package matching

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

type tradeActionData struct {
	Asset         string
	SubID         *big.Int
	LimitPrice    *big.Int
	DesiredAmount *big.Int
	IsBid         bool
}

// CancelReasonUnmatchable is the cancel reason for an order whose signed action can never settle
// against the order it crossed: a unit or market the signature disagrees with.
const CancelReasonUnmatchable = "unmatchable_signed_order"

// unmatchableError is a pair that can never settle as signed, whatever the book does: it depends only
// on the two orders' signatures and the fill, so a retry repeats it and holds the top of the book. legs
// names the orders at fault ("taker", "maker"), which the venue cancels.
type unmatchableError struct {
	legs []string
	err  error
}

func (u *unmatchableError) Error() string { return u.err.Error() }
func (u *unmatchableError) Unwrap() error { return u.err }

func unmatchable(err error, legs ...string) error {
	if err == nil {
		return nil
	}
	var already *unmatchableError
	if errors.As(err, &already) {
		return err
	}
	return &unmatchableError{legs: legs, err: err}
}

// unmatchableLegs is the legs to cancel for an error from computeExecutionUnits, or nil when the
// error is not one a retry cannot fix.
func unmatchableLegs(err error) []string {
	var u *unmatchableError
	if errors.As(err, &u) {
		return u.legs
	}
	return nil
}

type executionUnits struct {
	FillPrice  string
	FillAmount string
}

// computeExecutionUnits turns a fill in order units into the signed units the chain settles. Every
// error it returns is unmatchable: it follows from the two signatures and the fill amount alone.
func computeExecutionUnits(instrument instruments.Metadata, candidate orders.MatchCandidate, fillPriceTicks string, fillAmountAtomic string) (executionUnits, error) {
	takerAction, err := parseTradeAction(candidate.Taker)
	if err != nil {
		return executionUnits{}, unmatchable(fmt.Errorf("parse taker signed action: %w", err), "taker")
	}
	makerAction, err := parseTradeAction(candidate.Maker)
	if err != nil {
		return executionUnits{}, unmatchable(fmt.Errorf("parse maker signed action: %w", err), "maker")
	}

	if err := validateActionMarket("taker", candidate.Taker, takerAction); err != nil {
		return executionUnits{}, unmatchable(err, "taker")
	}
	if err := validateActionMarket("maker", candidate.Maker, makerAction); err != nil {
		return executionUnits{}, unmatchable(err, "maker")
	}

	takerLimitTicks, err := parsePositiveInt(candidate.Taker.LimitPriceTicks, "taker limit_price_ticks")
	if err != nil {
		return executionUnits{}, unmatchable(err, "taker")
	}
	makerLimitTicks, err := parsePositiveInt(candidate.Maker.LimitPriceTicks, "maker limit_price_ticks")
	if err != nil {
		return executionUnits{}, unmatchable(err, "maker")
	}
	fillPriceTickInt, err := parsePositiveInt(fillPriceTicks, "fill_price_ticks")
	if err != nil {
		return executionUnits{}, unmatchable(err, "taker", "maker")
	}
	takerDesiredAtomic, err := parsePositiveInt(candidate.Taker.DesiredAmount, "taker desired_amount")
	if err != nil {
		return executionUnits{}, unmatchable(err, "taker")
	}
	makerDesiredAtomic, err := parsePositiveInt(candidate.Maker.DesiredAmount, "maker desired_amount")
	if err != nil {
		return executionUnits{}, unmatchable(err, "maker")
	}
	fillAmountAtomicInt, err := parsePositiveInt(fillAmountAtomic, "fill_amount_atomic")
	if err != nil {
		return executionUnits{}, unmatchable(err, "taker", "maker")
	}

	priceScale, err := inferSharedScale(
		"price",
		takerLimitTicks, takerAction.LimitPrice,
		makerLimitTicks, makerAction.LimitPrice,
		nil,
	)
	if err != nil {
		return executionUnits{}, err
	}

	// A market that fixes its unit (spot, the future) knows which leg is off it; otherwise (the perp)
	// the incoming order of a pair at two different scales is cancelled.
	fixedAmountScale, _ := instrument.FixedAmountScale()
	amountScale, err := inferSharedScale(
		"amount",
		takerDesiredAtomic, takerAction.DesiredAmount,
		makerDesiredAtomic, makerAction.DesiredAmount,
		fixedAmountScale,
	)
	if err != nil {
		return executionUnits{}, err
	}

	fillPrice := new(big.Int).Mul(fillPriceTickInt, priceScale)
	fillAmount := new(big.Int).Mul(fillAmountAtomicInt, amountScale)

	takerRemaining, err := scaledRemaining(candidate.Taker, amountScale)
	if err != nil {
		return executionUnits{}, unmatchable(err, "taker")
	}
	makerRemaining, err := scaledRemaining(candidate.Maker, amountScale)
	if err != nil {
		return executionUnits{}, unmatchable(err, "maker")
	}

	if fillAmount.Cmp(takerRemaining) > 0 {
		return executionUnits{}, unmatchable(fmt.Errorf("fill_amount exceeds taker remaining desired amount"), "taker")
	}
	if fillAmount.Cmp(makerRemaining) > 0 {
		return executionUnits{}, unmatchable(fmt.Errorf("fill_amount exceeds maker remaining desired amount"), "maker")
	}

	if err := validatePriceScaleAlignment(candidate.Taker, takerAction, fillPrice, "taker"); err != nil {
		return executionUnits{}, unmatchable(err, "taker")
	}
	if err := validatePriceScaleAlignment(candidate.Maker, makerAction, fillPrice, "maker"); err != nil {
		return executionUnits{}, unmatchable(err, "maker")
	}

	return executionUnits{FillPrice: fillPrice.String(), FillAmount: fillAmount.String()}, nil
}

func validatePriceScaleAlignment(order orders.Order, action tradeActionData, fillPrice *big.Int, role string) error {
	if order.Side == orders.SideBuy {
		if fillPrice.Cmp(action.LimitPrice) > 0 {
			return fmt.Errorf("%s fill_price exceeds signed buy limit", role)
		}
	} else if order.Side == orders.SideSell {
		if fillPrice.Cmp(action.LimitPrice) < 0 {
			return fmt.Errorf("%s fill_price is below signed sell limit", role)
		}
	}
	return nil
}

// inferSharedScale is the one scale both legs are signed at (signed value per unit). With fixed set,
// a leg at any other scale is the leg at fault; without it, the taker of legs that disagree is.
func inferSharedScale(label string, leftBase *big.Int, leftSigned *big.Int, rightBase *big.Int, rightSigned *big.Int, fixed *big.Int) (*big.Int, error) {
	legScale := func(role string, base, signed *big.Int) (*big.Int, error) {
		if base.Sign() <= 0 {
			return nil, unmatchable(fmt.Errorf("%s base value must be positive", label), role)
		}
		if signed.Sign() <= 0 {
			return nil, unmatchable(fmt.Errorf("%s signed value must be positive", label), role)
		}
		scale, rem := new(big.Int).QuoRem(signed, base, new(big.Int))
		if rem.Sign() != 0 {
			return nil, unmatchable(fmt.Errorf("%s scale mismatch for %s signed order", label, role), role)
		}
		return scale, nil
	}
	leftScale, err := legScale("taker", leftBase, leftSigned)
	if err != nil {
		return nil, err
	}
	rightScale, err := legScale("maker", rightBase, rightSigned)
	if err != nil {
		return nil, err
	}
	if fixed != nil {
		var off []string
		if leftScale.Cmp(fixed) != 0 {
			off = append(off, "taker")
		}
		if rightScale.Cmp(fixed) != 0 {
			off = append(off, "maker")
		}
		if len(off) > 0 {
			return nil, unmatchable(fmt.Errorf("%s scale is not the market's %s for the %s signed order", label, fixed, strings.Join(off, " and ")), off...)
		}
	}
	if leftScale.Cmp(rightScale) != 0 {
		// No fixed unit to say which is right (the perp). The resting order was matchable until this one
		// arrived, so the incoming order goes: cancelling both would let anyone wipe a quote for free.
		return nil, unmatchable(fmt.Errorf("%s scale mismatch between taker and maker signed orders", label), "taker")
	}
	return leftScale, nil
}

func scaledRemaining(order orders.Order, scale *big.Int) (*big.Int, error) {
	desired, err := parsePositiveInt(order.DesiredAmount, "desired_amount")
	if err != nil {
		return nil, err
	}
	filled, err := parseNonNegativeInt(order.FilledAmount, "filled_amount")
	if err != nil {
		return nil, err
	}
	remaining := new(big.Int).Sub(desired, filled)
	if remaining.Sign() < 0 {
		return nil, fmt.Errorf("filled_amount exceeds desired_amount")
	}
	return new(big.Int).Mul(remaining, scale), nil
}

func validateActionMarket(role string, order orders.Order, action tradeActionData) error {
	if strings.ToLower(action.Asset) != strings.ToLower(order.AssetAddress) {
		return fmt.Errorf("%s signed action asset mismatch", role)
	}
	if action.SubID.String() != strings.TrimSpace(order.SubID) {
		return fmt.Errorf("%s signed action sub_id mismatch", role)
	}
	expectedBid := order.Side == orders.SideBuy
	if action.IsBid != expectedBid {
		return fmt.Errorf("%s signed action side mismatch", role)
	}
	return nil
}

func parseTradeAction(order orders.Order) (tradeActionData, error) {
	var action struct {
		Data string `json:"data"`
	}
	if err := json.Unmarshal(order.ActionJSON, &action); err != nil {
		return tradeActionData{}, err
	}
	if strings.TrimSpace(action.Data) == "" {
		return tradeActionData{}, fmt.Errorf("missing action data")
	}
	return decodeTradeData(action.Data)
}

func decodeTradeData(raw string) (tradeActionData, error) {
	hexValue := strings.TrimSpace(raw)
	hexValue = strings.TrimPrefix(hexValue, "0x")
	if len(hexValue) != 64*7 {
		return tradeActionData{}, fmt.Errorf("unexpected trade data length %d", len(hexValue))
	}
	bytesValue, err := hex.DecodeString(hexValue)
	if err != nil {
		return tradeActionData{}, err
	}
	word := func(i int) []byte {
		start := i * 32
		return bytesValue[start : start+32]
	}

	asset := "0x" + hex.EncodeToString(word(0)[12:])
	subID := new(big.Int).SetBytes(word(1))
	limitPrice := int256FromWord(word(2))
	desiredAmount := int256FromWord(word(3))
	isBid := new(big.Int).SetBytes(word(6)).Cmp(big.NewInt(0)) != 0

	return tradeActionData{
		Asset:         strings.ToLower(asset),
		SubID:         subID,
		LimitPrice:    limitPrice,
		DesiredAmount: desiredAmount,
		IsBid:         isBid,
	}, nil
}

func int256FromWord(word []byte) *big.Int {
	value := new(big.Int).SetBytes(word)
	if len(word) != 32 {
		return value
	}
	if word[0]&0x80 == 0 {
		return value
	}
	two256 := new(big.Int).Lsh(big.NewInt(1), 256)
	return value.Sub(value, two256)
}

func parseNonNegativeInt(value string, label string) (*big.Int, error) {
	parsed, ok := new(big.Int).SetString(strings.TrimSpace(value), 10)
	if !ok {
		return nil, fmt.Errorf("invalid %s", label)
	}
	if parsed.Sign() < 0 {
		return nil, fmt.Errorf("%s must be non-negative", label)
	}
	return parsed, nil
}

func parsePositiveInt(value string, label string) (*big.Int, error) {
	parsed, err := parseNonNegativeInt(value, label)
	if err != nil {
		return nil, err
	}
	if parsed.Sign() == 0 {
		return nil, fmt.Errorf("%s must be positive", label)
	}
	return parsed, nil
}
