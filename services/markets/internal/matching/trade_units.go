package matching

import (
	"encoding/hex"
	"encoding/json"
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

type executionUnits struct {
	FillPrice  string
	FillAmount string
}

func computeExecutionUnits(instrument instruments.Metadata, candidate orders.MatchCandidate, fillPriceTicks string, fillAmountAtomic string) (executionUnits, error) {
	takerAction, err := parseTradeAction(candidate.Taker)
	if err != nil {
		return executionUnits{}, fmt.Errorf("parse taker signed action: %w", err)
	}
	makerAction, err := parseTradeAction(candidate.Maker)
	if err != nil {
		return executionUnits{}, fmt.Errorf("parse maker signed action: %w", err)
	}

	if err := validateActionMarket("taker", candidate.Taker, takerAction); err != nil {
		return executionUnits{}, err
	}
	if err := validateActionMarket("maker", candidate.Maker, makerAction); err != nil {
		return executionUnits{}, err
	}

	takerLimitTicks, err := parsePositiveInt(candidate.Taker.LimitPriceTicks, "taker limit_price_ticks")
	if err != nil {
		return executionUnits{}, err
	}
	makerLimitTicks, err := parsePositiveInt(candidate.Maker.LimitPriceTicks, "maker limit_price_ticks")
	if err != nil {
		return executionUnits{}, err
	}
	fillPriceTickInt, err := parsePositiveInt(fillPriceTicks, "fill_price_ticks")
	if err != nil {
		return executionUnits{}, err
	}
	takerDesiredAtomic, err := parsePositiveInt(candidate.Taker.DesiredAmount, "taker desired_amount")
	if err != nil {
		return executionUnits{}, err
	}
	makerDesiredAtomic, err := parsePositiveInt(candidate.Maker.DesiredAmount, "maker desired_amount")
	if err != nil {
		return executionUnits{}, err
	}
	fillAmountAtomicInt, err := parsePositiveInt(fillAmountAtomic, "fill_amount_atomic")
	if err != nil {
		return executionUnits{}, err
	}

	priceScale, err := inferSharedScale(
		"price",
		takerLimitTicks, takerAction.LimitPrice,
		makerLimitTicks, makerAction.LimitPrice,
	)
	if err != nil {
		return executionUnits{}, err
	}

	amountScale, err := inferSharedScale(
		"amount",
		takerDesiredAtomic, takerAction.DesiredAmount,
		makerDesiredAtomic, makerAction.DesiredAmount,
	)
	if err != nil {
		return executionUnits{}, err
	}

	fillPrice := new(big.Int).Mul(fillPriceTickInt, priceScale)
	fillAmount := new(big.Int).Mul(fillAmountAtomicInt, amountScale)

	takerRemaining, err := scaledRemaining(candidate.Taker, amountScale)
	if err != nil {
		return executionUnits{}, err
	}
	makerRemaining, err := scaledRemaining(candidate.Maker, amountScale)
	if err != nil {
		return executionUnits{}, err
	}

	if fillAmount.Cmp(takerRemaining) > 0 {
		return executionUnits{}, fmt.Errorf("fill_amount exceeds taker remaining desired amount")
	}
	if fillAmount.Cmp(makerRemaining) > 0 {
		return executionUnits{}, fmt.Errorf("fill_amount exceeds maker remaining desired amount")
	}

	if err := validatePriceScaleAlignment(candidate.Taker, takerAction, fillPrice, "taker"); err != nil {
		return executionUnits{}, err
	}
	if err := validatePriceScaleAlignment(candidate.Maker, makerAction, fillPrice, "maker"); err != nil {
		return executionUnits{}, err
	}

	// Futures and perps rely on on-chain signed order units. Spot order entry is translated
	// before persistence, so this path remains consistent by deriving units directly from signatures.
	_ = instrument

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

func inferSharedScale(label string, leftBase *big.Int, leftSigned *big.Int, rightBase *big.Int, rightSigned *big.Int) (*big.Int, error) {
	if leftBase.Sign() <= 0 || rightBase.Sign() <= 0 {
		return nil, fmt.Errorf("%s base value must be positive", label)
	}
	if leftSigned.Sign() <= 0 || rightSigned.Sign() <= 0 {
		return nil, fmt.Errorf("%s signed value must be positive", label)
	}

	leftScale, leftRem := new(big.Int).QuoRem(leftSigned, leftBase, new(big.Int))
	if leftRem.Sign() != 0 {
		return nil, fmt.Errorf("%s scale mismatch for taker signed order", label)
	}
	rightScale, rightRem := new(big.Int).QuoRem(rightSigned, rightBase, new(big.Int))
	if rightRem.Sign() != 0 {
		return nil, fmt.Errorf("%s scale mismatch for maker signed order", label)
	}
	if leftScale.Cmp(rightScale) != 0 {
		return nil, fmt.Errorf("%s scale mismatch between taker and maker signed orders", label)
	}
	if leftScale.Sign() <= 0 {
		return nil, fmt.Errorf("%s scale must be positive", label)
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
