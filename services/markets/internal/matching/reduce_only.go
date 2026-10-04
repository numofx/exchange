package matching

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"strings"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// reduceOnlyCapacity is how much of a fill (in order units) a reduce-only order may take given the
// account's position in chain units: zero when the position is flat or on the order's own side (an
// engine buyer reduces a short, a seller reduces a long), otherwise the position floored to whole
// order units. amountScale is chain units per order unit, as computeExecutionUnits inferred it.
func reduceOnlyCapacity(side orders.Side, position, amountScale *big.Int) *big.Int {
	if position == nil || amountScale == nil || amountScale.Sign() <= 0 {
		return big.NewInt(0)
	}
	reduces := (side == orders.SideBuy && position.Sign() < 0) || (side == orders.SideSell && position.Sign() > 0)
	if !reduces {
		return big.NewInt(0)
	}
	return new(big.Int).Quo(new(big.Int).Abs(position), amountScale)
}

// perpLedger describes the fill to the orders repository, which moves the venue's position ledger
// with it. amountScale is exact: executionFill.FillAmount is fillAmount times the shared scale.
func perpLedger(instrument instruments.Metadata, fillAmountAtomic, fillAmountChain string) (*orders.PerpFillLedger, error) {
	if !instrument.IsPerpetual() {
		return nil, nil
	}
	atomic, err := parsePositiveInt(fillAmountAtomic, "fill_amount_atomic")
	if err != nil {
		return nil, err
	}
	chain, err := parsePositiveInt(fillAmountChain, "fill_amount")
	if err != nil {
		return nil, err
	}
	scale, rem := new(big.Int).QuoRem(chain, atomic, new(big.Int))
	if rem.Sign() != 0 || scale.Sign() <= 0 {
		return nil, fmt.Errorf("fill amount %s is not a whole multiple of its atomic amount %s", fillAmountChain, fillAmountAtomic)
	}
	return &orders.PerpFillLedger{AssetAddress: strings.ToLower(instrument.AssetAddress), ChainAmount: chain, AmountScale: scale}, nil
}

// errReduceOnlyCancelled: a reduce-only leg had nothing to reduce and was cancelled; the match is off.
var errReduceOnlyCancelled = errors.New("reduce-only order cancelled")

// clampReduceOnly shrinks fillAmount (order units) to what each reduce-only leg's position allows,
// read from the venue's ledger. A leg with no capacity is cancelled by the venue -- it could only
// have opened or flipped a position -- and the match is abandoned so the other leg goes back on the
// book. Spot orders never carry the flag (the API refuses it), so the clamp is perp-only.
func (e *Engine) clampReduceOnly(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillAmount string, ledger *orders.PerpFillLedger) (string, error) {
	if ledger == nil || (!candidate.Taker.ReduceOnly && !candidate.Maker.ReduceOnly) {
		return fillAmount, nil
	}
	fill, err := parsePositiveInt(fillAmount, "fill_amount_atomic")
	if err != nil {
		return "", err
	}
	for _, leg := range []orders.Order{candidate.Taker, candidate.Maker} {
		if !leg.ReduceOnly {
			continue
		}
		position, ok, err := e.orders.PerpPosition(ctx, leg.SubaccountID, ledger.AssetAddress)
		if err != nil {
			return "", fmt.Errorf("read ledger position of %s: %w", leg.SubaccountID, err)
		}
		if !ok {
			position = big.NewInt(0)
		}
		capacity := reduceOnlyCapacity(leg.Side, position, ledger.AmountScale)
		if capacity.Sign() <= 0 {
			if err := e.orders.CancelByVenue(ctx, leg.OrderID, orders.CancelReasonReduceOnlyNoPosition); err != nil && !errors.Is(err, orders.ErrNotFound) {
				return "", fmt.Errorf("cancel reduce-only order %s: %w", leg.OrderID, err)
			}
			slog.Info("reduce_only_cancelled",
				"market", instrument.Symbol,
				"order_id", leg.OrderID,
				"subaccount_id", leg.SubaccountID,
				"side", leg.Side,
				"ledger_position", position.String(),
				"reason", orders.CancelReasonReduceOnlyNoPosition,
			)
			return "", errReduceOnlyCancelled
		}
		if capacity.Cmp(fill) < 0 {
			slog.Info("reduce_only_clamped",
				"market", instrument.Symbol,
				"order_id", leg.OrderID,
				"subaccount_id", leg.SubaccountID,
				"ledger_position", position.String(),
				"fill_amount_atomic", fill.String(),
				"clamped_to", capacity.String(),
			)
			fill = capacity
		}
	}
	return fill.String(), nil
}
