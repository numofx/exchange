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

// effectiveReduceOnlyCapacity is the smaller of what the ledger and what the chain allow a
// reduce-only leg. Positions also move without a venue fill (a liquidation, perp settlement, a
// transfer between accounts), and a ledger that missed one would clamp to a size larger than the
// real position -- the flip again, and most likely for an account the keeper has just bid on. A
// chain read that lags a fill the venue has already finalized errs the other way, towards a smaller
// fill, which is the safe side. A nil chain (no RPC) leaves the ledger alone.
func effectiveReduceOnlyCapacity(side orders.Side, ledger, chain, amountScale *big.Int) *big.Int {
	fromLedger := reduceOnlyCapacity(side, ledger, amountScale)
	if chain == nil {
		return fromLedger
	}
	fromChain := reduceOnlyCapacity(side, chain, amountScale)
	if fromChain.Cmp(fromLedger) < 0 {
		return fromChain
	}
	return fromLedger
}

// perpLedger describes the fill to the orders repository, which moves the venue's position ledger
// with it: the perp's, or a future series' (keyed by its sub id, the expiry). amountScale is exact:
// executionFill.FillAmount is fillAmount times the shared scale.
func perpLedger(instrument instruments.Metadata, fillAmountAtomic, fillAmountChain string) (*orders.PerpFillLedger, error) {
	if !instrument.IsPerpetual() && !instrument.IsFuture() {
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
	return &orders.PerpFillLedger{
		AssetAddress: strings.ToLower(instrument.AssetAddress),
		SubID:        ledgerSeries(instrument),
		ChainAmount:  chain,
		AmountScale:  scale,
	}, nil
}

// ledgerSeries is the sub id a market's positions are held under: the perp's 0, a future's expiry.
func ledgerSeries(instrument instruments.Metadata) string {
	if instrument.IsFuture() && strings.TrimSpace(instrument.SubID) != "" {
		return instrument.SubID
	}
	return "0"
}

// chainPosition is the account's live position in the market, signed, in chain units: the perp's
// balance through the margin checker, a future series' through its own reader. Nil without a
// reader (no RPC), which leaves the clamp to the ledger alone.
func (e *Engine) chainPosition(ctx context.Context, instrument instruments.Metadata, ledger *orders.PerpFillLedger, subaccountID string) (*big.Int, error) {
	if instrument.IsFuture() {
		reader := e.futureReader(instrument)
		if reader == nil {
			return nil, nil
		}
		account, ok := new(big.Int).SetString(strings.TrimSpace(subaccountID), 10)
		if !ok {
			return nil, fmt.Errorf("subaccount %q is not an integer", subaccountID)
		}
		return reader.Position(ctx, account)
	}
	if e.margin == nil {
		return nil, nil
	}
	return e.margin.Position(ctx, ledger.AssetAddress, subaccountID)
}

// errReduceOnlyCancelled: a reduce-only leg had nothing to reduce and was cancelled; the match is off.
var errReduceOnlyCancelled = errors.New("reduce-only order cancelled")

// reduceOnlyLeg: the order carries the flag, or the perp is close-only (CNGN_PERP_CLOSE_ONLY), or the
// order's futures series is (FutureSeries.CloseOnly): either holds every leg on that market to its
// position, orders resting from before the switch included.
func (e *Engine) reduceOnlyLeg(instrument instruments.Metadata, leg orders.Order) bool {
	return leg.ReduceOnly || (e.perpCloseOnly && instrument.IsPerpetual()) || (instrument.IsFuture() && instrument.CloseOnly)
}

// clampReduceOnly shrinks fillAmount (order units) to what each reduce-only leg's position allows,
// read from the venue's ledger. A leg with no capacity is cancelled by the venue -- it could only
// have opened or flipped a position -- and the match is abandoned so the other leg goes back on the
// book. Spot orders never carry the flag (the API refuses it), so the clamp is the perp's and the
// futures'.
func (e *Engine) clampReduceOnly(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillAmount string, ledger *orders.PerpFillLedger) (string, error) {
	if ledger == nil || (!e.reduceOnlyLeg(instrument, candidate.Taker) && !e.reduceOnlyLeg(instrument, candidate.Maker)) {
		return fillAmount, nil
	}
	fill, err := parsePositiveInt(fillAmount, "fill_amount_atomic")
	if err != nil {
		return "", err
	}
	for _, leg := range []orders.Order{candidate.Taker, candidate.Maker} {
		if !e.reduceOnlyLeg(instrument, leg) {
			continue
		}
		position, ok, err := e.orders.PerpPosition(ctx, leg.SubaccountID, ledger.AssetAddress, ledger.Series())
		if err != nil {
			return "", fmt.Errorf("read ledger position of %s: %w", leg.SubaccountID, err)
		}
		if !ok {
			position = big.NewInt(0)
		}
		// The live position, read in this match cycle. Unreadable means no reduce-only fill this
		// tick: the pair goes back on the book and is retried, rather than filled on the ledger alone.
		chain, err := e.chainPosition(ctx, instrument, ledger, leg.SubaccountID)
		if err != nil {
			return "", fmt.Errorf("read chain position of %s: %w", leg.SubaccountID, err)
		}
		if chain != nil {
			if !ok || position.Cmp(chain) != 0 {
				slog.Warn("reduce_only_ledger_resynced",
					"market", instrument.Symbol,
					"subaccount_id", leg.SubaccountID,
					"ledger_position", position.String(),
					"chain_position", chain.String(),
					"ledger_seeded", ok,
				)
				if err := e.orders.SetPerpPosition(ctx, leg.SubaccountID, ledger.AssetAddress, ledger.Series(), chain); err != nil {
					slog.Error("reduce_only_ledger_resync_failed", "subaccount_id", leg.SubaccountID, "error", err)
				}
			}
			// A ledger never seeded has no fills of its own to count: the chain is the position. A
			// seeded one keeps the smaller of the two, since it counts fills the chain has not seen.
			if !ok {
				position = new(big.Int).Set(chain)
			}
		}
		capacity := effectiveReduceOnlyCapacity(leg.Side, position, chain, ledger.AmountScale)
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
				"chain_position", bigString(chain),
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
				"chain_position", bigString(chain),
				"fill_amount_atomic", fill.String(),
				"clamped_to", capacity.String(),
			)
			fill = capacity
		}
	}
	return fill.String(), nil
}

func bigString(value *big.Int) string {
	if value == nil {
		return "unread"
	}
	return value.String()
}
