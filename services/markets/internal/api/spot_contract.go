package api

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

const (
	spotOrderEntrySpec          = instruments.SpotOrderEntrySpec
	spotEngineDecimalScale      = 18
	spotUIPriceDecimalScale     = 6
	spotUISizeDecimalScale      = 6
	spotContractComparisonScale = 18
)

type spotOrderIntent struct {
	Side  string `json:"side"`
	Price string `json:"price"`
	Size  string `json:"size"`
}

type spotEngineOrder struct {
	Side   string `json:"side"`
	Price  string `json:"price"`
	Amount string `json:"amount"`
}

type spotBalanceDeltas struct {
	USDC string `json:"usdc"`
	CNGN string `json:"cngn"`
}

type spotOrderContractEcho struct {
	Spec         string            `json:"spec"`
	UIIntent     spotOrderIntent   `json:"ui_intent"`
	EngineOrder  spotEngineOrder   `json:"engine_order"`
	BalanceDelta spotBalanceDeltas `json:"balance_delta"`
}

// isSpotContractInstrument reports whether the market is quoted in the inverted UI orientation:
// price in cNGN per USDC, size in USDC notional, side flipped against the engine. Spot and the perp
// both are -- the perp is USD per NGN on chain -- so one translation serves both, keyed on the
// market's own order_entry_spec. (The name predates the perp; every caller wants this predicate.)
func isSpotContractInstrument(instrument instruments.Metadata) bool {
	switch instrument.OrderEntrySpec {
	case instruments.SpotOrderEntrySpec:
		return instrument.Symbol == instruments.CNGNSpotSymbol && instrument.ContractType == instruments.ContractTypeSpot
	case instruments.PerpOrderEntrySpec:
		return instrument.Symbol == instruments.CNGNPerpSymbol && instrument.ContractType == instruments.ContractTypePerpetual
	default:
		return false
	}
}

// validateOrTranslateSpotUIIntent checks a ui_intent against, and translates it into, the engine
// order. `spec` is the market's own order_entry_spec: an intent signed for one market's spec is
// refused on another's, so a spot ticket cannot be replayed onto the perp or the other way round.
func validateOrTranslateSpotUIIntent(spec string, orderEntrySpec string, uiIntent *spotOrderIntent, engineSide orders.Side, enginePrice string, engineAmount string) (orders.Side, string, string, error) {
	if orderEntrySpec == "" && uiIntent == nil {
		return engineSide, enginePrice, engineAmount, nil
	}
	if orderEntrySpec != spec {
		return "", "", "", fmt.Errorf("order_entry_spec must be %q for this market's ui_intent", spec)
	}
	if uiIntent == nil {
		return "", "", "", fmt.Errorf("ui_intent is required when order_entry_spec is provided")
	}

	translated, err := translateSpotUIIntent(spec, uiIntent)
	if err != nil {
		return "", "", "", err
	}
	translatedEngineSide := orders.Side(translated.EngineOrder.Side)
	if engineSide != "" && engineSide != translatedEngineSide {
		return "", "", "", fmt.Errorf("side does not match ui_intent translation")
	}
	if strings.TrimSpace(enginePrice) != "" && !decimalStringsMatch(enginePrice, translated.EngineOrder.Price) {
		return "", "", "", fmt.Errorf("limit_price does not match ui_intent translation")
	}
	if strings.TrimSpace(engineAmount) != "" && !decimalStringsMatch(engineAmount, translated.EngineOrder.Amount) {
		return "", "", "", fmt.Errorf("desired_amount does not match ui_intent translation")
	}

	return translatedEngineSide, translated.EngineOrder.Price, translated.EngineOrder.Amount, nil
}

func translateSpotUIIntent(spec string, uiIntent *spotOrderIntent) (*spotOrderContractEcho, error) {
	if uiIntent == nil {
		return nil, fmt.Errorf("ui_intent is required")
	}

	uiSide := orders.Side(strings.ToLower(strings.TrimSpace(uiIntent.Side)))
	if uiSide != orders.SideBuy && uiSide != orders.SideSell {
		return nil, fmt.Errorf("ui_intent.side must be 'buy' or 'sell'")
	}

	uiPrice, err := parsePositiveDecimal(uiIntent.Price, "ui_intent.price")
	if err != nil {
		return nil, err
	}
	uiSize, err := parsePositiveDecimal(uiIntent.Size, "ui_intent.size")
	if err != nil {
		return nil, err
	}

	enginePrice := new(big.Rat).Inv(uiPrice)
	engineAmount := new(big.Rat).Mul(uiSize, uiPrice)
	engineSide := orders.SideBuy
	if uiSide == orders.SideBuy {
		engineSide = orders.SideSell
	}

	usdcDelta := new(big.Rat).Set(uiSize)
	cngnDelta := new(big.Rat).Neg(engineAmount)
	if uiSide == orders.SideSell {
		usdcDelta.Neg(usdcDelta)
		cngnDelta.Neg(cngnDelta)
	}

	return &spotOrderContractEcho{
		Spec: spec,
		UIIntent: spotOrderIntent{
			Side:  string(uiSide),
			Price: normalizeDecimalString(uiIntent.Price),
			Size:  normalizeDecimalString(uiIntent.Size),
		},
		EngineOrder: spotEngineOrder{
			Side:   string(engineSide),
			Price:  formatDecimal(enginePrice, spotEngineDecimalScale),
			Amount: formatDecimal(engineAmount, spotEngineDecimalScale),
		},
		BalanceDelta: spotBalanceDeltas{
			USDC: formatSignedDecimal(usdcDelta, spotUISizeDecimalScale),
			CNGN: formatSignedDecimal(cngnDelta, spotUISizeDecimalScale),
		},
	}, nil
}

func deriveSpotContractFromOrder(order orders.Order, instrument instruments.Metadata) (*spotOrderContractEcho, error) {
	if !isSpotContractInstrument(instrument) {
		return nil, nil
	}
	return deriveSpotOrderContractEchoFromEngine(instrument.OrderEntrySpec, order.Side, order.LimitPrice, order.DesiredAmount)
}

func deriveSpotContractFromTrade(trade orders.TradeFill, instrument instruments.Metadata) (*spotOrderContractEcho, error) {
	if !isSpotContractInstrument(instrument) {
		return nil, nil
	}
	return deriveSpotOrderContractEchoFromEngine(instrument.OrderEntrySpec, trade.AggressorSide, trade.Price, trade.Size)
}

// deriveSpotOrderContractEchoFromEngine presents an engine order in UI terms. For the perp the
// balance_delta is the change in USD/NGN exposure a fill opens, not a token movement: the same
// numbers, since the translation is the same, but nothing is delivered.
func deriveSpotOrderContractEchoFromEngine(spec string, engineSide orders.Side, enginePrice string, engineAmount string) (*spotOrderContractEcho, error) {
	if engineSide != orders.SideBuy && engineSide != orders.SideSell {
		return nil, fmt.Errorf("spot engine side must be buy or sell")
	}

	enginePriceRat, err := parsePositiveDecimal(enginePrice, "engine price")
	if err != nil {
		return nil, err
	}
	engineAmountRat, err := parsePositiveDecimal(engineAmount, "engine amount")
	if err != nil {
		return nil, err
	}

	uiPrice := new(big.Rat).Inv(enginePriceRat)
	uiSize := new(big.Rat).Mul(engineAmountRat, enginePriceRat)
	uiSide := orders.SideSell
	if engineSide == orders.SideSell {
		uiSide = orders.SideBuy
	}

	usdcDelta := new(big.Rat).Set(uiSize)
	cngnDelta := new(big.Rat).Neg(engineAmountRat)
	if uiSide == orders.SideSell {
		usdcDelta.Neg(usdcDelta)
		cngnDelta.Neg(cngnDelta)
	}

	return &spotOrderContractEcho{
		Spec: spec,
		UIIntent: spotOrderIntent{
			Side:  string(uiSide),
			Price: formatDecimal(uiPrice, spotUIPriceDecimalScale),
			Size:  formatDecimal(uiSize, spotUISizeDecimalScale),
		},
		EngineOrder: spotEngineOrder{
			Side:   string(engineSide),
			Price:  normalizeDecimalString(enginePrice),
			Amount: normalizeDecimalString(engineAmount),
		},
		BalanceDelta: spotBalanceDeltas{
			USDC: formatSignedDecimal(usdcDelta, spotUISizeDecimalScale),
			CNGN: formatSignedDecimal(cngnDelta, spotUISizeDecimalScale),
		},
	}, nil
}

func parsePositiveDecimal(raw string, label string) (*big.Rat, error) {
	rat, err := parseDecimal(raw)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", label, err)
	}
	if rat.Sign() <= 0 {
		return nil, fmt.Errorf("%s must be greater than zero", label)
	}
	return rat, nil
}

func decimalStringsMatch(left string, right string) bool {
	leftRat, err := parseDecimal(left)
	if err != nil {
		return false
	}
	rightRat, err := parseDecimal(right)
	if err != nil {
		return false
	}

	delta := new(big.Rat).Sub(leftRat, rightRat)
	if delta.Sign() < 0 {
		delta.Neg(delta)
	}

	return delta.Cmp(decimalTolerance(spotContractComparisonScale)) <= 0
}

func decimalTolerance(scale int) *big.Rat {
	denominator := new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(scale)), nil)
	return new(big.Rat).SetFrac(big.NewInt(1), denominator)
}

func formatSignedDecimal(value *big.Rat, scale int) string {
	if value.Sign() >= 0 {
		return "+" + formatDecimal(value, scale)
	}
	positive := new(big.Rat).Neg(new(big.Rat).Set(value))
	return "-" + formatDecimal(positive, scale)
}
