package instruments

import (
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

const (
	// The market identifiers, in base-quote order: cNGN is the base, priced in USDC per cNGN. These
	// are what every response and websocket frame carries as market, symbol or ticker_id.
	CNGNSpotSymbol = "cNGN-USDC"
	CNGNPerpSymbol = "cNGN-PERP"

	// The identifier spot was listed under before the rename, inverted relative to how it is quoted.
	// Accepted anywhere an identifier is, by exact match, and answered with the canonical name and a
	// Deprecation header; never emitted. The perp's old name, USDCcNGN-PERP, is no longer an alias:
	// the perp is being delisted, and both its names are an unknown market once it is.
	CNGNSpotDeprecatedSymbol = "USDCcNGN-SPOT"

	CNGNSpotLegacySymbol = "USDC/cNGN"

	// EURCSpotSymbol is the second spot market: EURC the base, priced in USDC per EURC (~1.12). Unlike
	// every cNGN market it was never listed under another name, so it has no aliases, and it carries
	// no ui_intent contract: the engine order is the UI order, taken on the plain native path.
	EURCSpotSymbol = "EURC-USDC"

	// FutureContractSizeUSDC is one contract of the cNGN future, in USDC: FutureAsset.contractSize()
	// at 18dp, checked against the chain when the matcher starts. It is the future's fee notional.
	FutureContractSizeUSDC = "1000"

	// FutureAmountScale is the future's unit: one USDC of notional, 0.001 of a contract, signed as 1e15
	// of the FutureAsset's 1e18-per-contract amount. Sizes are whole USDC, so the smallest order is
	// 1 USDC. It was one whole contract (1,000 USDC) until 2026-10-14, a minimum nobody chose: the
	// whole-unit step every market shares is a cNGN on spot and the perp.
	FutureAmountScale = "1000000000000000"

	// SpotAmountScale is spot's unit: one whole base token (cNGN, EURC), signed as 1e18 of the escrow's
	// 18dp amount: what the app and the market maker sign. Fixed since 2026-10-14 so the matcher can tell which order of a
	// pair is off it; before, intake took any whole scale and two orders at different ones could not
	// trade. The perp, close-only and winding down, keeps taking any.
	SpotAmountScale = "1000000000000000000"

	// The UI contract is the engine's own orientation: cNGN is the base, priced in USDC per cNGN,
	// sized in cNGN, and a UI buy is an engine buy. ui_intent translates to the engine order as the
	// identity; the specs exist so an intent signed for one market cannot be replayed on the other.
	SpotOrderEntrySpec = "cngn_usdc_spot_v1"
	PerpOrderEntrySpec = "cngn_usdc_perp_v1"
)

func DefaultRegistry(cfg config.Config) *Registry {
	items := []Metadata{
		{
			Symbol:           CNGNSpotSymbol,
			Aliases:          []string{CNGNSpotDeprecatedSymbol},
			AssetAddress:     strings.ToLower(strings.TrimSpace(cfg.CNGNSpotAssetAddress)),
			SubID:            "0",
			ContractType:     ContractTypeSpot,
			SettlementType:   "spot",
			BaseAssetSymbol:  "cNGN",
			QuoteAssetSymbol: "USDC",
			TickSize:         "0.000000000000000001",
			// 25 bps taker, 0 maker. Charged in the trade module's quote asset -- wrapped USDC
			// since the 2026-09-10 cutover -- and paid to the module's feeRecipient.
			TakerFeeBps:        25,
			MakerFeeBps:        0,
			MinSize:            AmountStep,
			ContractMultiplier: "1",
			AmountScale:        SpotAmountScale,
			QuotePrecision:     18,
			PricingModel:       PricingModelLinear,
			PriceSemantics:     PricingModelLinear,
			DisplayPriceKind:   DisplayPriceDirect,
			DisplaySemantics:   DisplayPriceDirect,
			DisplayLabel:       "USDC per cNGN",
			DisplayName:        "cNGN-USDC",
			SettlementNote:     "Spot-style orderbook market on Base. Trades exchange WRAPPED_CNGN against the quote asset of the configured TradeModule (TRADE_MODULE_ADDRESS / QUOTE_ASSET_ADDRESS): the internal USDC cash ledger under the cash-quoted module, or the wrapped USDC asset under the wrapped-quote module, in which case both legs are 1:1 token-backed.",
			OrderEntrySpec:     SpotOrderEntrySpec,
			UIPriceUnit:        "USDC per cNGN",
			UISizeUnit:         "cNGN amount",
			UISideMeaning:      "BUY acquires cNGN and pays USDC; SELL delivers cNGN and receives USDC.",
			EnginePriceUnit:    "USDC per cNGN",
			EngineAmountUnit:   "cNGN amount",
			EngineSidePolicy:   "same_as_ui",
			UIPriceToEngine:    "engine_price = ui_price",
			UISizeToEngine:     "engine_amount = ui_size",
			TradeModuleAddress: strings.ToLower(strings.TrimSpace(cfg.TradeModuleAddress)),
			QuoteAssetAddress:  strings.ToLower(strings.TrimSpace(cfg.QuoteAsset())),
			// Set when spot runs on the perp stack (SPOT_MARGIN_MANAGER_ADDRESS = the perp SRM).
			MarginManagerAddress: strings.ToLower(strings.TrimSpace(cfg.SpotMarginManagerAddress)),
			Enabled:              strings.TrimSpace(cfg.CNGNSpotAssetAddress) != "",
			UIPriceDecimals:      10,
			UISizeDecimals:       6,
		},
		eurcSpotMetadata(cfg),
		{
			// The perp is a cNGN perp: denominated on chain in USDC per cNGN (~0.00072), sized in
			// cNGN, so PnL lands in USDC cash with no conversion. The venue shows it exactly so,
			// like spot: a UI long is the on-chain long of the cNGN perp.
			Symbol:                 CNGNPerpSymbol,
			AssetAddress:           strings.ToLower(strings.TrimSpace(cfg.CNGNPerpAssetAddress)),
			SubID:                  "0",
			ContractType:           ContractTypePerpetual,
			SettlementType:         "cash_settled_perpetual",
			BaseAssetSymbol:        "cNGN",
			QuoteAssetSymbol:       "USDC",
			TickSize:               "0.000000000000000001",
			TakerFeeBps:            25,
			MakerFeeBps:            0,
			MinSize:                AmountStep,
			ContractMultiplier:     "1",
			QuotePrecision:         18,
			PricingModel:           PricingModelLinear,
			PriceSemantics:         PricingModelLinear,
			DisplayPriceKind:       DisplayPriceDirect,
			DisplaySemantics:       DisplayPriceDirect,
			DisplayLabel:           "USDC per cNGN",
			DisplayName:            "cNGN-PERP",
			SettlementNote:         "USDC-settled perpetual on Base, on its own stack: a CashAsset over real USDC, its own SRM, security module and liquidation auction. PnL and funding settle in that cash; the trade leg moves only the difference between the fill and the mark.",
			OrderEntrySpec:         PerpOrderEntrySpec,
			UIPriceUnit:            "USDC per cNGN",
			UISizeUnit:             "cNGN contracts",
			UISideMeaning:          "BUY (long) gains when cNGN strengthens against USD; SELL (short) gains when USD strengthens. A UI long is a long of the on-chain cNGN perp.",
			EnginePriceUnit:        "USDC per cNGN",
			EngineAmountUnit:       "cNGN contracts",
			EngineSidePolicy:       "same_as_ui",
			UIPriceToEngine:        "engine_price = ui_price",
			UISizeToEngine:         "engine_amount = ui_size",
			FundingInterval:        time.Hour,
			TradeModuleAddress:     strings.ToLower(strings.TrimSpace(cfg.CNGNPerpTradeModuleAddress)),
			QuoteAssetAddress:      strings.ToLower(strings.TrimSpace(cfg.CNGNPerpCashAddress)),
			MarginManagerAddress:   strings.ToLower(strings.TrimSpace(cfg.CNGNPerpSRMAddress)),
			CollateralAssetAddress: strings.ToLower(strings.TrimSpace(cfg.CNGNPerpCollateralAddress)),
			Enabled:                cfg.PerpEnabled(),
			UIPriceDecimals:        10,
			UISizeDecimals:         6,
		},
	}
	for _, series := range cfg.FutureSeriesList() {
		items = append(items, futureMetadata(cfg, series))
	}

	return NewRegistry(items)
}

// eurcSpotMetadata is EURC-USDC: a WrappedERC20Asset escrow of Base EURC (EURC_SPOT_ASSET_ADDRESS)
// under the same MarginEngine, TradeModule and quote asset as cNGN-USDC, so it reads the process-wide
// TRADE_MODULE_ADDRESS / QUOTE_ASSET_ADDRESS and SPOT_MARGIN_MANAGER_ADDRESS exactly as cNGN spot does.
// Listed only when the escrow is configured. Direct and linear: EURC is the base, priced in USDC per
// EURC, sized in whole EURC (desired_amount 1 = 1 EURC, signed as 1e18 of the escrow's 18dp amount),
// and a UI buy is an engine buy. Orders are taken in engine units only: there is no ui_intent
// contract (order_entry_spec) because there is nothing to translate.
func eurcSpotMetadata(cfg config.Config) Metadata {
	return Metadata{
		Symbol:           EURCSpotSymbol,
		AssetAddress:     strings.ToLower(strings.TrimSpace(cfg.EURCSpotAssetAddress)),
		SubID:            "0",
		ContractType:     ContractTypeSpot,
		SettlementType:   "spot",
		BaseAssetSymbol:  "EURC",
		QuoteAssetSymbol: "USDC",
		TickSize:         "0.000000000000000001",
		// 5 bps taker, 0 maker (set 2026-10-21: a stable pair, priced against EURC/USDC pools that charge
		// 1-5 bps): charged in the trade module's quote asset and paid to the module's feeRecipient.
		TakerFeeBps:        5,
		MakerFeeBps:        0,
		MinSize:            AmountStep,
		ContractMultiplier: "1",
		AmountScale:        SpotAmountScale,
		QuotePrecision:     18,
		PricingModel:       PricingModelLinear,
		PriceSemantics:     PricingModelLinear,
		DisplayPriceKind:   DisplayPriceDirect,
		DisplaySemantics:   DisplayPriceDirect,
		DisplayLabel:       "USDC per EURC",
		DisplayName:        EURCSpotSymbol,
		SettlementNote:     "Spot-style orderbook market on Base, under the MarginEngine. Trades exchange wrapped EURC (a WrappedERC20Asset escrow of Base EURC, 18dp internal balances) against the quote asset of the configured TradeModule (TRADE_MODULE_ADDRESS / QUOTE_ASSET_ADDRESS), the same module and quote as cNGN-USDC. EURC also counts as margin on the engine.",
		UIPriceUnit:        "USDC per EURC",
		UISizeUnit:         "EURC amount",
		UISideMeaning:      "BUY acquires EURC and pays USDC; SELL delivers EURC and receives USDC.",
		EnginePriceUnit:    "USDC per EURC",
		EngineAmountUnit:   "EURC amount",
		EngineSidePolicy:   "same_as_ui",
		UIPriceToEngine:    "engine_price = ui_price",
		UISizeToEngine:     "engine_amount = ui_size",
		TradeModuleAddress: strings.ToLower(strings.TrimSpace(cfg.TradeModuleAddress)),
		QuoteAssetAddress:  strings.ToLower(strings.TrimSpace(cfg.QuoteAsset())),
		// Both spots are under the MarginEngine, so they share SPOT_MARGIN_MANAGER_ADDRESS.
		MarginManagerAddress: strings.ToLower(strings.TrimSpace(cfg.SpotMarginManagerAddress)),
		Enabled:              strings.TrimSpace(cfg.EURCSpotAssetAddress) != "",
		// ~1.12 USDC per EURC: five places is a hundredth of a basis point.
		UIPriceDecimals: 5,
		UISizeDecimals:  6,
	}
}

// FutureSymbol names a v1 series by its expiry: USDC-cNGN-31DEC26. USDC is the base, as the v1 future
// is quoted in cNGN per USDC. A v2 series is <BASE>-<DDMONYY> (config.FutureSeries.MarketSymbol).
func FutureSymbol(expiry int64) string {
	return config.FutureSeries{Kind: config.FutureKindInverse, Expiry: expiry}.MarketSymbol()
}

// futureMetadata is a FutureAsset series under its engine, on the perp's TradeModule and cash. Orders
// are taken in engine units only (no order_entry_spec): there is no ui_intent contract for a future.
func futureMetadata(cfg config.Config, series config.FutureSeries) Metadata {
	if series.Linear() {
		return linearFutureMetadata(cfg, series)
	}
	return Metadata{
		Symbol:           series.MarketSymbol(),
		AssetAddress:     series.AssetAddress,
		SubID:            series.SubID(),
		ContractType:     ContractTypeFuture,
		SettlementType:   "cash_settled_future",
		BaseAssetSymbol:  "USDC",
		QuoteAssetSymbol: "cNGN",
		ExpiryTimestamp:  series.Expiry,
		TickSize:         "0.000000000000000001",
		// 25 bps taker, 0 maker, of the notional: contracts x FutureContractSizeUSDC, charged in the
		// perp's USDC cash and paid to the TradeModule's feeRecipient. 2.5 USDC a contract (0.0025 a
		// unit); worstFee is per contract on chain, so a taker's must still be at least 2.5e18.
		TakerFeeBps:          25,
		MakerFeeBps:          0,
		MinSize:              AmountStep,
		ContractMultiplier:   FutureContractSizeUSDC,
		AmountScale:          FutureAmountScale,
		QuotePrecision:       18,
		PricingModel:         PricingModelLinear,
		PriceSemantics:       PricingModelLinear,
		DisplayPriceKind:     DisplayPriceDirect,
		DisplaySemantics:     DisplayPriceDirect,
		DisplayLabel:         "cNGN per USDC",
		DisplayName:          series.MarketSymbol(),
		SettlementNote:       "Cash-settled cNGN future on Base, under the MarginEngine. One contract is 1,000 USDC, and orders are sized in whole USDC of notional (desired_amount 1 = 0.001 contract, signed as 1e15); variation margin accrues in cNGN at each mark, Δmark x contract size, and the series settles at a TWAP of the index over its fixing window. A fill carries its price and moves no quote leg; the chain refuses one outside the index band (fill_band_low to fill_band_high), and so does the venue.",
		UIPriceUnit:          "cNGN per USDC",
		UISizeUnit:           "USDC of notional (1,000 a contract)",
		UISideMeaning:        "BUY (long) gains when cNGN weakens against USD (more cNGN per USDC); SELL (short) gains when it strengthens.",
		EnginePriceUnit:      "cNGN per USDC",
		EngineAmountUnit:     "USDC of notional",
		EngineSidePolicy:     "same_as_ui",
		UIPriceToEngine:      "engine_price = ui_price",
		UISizeToEngine:       "engine_amount = ui_size (signed as ui_size x 1e15: ui_size / 1000 contracts)",
		TradeModuleAddress:   strings.ToLower(strings.TrimSpace(cfg.CNGNPerpTradeModuleAddress)),
		QuoteAssetAddress:    strings.ToLower(strings.TrimSpace(cfg.CNGNPerpCashAddress)),
		MarginManagerAddress: series.ManagerAddress,
		Enabled:              true,
		FutureKind:           config.FutureKindInverse,
		CloseOnly:            series.CloseOnly,
	}
}

// linearFutureMetadata is a MarginEngine v2 series, <BASE>-<expiry>: priced in USDC per base as spot is,
// one contract ContractSize base units, sized in whole base units of notional by default, VM in USDC.
func linearFutureMetadata(cfg config.Config, series config.FutureSeries) Metadata {
	base, size, scale := series.BaseAsset, series.ContractSize, series.ScaledAmount()
	return Metadata{
		Symbol:           series.MarketSymbol(),
		AssetAddress:     series.AssetAddress,
		SubID:            series.SubID(),
		ContractType:     ContractTypeFuture,
		SettlementType:   "cash_settled_future",
		BaseAssetSymbol:  base,
		QuoteAssetSymbol: "USDC",
		ExpiryTimestamp:  series.Expiry,
		TickSize:         "0.000000000000000001",
		// 25 bps taker, 0 maker, of the notional: contracts x contract size x the fill price, in USDC,
		// charged in the perp's USDC cash and paid to the TradeModule's feeRecipient.
		TakerFeeBps:        25,
		MakerFeeBps:        0,
		MinSize:            AmountStep,
		ContractMultiplier: size,
		AmountScale:        scale,
		QuotePrecision:     18,
		PricingModel:       PricingModelLinear,
		PriceSemantics:     PricingModelLinear,
		DisplayPriceKind:   DisplayPriceDirect,
		DisplaySemantics:   DisplayPriceDirect,
		DisplayLabel:       "USDC per " + base,
		DisplayName:        series.MarketSymbol(),
		SettlementNote: "Cash-settled " + base + " future on Base, under MarginEngine v2. One contract is " + groupThousands(size) + " " + base +
			", and orders are sized in " + base + " of notional (desired_amount 1 signed as " + scale + " of the FutureAsset's 1e18 a contract); variation margin accrues in USDC at each mark, Δmark x contract size, and the series settles at a TWAP of the index over its fixing window. A fill carries its price and moves no quote leg; the chain refuses one outside the index band (fill_band_low to fill_band_high), and so does the venue.",
		UIPriceUnit:          "USDC per " + base,
		UISizeUnit:           base + " of notional (" + groupThousands(size) + " a contract)",
		UISideMeaning:        "BUY (long) gains when " + base + " strengthens against USD (more USDC per " + base + "); SELL (short) gains when it weakens.",
		EnginePriceUnit:      "USDC per " + base,
		EngineAmountUnit:     base + " of notional",
		EngineSidePolicy:     "same_as_ui",
		UIPriceToEngine:      "engine_price = ui_price",
		UISizeToEngine:       "engine_amount = ui_size (signed as ui_size x " + scale + ": ui_size / " + size + " contracts)",
		TradeModuleAddress:   strings.ToLower(strings.TrimSpace(cfg.CNGNPerpTradeModuleAddress)),
		QuoteAssetAddress:    strings.ToLower(strings.TrimSpace(cfg.CNGNPerpCashAddress)),
		MarginManagerAddress: series.ManagerAddress,
		Enabled:              true,
		FutureKind:           config.FutureKindLinear,
		CloseOnly:            series.CloseOnly,
	}
}

// groupThousands writes a whole number with thousands separators: 1000000 -> 1,000,000. Anything else
// is returned as is.
func groupThousands(value string) string {
	if value == "" || strings.Trim(value, "0123456789") != "" {
		return value
	}
	var out []byte
	for i := range len(value) {
		if i > 0 && (len(value)-i)%3 == 0 {
			out = append(out, ',')
		}
		out = append(out, value[i])
	}
	return string(out)
}
