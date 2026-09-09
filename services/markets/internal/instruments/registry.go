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
			SettlementNote:     spotSettlementNote(cfg),
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

// spotSettlementNote states which rail the quote leg actually settles on, because the two are
// not equivalent: against cash the USDC side is a claim on the settlement ledger, against a
// WrappedERC20Asset it is a 1:1 claim on USDC the wrapper holds. QUOTE_ASSET_ADDRESS is the
// switch, and it must be set to the quoteAsset() of whichever TradeModule the venue is pointed
// at -- the note is derived from it so the two cannot drift.
func spotSettlementNote(cfg config.Config) string {
	if strings.TrimSpace(cfg.QuoteAssetAddress) != "" {
		return "Spot-style orderbook market on Base. Trades exchange WRAPPED_CNGN against wrapped USDC (" +
			strings.TrimSpace(cfg.QuoteAssetAddress) +
			"); both legs are wrapped-token transfers and the settlement ledger is out of the trade path."
	}
	return "Spot-style orderbook market on Base. Trades exchange WRAPPED_CNGN against internal USDC cash using the existing single quote-asset rail."
}
