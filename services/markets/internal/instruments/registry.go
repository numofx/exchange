package instruments

import (
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

const (
	CNGNSpotSymbol       = "USDCcNGN-SPOT"
	CNGNSpotLegacySymbol = "USDC/cNGN"
	CNGNPerpSymbol       = "USDCcNGN-PERP"

	SpotOrderEntrySpec = "usdc_cngn_spot_v1"
	PerpOrderEntrySpec = "usdc_cngn_perp_v1"
)

func DefaultRegistry(cfg config.Config) *Registry {
	items := []Metadata{
		{
			Symbol:           CNGNSpotSymbol,
			AssetAddress:     strings.ToLower(strings.TrimSpace(cfg.CNGNSpotAssetAddress)),
			SubID:            "0",
			ContractType:     ContractTypeSpot,
			SettlementType:   "spot",
			BaseAssetSymbol:  "USDC",
			QuoteAssetSymbol: "cNGN",
			TickSize:         "0.000000000000000001",
			// 25 bps taker, 0 maker. Charged in the trade module's quote asset -- wrapped USDC
			// since the 2026-09-10 cutover -- and paid to the module's feeRecipient.
			TakerFeeBps:        25,
			MakerFeeBps:        0,
			MinSize:            "0.000001",
			ContractMultiplier: "1",
			QuotePrecision:     18,
			PricingModel:       PricingModelLinear,
			PriceSemantics:     PricingModelLinear,
			DisplayPriceKind:   DisplayPriceDirect,
			DisplaySemantics:   DisplayPriceDirect,
			DisplayLabel:       "cNGN per USDC",
			DisplayName:        "USDC/cNGN Spot",
			SettlementNote:     "Spot-style orderbook market on Base. Trades exchange WRAPPED_CNGN against the quote asset of the configured TradeModule (TRADE_MODULE_ADDRESS / QUOTE_ASSET_ADDRESS): the internal USDC cash ledger under the cash-quoted module, or the wrapped USDC asset under the wrapped-quote module, in which case both legs are 1:1 token-backed.",
			OrderEntrySpec:     SpotOrderEntrySpec,
			UIPriceUnit:        "cNGN per USDC",
			UISizeUnit:         "USDC notional",
			UISideMeaning:      "BUY acquires USDC and sells cNGN inventory; SELL delivers USDC and buys cNGN inventory.",
			EnginePriceUnit:    "USDC per cNGN",
			EngineAmountUnit:   "cNGN amount",
			EngineSidePolicy:   "invert_ui_side",
			UIPriceToEngine:    "engine_price = 1 / ui_price",
			UISizeToEngine:     "engine_amount = ui_size * ui_price",
			TradeModuleAddress: strings.ToLower(strings.TrimSpace(cfg.TradeModuleAddress)),
			QuoteAssetAddress:  strings.ToLower(strings.TrimSpace(cfg.QuoteAsset())),
			Enabled:            strings.TrimSpace(cfg.CNGNSpotAssetAddress) != "",
		},
		{
			// The perp is denominated on chain in USDC per cNGN (~0.00072), sized in cNGN, so PnL lands
			// in USDC cash with no conversion. The venue shows it the way it shows spot: cNGN per USDC,
			// sized in USDC notional, with the side flipped -- a UI long is long USDC, which is short
			// the cNGN perp. Same translation as spot, so one ticket reads both markets.
			Symbol:               CNGNPerpSymbol,
			AssetAddress:         strings.ToLower(strings.TrimSpace(cfg.CNGNPerpAssetAddress)),
			SubID:                "0",
			ContractType:         ContractTypePerpetual,
			SettlementType:       "cash_settled_perpetual",
			BaseAssetSymbol:      "USDC",
			QuoteAssetSymbol:     "cNGN",
			TickSize:             "0.000000000000000001",
			TakerFeeBps:          25,
			MakerFeeBps:          0,
			MinSize:              "0.000001",
			ContractMultiplier:   "1",
			QuotePrecision:       18,
			PricingModel:         PricingModelLinear,
			PriceSemantics:       PricingModelLinear,
			DisplayPriceKind:     DisplayPriceDirect,
			DisplaySemantics:     DisplayPriceDirect,
			DisplayLabel:         "cNGN per USDC",
			DisplayName:          "USDC/cNGN Perpetual",
			SettlementNote:       "USDC-settled perpetual on Base, on its own stack: a CashAsset over real USDC, its own SRM, security module and liquidation auction. PnL and funding settle in that cash; the trade leg moves only the difference between the fill and the mark.",
			OrderEntrySpec:       PerpOrderEntrySpec,
			UIPriceUnit:          "cNGN per USDC",
			UISizeUnit:           "USDC notional",
			UISideMeaning:        "BUY (long) gains when USD strengthens against NGN; SELL (short) gains when NGN strengthens. A UI long is a short of the on-chain cNGN perp.",
			EnginePriceUnit:      "USDC per cNGN",
			EngineAmountUnit:     "NGN contracts",
			EngineSidePolicy:     "invert_ui_side",
			UIPriceToEngine:      "engine_price = 1 / ui_price",
			UISizeToEngine:       "engine_amount = ui_size * ui_price",
			FundingInterval:      time.Hour,
			TradeModuleAddress:   strings.ToLower(strings.TrimSpace(cfg.CNGNPerpTradeModuleAddress)),
			QuoteAssetAddress:    strings.ToLower(strings.TrimSpace(cfg.CNGNPerpCashAddress)),
			MarginManagerAddress: strings.ToLower(strings.TrimSpace(cfg.CNGNPerpSRMAddress)),
			Enabled:              cfg.PerpEnabled(),
		},
	}

	return NewRegistry(items)
}
