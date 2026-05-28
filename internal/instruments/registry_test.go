package instruments

import (
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

func TestDefaultRegistryIncludesDeliverableFutureByAssetAndSubID(t *testing.T) {
	cfg := config.Config{
		CNGNJun2026FutureAssetAddress: "0xF000000000000000000000000000000000000123",
		CNGNJun2026FutureSubID:        "1782777600",
		CNGNNov2026FutureAssetAddress: "0xF000000000000000000000000000000000000456",
		CNGNNov2026FutureSubID:        "1795996800",
		CNGNMay2027FutureAssetAddress: "0xF000000000000000000000000000000000000789",
		CNGNMay2027FutureSubID:        "1811721600",
	}

	registry := DefaultRegistry(cfg)

	// Verify June Future
	item, ok := registry.ByAssetAndSubID("0xf000000000000000000000000000000000000123", "1782777600")
	if !ok {
		t.Fatalf("June deliverable future not found by asset/subId")
	}

	if item.Symbol != CNGNJun2026Symbol {
		t.Fatalf("June symbol = %q", item.Symbol)
	}
	if item.ContractType != "deliverable_fx_future" {
		t.Fatalf("June contract type = %q", item.ContractType)
	}
	if item.SettlementType != "physical_delivery" {
		t.Fatalf("June settlement type = %q", item.SettlementType)
	}
	if item.BaseAssetSymbol != "USDC" || item.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("June unexpected base/quote %q/%q", item.BaseAssetSymbol, item.QuoteAssetSymbol)
	}
	if item.SubID != "1782777600" {
		t.Fatalf("June subId = %q", item.SubID)
	}
	if !item.Enabled {
		t.Fatalf("June deliverable future should be enabled when both env vars are set")
	}

	// Verify November Future
	itemNov, okNov := registry.ByAssetAndSubID("0xf000000000000000000000000000000000000456", "1795996800")
	if !okNov {
		t.Fatalf("November deliverable future not found by asset/subId")
	}

	if itemNov.Symbol != CNGNNov2026Symbol {
		t.Fatalf("November symbol = %q", itemNov.Symbol)
	}
	if itemNov.ContractType != "deliverable_fx_future" {
		t.Fatalf("November contract type = %q", itemNov.ContractType)
	}
	if itemNov.SettlementType != "physical_delivery" {
		t.Fatalf("November settlement type = %q", itemNov.SettlementType)
	}
	if itemNov.BaseAssetSymbol != "USDC" || itemNov.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("November unexpected base/quote %q/%q", itemNov.BaseAssetSymbol, itemNov.QuoteAssetSymbol)
	}
	if itemNov.SubID != "1795996800" {
		t.Fatalf("November subId = %q", itemNov.SubID)
	}
	if !itemNov.Enabled {
		t.Fatalf("November deliverable future should be enabled when both env vars are set")
	}

	// Verify May 2027 Future
	itemMay, okMay := registry.ByAssetAndSubID("0xf000000000000000000000000000000000000789", "1811721600")
	if !okMay {
		t.Fatalf("May 2027 deliverable future not found by asset/subId")
	}

	if itemMay.Symbol != CNGNMay2027Symbol {
		t.Fatalf("May 2027 symbol = %q", itemMay.Symbol)
	}
	if itemMay.ContractType != "deliverable_fx_future" {
		t.Fatalf("May 2027 contract type = %q", itemMay.ContractType)
	}
	if itemMay.SettlementType != "physical_delivery" {
		t.Fatalf("May 2027 settlement type = %q", itemMay.SettlementType)
	}
	if itemMay.BaseAssetSymbol != "USDC" || itemMay.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("May 2027 unexpected base/quote %q/%q", itemMay.BaseAssetSymbol, itemMay.QuoteAssetSymbol)
	}
	if itemMay.SubID != "1811721600" {
		t.Fatalf("May 2027 subId = %q", itemMay.SubID)
	}
	if !itemMay.Enabled {
		t.Fatalf("May 2027 deliverable future should be enabled when both env vars are set")
	}
}

func TestDefaultRegistryResolvesLegacyDisplaySymbolAlias(t *testing.T) {
	cfg := config.Config{
		CNGNJun2026FutureAssetAddress: "0xF000000000000000000000000000000000000123",
		CNGNJun2026FutureSubID:        "1782777600",
		CNGNNov2026FutureAssetAddress: "0xF000000000000000000000000000000000000456",
		CNGNNov2026FutureSubID:        "1795996800",
		CNGNMay2027FutureAssetAddress: "0xF000000000000000000000000000000000000789",
		CNGNMay2027FutureSubID:        "1811721600",
	}

	registry := DefaultRegistry(cfg)

	// Verify June Legacy resolving
	item, ok := registry.BySymbol(CNGNJun2026LegacySymbol)
	if !ok {
		t.Fatalf("June deliverable future not found by legacy display symbol")
	}
	if item.Symbol != CNGNJun2026Symbol {
		t.Fatalf("June canonical symbol = %q", item.Symbol)
	}

	// Verify November Legacy resolving
	itemNov, okNov := registry.BySymbol(CNGNNov2026LegacySymbol)
	if !okNov {
		t.Fatalf("November deliverable future not found by legacy display symbol")
	}
	if itemNov.Symbol != CNGNNov2026Symbol {
		t.Fatalf("November canonical symbol = %q", itemNov.Symbol)
	}

	// Verify May 2027 Legacy resolving
	itemMay, okMay := registry.BySymbol(CNGNMay2027LegacySymbol)
	if !okMay {
		t.Fatalf("May 2027 deliverable future not found by legacy display symbol")
	}
	if itemMay.Symbol != CNGNMay2027Symbol {
		t.Fatalf("May 2027 canonical symbol = %q", itemMay.Symbol)
	}
}


