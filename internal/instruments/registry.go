package instruments

import (
	"strings"

	"github.com/numofx/matching-backend/internal/config"
)

const (
	CNGNSpotSymbol       = "USDCcNGN-SPOT"
	CNGNSpotLegacySymbol = "USDC/cNGN"

	CNGNJun2026Symbol       = "USDCcNGN-JUN30-2026"
	CNGNJun2026LegacySymbol = "USDC-cNGN-JUN30-2026"
	CNGNNov2026Symbol       = "USDCcNGN-NOV30-2026"
	CNGNNov2026LegacySymbol = "USDC-cNGN-NOV30-2026"
	CNGNMay2027Symbol       = "USDCcNGN-MAY31-2027"
	CNGNMay2027LegacySymbol = "USDC-cNGN-MAY31-2027"
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
		{
			Symbol:             CNGNJun2026Symbol,
			AssetAddress:       strings.ToLower(strings.TrimSpace(cfg.CNGNJun2026FutureAssetAddress)),
			SubID:              strings.TrimSpace(cfg.CNGNJun2026FutureSubID),
			ContractType:       "deliverable_fx_future",
			SettlementType:     "physical_delivery",
			BaseAssetSymbol:    "USDC",
			QuoteAssetSymbol:   "cNGN",
			ExpiryTimestamp:    1782777600,
			LastTradeTimestamp: 1782691200,
			TickSize:           "1",
			MinSize:            "0.001",
			ContractMultiplier: "10000",
			QuotePrecision:     6,
			PricingModel:       PricingModelLinear,
			PriceSemantics:     PricingModelLinear,
			DisplayPriceKind:   DisplayPriceDirect,
			DisplaySemantics:   DisplayPriceDirect,
			DisplayLabel:       "cNGN per USDC",
			DisplayName:        "USDC-cNGN JUN-30-2026 Future",
			SettlementNote:     "Physically delivered on Base. Long pays cNGN and receives fixed USDC notional; short pays fixed USDC notional and receives cNGN.",
			Enabled:            strings.TrimSpace(cfg.CNGNJun2026FutureAssetAddress) != "" && strings.TrimSpace(cfg.CNGNJun2026FutureSubID) != "",
		},
		{
			Symbol:             CNGNNov2026Symbol,
			AssetAddress:       strings.ToLower(strings.TrimSpace(cfg.CNGNNov2026FutureAssetAddress)),
			SubID:              strings.TrimSpace(cfg.CNGNNov2026FutureSubID),
			ContractType:       "deliverable_fx_future",
			SettlementType:     "physical_delivery",
			BaseAssetSymbol:    "USDC",
			QuoteAssetSymbol:   "cNGN",
			ExpiryTimestamp:    1795996800,
			LastTradeTimestamp: 1795910400,
			TickSize:           "1",
			MinSize:            "0.001",
			ContractMultiplier: "10000",
			QuotePrecision:     6,
			PricingModel:       PricingModelLinear,
			PriceSemantics:     PricingModelLinear,
			DisplayPriceKind:   DisplayPriceDirect,
			DisplaySemantics:   DisplayPriceDirect,
			DisplayLabel:       "cNGN per USDC",
			DisplayName:        "USDC-cNGN NOV-30-2026 Future",
			SettlementNote:     "Physically delivered on Base. Long pays cNGN and receives fixed USDC notional; short pays fixed USDC notional and receives cNGN.",
			Enabled:            strings.TrimSpace(cfg.CNGNNov2026FutureAssetAddress) != "" && strings.TrimSpace(cfg.CNGNNov2026FutureSubID) != "",
		},
		{
			Symbol:             CNGNMay2027Symbol,
			AssetAddress:       strings.ToLower(strings.TrimSpace(cfg.CNGNMay2027FutureAssetAddress)),
			SubID:              strings.TrimSpace(cfg.CNGNMay2027FutureSubID),
			ContractType:       "deliverable_fx_future",
			SettlementType:     "physical_delivery",
			BaseAssetSymbol:    "USDC",
			QuoteAssetSymbol:   "cNGN",
			ExpiryTimestamp:    1811721600,
			LastTradeTimestamp: 1811635200,
			TickSize:           "1",
			MinSize:            "0.001",
			ContractMultiplier: "10000",
			QuotePrecision:     6,
			PricingModel:       PricingModelLinear,
			PriceSemantics:     PricingModelLinear,
			DisplayPriceKind:   DisplayPriceDirect,
			DisplaySemantics:   DisplayPriceDirect,
			DisplayLabel:       "cNGN per USDC",
			DisplayName:        "USDC-cNGN MAY-31-2027 Future",
			SettlementNote:     "Physically delivered on Base. Long pays cNGN and receives fixed USDC notional; short pays fixed USDC notional and receives cNGN.",
			Enabled:            strings.TrimSpace(cfg.CNGNMay2027FutureAssetAddress) != "" && strings.TrimSpace(cfg.CNGNMay2027FutureSubID) != "",
		},
	}

	return NewRegistry(items)
}
