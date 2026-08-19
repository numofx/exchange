package instruments

import (
	"strings"

	"github.com/numofx/matching-backend/internal/config"
)

const (
	CNGNSpotSymbol       = "USDCcNGN-SPOT"
	CNGNSpotLegacySymbol = "USDC/cNGN"
)

func DefaultRegistry(cfg config.Config) *Registry {
	items := []Metadata{
		{
			Symbol:             CNGNSpotSymbol,
			AssetAddress:       strings.ToLower(strings.TrimSpace(cfg.CNGNSpotAssetAddress)),
			SubID:              "0",
			ContractType:       "spot",
			SettlementType:     "spot",
			BaseAssetSymbol:    "USDC",
			QuoteAssetSymbol:   "cNGN",
			TickSize:           "0.000000000000000001",
			MinSize:            "0.000001",
			ContractMultiplier: "1",
			QuotePrecision:     18,
			PricingModel:       PricingModelLinear,
			PriceSemantics:     PricingModelLinear,
			DisplayPriceKind:   DisplayPriceDirect,
			DisplaySemantics:   DisplayPriceDirect,
			DisplayLabel:       "cNGN per USDC",
			DisplayName:        "USDC/cNGN Spot",
			SettlementNote:     "Spot-style orderbook market on Base. Trades exchange WRAPPED_CNGN against internal USDC cash using the existing single quote-asset rail.",
			OrderEntrySpec:     "usdc_cngn_spot_v1",
			UIPriceUnit:        "cNGN per USDC",
			UISizeUnit:         "USDC notional",
			UISideMeaning:      "BUY acquires USDC and sells cNGN inventory; SELL delivers USDC and buys cNGN inventory.",
			EnginePriceUnit:    "USDC per cNGN",
			EngineAmountUnit:   "cNGN amount",
			EngineSidePolicy:   "invert_ui_side",
			UIPriceToEngine:    "engine_price = 1 / ui_price",
			UISizeToEngine:     "engine_amount = ui_size * ui_price",
			Enabled:            strings.TrimSpace(cfg.CNGNSpotAssetAddress) != "",
		},
	}

	return NewRegistry(items)
}
