package instruments

import (
	"reflect"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

func TestDefaultRegistryIncludesSpotByAssetAndSubID(t *testing.T) {
	cfg := config.Config{
		CNGNSpotAssetAddress: "0xF000000000000000000000000000000000000123",
	}

	registry := DefaultRegistry(cfg)

	item, ok := registry.ByAssetAndSubID("0xf000000000000000000000000000000000000123", "0")
	if !ok {
		t.Fatalf("spot market not found by asset/subId")
	}
	if item.Symbol != CNGNSpotSymbol {
		t.Fatalf("spot symbol = %q", item.Symbol)
	}
	if item.ContractType != "spot" {
		t.Fatalf("spot contract type = %q", item.ContractType)
	}
	if item.SettlementType != "spot" {
		t.Fatalf("spot settlement type = %q", item.SettlementType)
	}
	if item.BaseAssetSymbol != "cNGN" || item.QuoteAssetSymbol != "USDC" {
		t.Fatalf("spot unexpected base/quote %q/%q", item.BaseAssetSymbol, item.QuoteAssetSymbol)
	}
	if !item.Enabled {
		t.Fatalf("spot market should be enabled when its asset address is set")
	}
	if item.OrderEntrySpec != "cngn_usdc_spot_v1" || item.EngineSidePolicy != "same_as_ui" {
		t.Fatalf("spot spec/side policy = %q/%q", item.OrderEntrySpec, item.EngineSidePolicy)
	}
	perp, ok := registry.BySymbol(CNGNPerpSymbol)
	if !ok || perp.BaseAssetSymbol != "cNGN" || perp.QuoteAssetSymbol != "USDC" || perp.OrderEntrySpec != "cngn_usdc_perp_v1" {
		t.Fatalf("perp unexpected base/quote/spec %q/%q/%q", perp.BaseAssetSymbol, perp.QuoteAssetSymbol, perp.OrderEntrySpec)
	}
}

func TestDefaultRegistryDisablesSpotWithoutAssetAddress(t *testing.T) {
	registry := DefaultRegistry(config.Config{})

	item, ok := registry.BySymbol(CNGNSpotSymbol)
	if !ok {
		t.Fatalf("spot market missing from registry")
	}
	if item.Enabled {
		t.Fatalf("spot market should be disabled when no asset address is configured")
	}
	if len(registry.Enabled()) != 0 {
		t.Fatalf("no market should be enabled without configuration, got %d", len(registry.Enabled()))
	}
}

// Resolve is the one lookup every endpoint that takes a symbol, market or ticker_id goes through.
// It matches exactly or not at all: an identifier the venue does not list must be refused, never
// answered with another market's data. Before this, an unknown symbol fell through to spot.
func TestResolveMatchesExactlyOrNotAtAll(t *testing.T) {
	cfg := config.Config{
		CNGNSpotAssetAddress: "0xF000000000000000000000000000000000000123",
		CNGNPerpAssetAddress: "0xF000000000000000000000000000000000000456",
	}
	registry := DefaultRegistry(cfg)

	accepted := map[string]string{
		CNGNSpotSymbol: CNGNSpotSymbol,
		CNGNPerpSymbol: CNGNPerpSymbol,
		"0xf000000000000000000000000000000000000123:0": CNGNSpotSymbol,
		"0xF000000000000000000000000000000000000456:0": CNGNPerpSymbol, // a hex address has no case
		"  " + CNGNPerpSymbol + "  ":                   CNGNPerpSymbol, // surrounding whitespace only
	}
	for identifier, want := range accepted {
		item, ok := registry.Resolve(identifier)
		if !ok || item.Symbol != want {
			t.Errorf("Resolve(%q) = %q, %v; want %q", identifier, item.Symbol, ok, want)
		}
	}

	refused := []string{
		"",
		"usdccngn-spot",  // no case-folding of the symbol
		"cngn-usdc",      // nor of the canonical one
		"USDCcNGN",       // no prefix match
		"cNGN",           // likewise
		"USDCcNGN-SPOT-", // no suffix slack
		"cNGN-USDC-",     // likewise
		"USDCcNGN-SPOT:0",
		"USDC/cNGN",
		"cNGN-SPOT",
		"USDC-cNGN",
		"0xf000000000000000000000000000000000000123",   // the asset form needs its sub_id
		"0xf000000000000000000000000000000000000123:1", // unknown sub_id
		"0xf000000000000000000000000000000000000999:0", // unknown asset
		"BTC-PERP",
	}
	for _, identifier := range refused {
		if item, ok := registry.Resolve(identifier); ok {
			t.Errorf("Resolve(%q) = %q; want a refusal", identifier, item.Symbol)
		}
	}

	ids := registry.Identifiers()
	if len(ids) != 2 || ids[0] != CNGNSpotSymbol || ids[1] != CNGNPerpSymbol {
		t.Fatalf("Identifiers() = %v", ids)
	}
}

// The identifiers the markets were listed under before the rename resolve by exact match to the
// same instruments, flagged deprecated; the canonical symbols are not flagged.
func TestResolveAcceptsDeprecatedAliasesAsSuchOnly(t *testing.T) {
	cfg := config.Config{
		CNGNSpotAssetAddress: "0xF000000000000000000000000000000000000123",
		CNGNPerpAssetAddress: "0xF000000000000000000000000000000000000456",
	}
	registry := DefaultRegistry(cfg)

	cases := []struct {
		identifier string
		want       string
		deprecated bool
	}{
		{"cNGN-USDC", CNGNSpotSymbol, false},
		{"cNGN-PERP", CNGNPerpSymbol, false},
		{"USDCcNGN-SPOT", CNGNSpotSymbol, true},
		{"0xf000000000000000000000000000000000000456:0", CNGNPerpSymbol, false},
	}
	for _, c := range cases {
		item, deprecated, ok := registry.ResolveIdentifier(c.identifier)
		if !ok || item.Symbol != c.want || deprecated != c.deprecated {
			t.Errorf("ResolveIdentifier(%q) = %q, deprecated=%v, ok=%v; want %q, deprecated=%v", c.identifier, item.Symbol, deprecated, ok, c.want, c.deprecated)
		}
	}
	// The perp's pre-rename name is no longer an alias, even while the perp is listed.
	if item, _, ok := registry.ResolveIdentifier("USDCcNGN-PERP"); ok {
		t.Errorf("ResolveIdentifier(USDCcNGN-PERP) = %q; want unknown", item.Symbol)
	}
	if CNGNSpotSymbol != "cNGN-USDC" || CNGNPerpSymbol != "cNGN-PERP" {
		t.Fatalf("canonical symbols = %q / %q", CNGNSpotSymbol, CNGNPerpSymbol)
	}
	for _, alias := range []string{"usdccngn-spot", "USDCCNGN-PERP", "USDCcNGN-SPOT "} {
		if _, _, ok := registry.ResolveIdentifier(alias); ok && alias != "USDCcNGN-SPOT " {
			t.Errorf("alias %q matched inexactly", alias)
		}
	}
	// Only the canonical names are advertised.
	if ids := registry.Identifiers(); len(ids) != 2 || ids[0] != "cNGN-USDC" || ids[1] != "cNGN-PERP" {
		t.Fatalf("Identifiers() = %v", ids)
	}
}

func TestResolveRefusesDisabledMarkets(t *testing.T) {
	// Spot only: the perp is listed in the registry but not configured, so it must not resolve.
	registry := DefaultRegistry(config.Config{CNGNSpotAssetAddress: "0xF000000000000000000000000000000000000123"})
	if _, ok := registry.Resolve(CNGNPerpSymbol); ok {
		t.Fatalf("an unconfigured market resolved")
	}
	if ids := registry.Identifiers(); len(ids) != 1 || ids[0] != CNGNSpotSymbol {
		t.Fatalf("Identifiers() = %v", ids)
	}

	var none *Registry
	if _, ok := none.Resolve(CNGNSpotSymbol); ok {
		t.Fatalf("a nil registry resolved")
	}
	if ids := none.Identifiers(); ids != nil {
		t.Fatalf("nil registry Identifiers() = %v", ids)
	}
}

func TestTheFutureIsListedUnderItsExpiryOnlyWhenConfigured(t *testing.T) {
	if _, ok := DefaultRegistry(config.Config{}).BySymbol(FutureSymbol(1798675200)); ok {
		t.Fatal("no future is listed without CNGN_FUTURE_ASSET_ADDRESS")
	}
	cfg := config.Config{
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
		CNGNFutureAssetAddress:     "0x5555555555555555555555555555555555555555",
		CNGNFutureExpiry:           1798675200,
		CNGNFutureManagerAddress:   "0x6666666666666666666666666666666666666666",
	}
	future, ok := DefaultRegistry(cfg).ByAssetAndSubID("0x5555555555555555555555555555555555555555", "1798675200")
	if !ok {
		t.Fatal("the future is listed under (asset, expiry)")
	}
	if future.Symbol != "USDC-cNGN-31DEC26" || !future.IsFuture() || future.IsPerpetual() {
		t.Fatalf("future: %s %s", future.Symbol, future.ContractType)
	}
	// on the perp's TradeModule and cash, under the engine; no ui_intent contract
	if future.TradeModuleAddress != cfg.CNGNPerpTradeModuleAddress || future.QuoteAssetAddress != cfg.CNGNPerpCashAddress ||
		future.MarginManagerAddress != cfg.CNGNFutureManagerAddress || future.OrderEntrySpec != "" {
		t.Fatalf("future stack: %+v", future)
	}
	if future.TakerFeeBps != 25 || future.MakerFeeBps != 0 || future.ContractMultiplier != FutureContractSizeUSDC {
		t.Fatalf("future fees and size: %d/%d %s", future.TakerFeeBps, future.MakerFeeBps, future.ContractMultiplier)
	}
}

const testEURCEscrow = "0x00000000000000000000000000000000000E0dC0"

func TestEURCSpotIsListedOnlyWhenItsEscrowIsConfigured(t *testing.T) {
	off := DefaultRegistry(config.Config{CNGNSpotAssetAddress: "0xF000000000000000000000000000000000000123"})
	if _, ok := off.Resolve(EURCSpotSymbol); ok {
		t.Fatal("EURC-USDC resolved without EURC_SPOT_ASSET_ADDRESS")
	}
	if ids := off.Identifiers(); len(ids) != 1 || ids[0] != CNGNSpotSymbol {
		t.Fatalf("Identifiers() = %v without EURC configured", ids)
	}
	if len(DefaultRegistry(config.Config{}).Enabled()) != 0 {
		t.Fatal("a market is enabled with nothing configured")
	}

	cfg := config.Config{
		EURCSpotAssetAddress:     testEURCEscrow,
		TradeModuleAddress:       "0xDea968188598BA0E3F58A56C0fdfF338C74F699f",
		CashAssetAddress:         "0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272",
		SpotMarginManagerAddress: "0xA19E296021c9DF25b90D96C2A0793CC3D0800758",
	}
	item, ok := DefaultRegistry(cfg).Resolve(EURCSpotSymbol)
	if !ok {
		t.Fatal("EURC-USDC not listed with EURC_SPOT_ASSET_ADDRESS set")
	}
	if item.Symbol != "EURC-USDC" || item.AssetAddress != strings.ToLower(testEURCEscrow) || item.SubID != "0" ||
		item.ContractType != ContractTypeSpot || item.SettlementType != "spot" ||
		item.BaseAssetSymbol != "EURC" || item.QuoteAssetSymbol != "USDC" || len(item.Aliases) != 0 {
		t.Fatalf("EURC-USDC identity: %+v", item)
	}
	// Direct and linear, no inversion, and no ui_intent contract: orders are taken in engine units.
	if item.OrderEntrySpec != "" || item.EngineSidePolicy != "same_as_ui" || item.UIPriceUnit != "USDC per EURC" ||
		item.EnginePriceUnit != item.UIPriceUnit || item.UISizeUnit != "EURC amount" || item.EngineAmountUnit != item.UISizeUnit ||
		item.PricingModel != PricingModelLinear || item.DisplayPriceKind != DisplayPriceDirect || item.DisplayLabel != "USDC per EURC" {
		t.Fatalf("EURC-USDC orientation: %+v", item)
	}
	// Its own schedule, cNGN spot's units: 5 bps taker, 0 maker; desired_amount 1 = 1 EURC = 1e18 signed.
	if item.TakerFeeBps != 5 || item.MakerFeeBps != 0 || item.AmountScale != "1000000000000000000" ||
		item.TickSize != "0.000000000000000001" || item.MinSize != AmountStep || item.QuotePrecision != 18 || item.ContractMultiplier != "1" {
		t.Fatalf("EURC-USDC fees and units: %+v", item)
	}
	if item.UIPriceDecimals != 5 || item.UISizeDecimals != 6 {
		t.Fatalf("EURC-USDC display places = %d/%d", item.UIPriceDecimals, item.UISizeDecimals)
	}
	// The same TradeModule, quote and manager as cNGN spot.
	if item.TradeModuleAddress != strings.ToLower(cfg.TradeModuleAddress) || item.QuoteAssetAddress != strings.ToLower(cfg.CashAssetAddress) ||
		item.MarginManagerAddress != strings.ToLower(cfg.SpotMarginManagerAddress) || item.IsFuture() || item.IsPerpetual() {
		t.Fatalf("EURC-USDC stack: %+v", item)
	}
}

// Two spot markets on one TradeModule and manager: every lookup must answer each with its own metadata, never the
// other spot's. Nothing may pick "the" spot market by contract type.
func TestTwoSpotMarketsDoNotCollideInAnyLookup(t *testing.T) {
	cfg := config.Config{
		CNGNSpotAssetAddress: "0xF000000000000000000000000000000000000123",
		EURCSpotAssetAddress: testEURCEscrow,
		CNGNPerpAssetAddress: "0xF000000000000000000000000000000000000456",
	}
	registry := DefaultRegistry(cfg)

	want := map[string]string{
		CNGNSpotSymbol:           CNGNSpotSymbol,
		EURCSpotSymbol:           EURCSpotSymbol,
		CNGNSpotDeprecatedSymbol: CNGNSpotSymbol,
		"0xf000000000000000000000000000000000000123:0": CNGNSpotSymbol,
		strings.ToLower(testEURCEscrow) + ":0":         EURCSpotSymbol,
		testEURCEscrow + ":0":                          EURCSpotSymbol,
	}
	for identifier, symbol := range want {
		if item, ok := registry.Resolve(identifier); !ok || item.Symbol != symbol {
			t.Errorf("Resolve(%q) = %q, %v; want %q", identifier, item.Symbol, ok, symbol)
		}
	}
	if item, ok := registry.ByAssetAndSubID(strings.ToLower(testEURCEscrow), "0"); !ok || item.Symbol != EURCSpotSymbol || item.BaseAssetSymbol != "EURC" {
		t.Fatalf("ByAssetAndSubID(EURC escrow) = %+v, %v", item, ok)
	}
	if item, ok := registry.ByAssetAddress("0xf000000000000000000000000000000000000123"); !ok || item.Symbol != CNGNSpotSymbol || item.BaseAssetSymbol != "cNGN" {
		t.Fatalf("ByAssetAddress(cNGN escrow) = %+v, %v", item, ok)
	}
	for _, refused := range []string{"eurc-usdc", "EURC", "USDC-EURC", "EURC/USDC", strings.ToLower(testEURCEscrow) + ":1"} {
		if item, ok := registry.Resolve(refused); ok {
			t.Errorf("Resolve(%q) = %q; want a refusal", refused, item.Symbol)
		}
	}
	if ids := registry.Identifiers(); len(ids) != 3 || ids[0] != CNGNSpotSymbol || ids[1] != EURCSpotSymbol || ids[2] != CNGNPerpSymbol {
		t.Fatalf("Identifiers() = %v", ids)
	}
	spots := 0
	for _, item := range registry.Enabled() {
		if item.ContractType == ContractTypeSpot {
			spots++
		}
	}
	if spots != 2 {
		t.Fatalf("enabled spot markets = %d, want 2", spots)
	}
}

// v1's series and v2's cNGN and EURC series at one expiry are three markets: each found under its own
// (asset, expiry) and its own symbol, v1's under the name the app and the makers route by.
func TestSeriesAtOneExpiryAreDistinctMarkets(t *testing.T) {
	const (
		v1, v2CNGN, v2EURC = "0x00000000000000000000000000000000000000f1", "0x00000000000000000000000000000000000000f2", "0x00000000000000000000000000000000000000f3"
		v2Engine           = "0x00000000000000000000000000000000000000e2"
	)
	cfg := config.Config{
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
		CNGNFutureAssetAddress:     v1, CNGNFutureExpiry: 1796047200, CNGNFutureManagerAddress: "0x00000000000000000000000000000000000000e1",
		FutureSeries: []config.FutureSeries{
			{AssetAddress: v2CNGN, Expiry: 1796047200, ManagerAddress: v2Engine, Kind: config.FutureKindLinear, BaseAsset: "cNGN", ContractSize: "1000000"},
			{AssetAddress: v2EURC, Expiry: 1796047200, ManagerAddress: v2Engine, Kind: config.FutureKindLinear, BaseAsset: "EURC", ContractSize: "1000"},
		},
	}
	registry := DefaultRegistry(cfg)
	for asset, want := range map[string]struct{ symbol, base, quote, unit, scale string }{
		v1:     {"USDC-cNGN-30NOV26", "USDC", "cNGN", "cNGN per USDC", FutureAmountScale},
		v2CNGN: {"cNGN-30NOV26", "cNGN", "USDC", "USDC per cNGN", "1000000000000"},
		v2EURC: {"EURC-30NOV26", "EURC", "USDC", "USDC per EURC", "1000000000000000"},
	} {
		byKey, ok := registry.ByAssetAndSubID(asset, "1796047200")
		bySymbol, okSymbol := registry.BySymbol(want.symbol)
		if !ok || !okSymbol || byKey.AssetAddress != bySymbol.AssetAddress || byKey.Symbol != want.symbol {
			t.Fatalf("%s: by key %v %s, by symbol %v %s", want.symbol, ok, byKey.Symbol, okSymbol, bySymbol.AssetAddress)
		}
		if byKey.BaseAssetSymbol != want.base || byKey.QuoteAssetSymbol != want.quote || byKey.EnginePriceUnit != want.unit ||
			byKey.AmountScale != want.scale || byKey.LinearFuture() != (asset != v1) {
			t.Errorf("%s: %+v", want.symbol, byKey)
		}
	}
}

// The single-series envs and the same series written as a FUTURE_SERIES entry list the same market.
func TestTheLegacySeriesIsTheSameMarketEitherWayItIsConfigured(t *testing.T) {
	stack := config.Config{
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
	}
	legacy := stack
	legacy.CNGNFutureAssetAddress, legacy.CNGNFutureExpiry, legacy.CNGNFutureManagerAddress =
		"0x5555555555555555555555555555555555555555", 1796047200, "0x6666666666666666666666666666666666666666"
	listed := stack
	listed.FutureSeries = []config.FutureSeries{{AssetAddress: "0x5555555555555555555555555555555555555555", Expiry: 1796047200,
		ManagerAddress: "0x6666666666666666666666666666666666666666", Kind: config.FutureKindInverse, BaseAsset: "cNGN", ContractSize: "1000"}}
	a, _ := DefaultRegistry(legacy).BySymbol("USDC-cNGN-30NOV26")
	b, _ := DefaultRegistry(listed).BySymbol("USDC-cNGN-30NOV26")
	if !reflect.DeepEqual(a, b) || a.Symbol == "" {
		t.Fatalf("legacy %+v\nlisted %+v", a, b)
	}
}
