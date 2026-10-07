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
