package instruments

import (
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
		"cNGN-PERP",      // the display name, not (yet) an identifier
		"cNGN-USDC",      // likewise
		"usdccngn-spot",  // no case-folding of the symbol
		"USDCcNGN",       // no prefix match
		"USDCcNGN-SPOT-", // no suffix slack
		"USDCcNGN-SPOT:0",
		"USDC/cNGN",
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
