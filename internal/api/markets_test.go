package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

func TestHandleMarketsIncludesDeliverableFutureMetadata(t *testing.T) {
	registry := instruments.DefaultRegistry(config.Config{
		CNGNSep2026FutureAssetAddress: "0xf000000000000000000000000000000000000123",
		CNGNSep2026FutureSubID:        "1789567201",
		CNGNNov2026FutureAssetAddress: "0xf000000000000000000000000000000000000456",
		CNGNNov2026FutureSubID:        "1795996800",
		CNGNMay2027FutureAssetAddress: "0xf000000000000000000000000000000000000789",
		CNGNMay2027FutureSubID:        "1811721600",
	})

	server := NewServer(config.Config{}, nil, registry)

	req := httptest.NewRequest(http.MethodGet, "/v1/markets", nil)
	rec := httptest.NewRecorder()
	server.handleMarkets(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}

	var markets []marketPresentation
	if err := json.Unmarshal(rec.Body.Bytes(), &markets); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	// Verify June Future
	var found *marketPresentation
	for i := range markets {
		if markets[i].Market == instruments.CNGNSep2026Symbol {
			found = &markets[i]
			break
		}
	}
	if found == nil {
		t.Fatal("June deliverable future missing from markets response")
	}

	if found.ContractType != "deliverable_fx_future" {
		t.Fatalf("June contract type = %q", found.ContractType)
	}
	if found.SettlementType != "physical_delivery" {
		t.Fatalf("June settlement type = %q", found.SettlementType)
	}
	if found.AssetAddress != "0xf000000000000000000000000000000000000123" {
		t.Fatalf("June asset address = %q", found.AssetAddress)
	}
	if found.SubID != "1789567201" {
		t.Fatalf("June sub id = %q", found.SubID)
	}
	if found.ExpiryTimestamp != 1789567201 {
		t.Fatalf("June unexpected expiry window %+v", found)
	}
	if found.LastTradeTimestamp != nil {
		t.Fatalf("June expected nil last_trade_timestamp without trade history, got %+v", found)
	}
	if found.BaseAssetSymbol != "USDC" || found.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("June unexpected base/quote %q/%q", found.BaseAssetSymbol, found.QuoteAssetSymbol)
	}
	if found.TickSize != "1" {
		t.Fatalf("June tick size = %q", found.TickSize)
	}

	// Verify November Future
	var foundNov *marketPresentation
	for i := range markets {
		if markets[i].Market == instruments.CNGNNov2026Symbol {
			foundNov = &markets[i]
			break
		}
	}
	if foundNov == nil {
		t.Fatal("November deliverable future missing from markets response")
	}

	if foundNov.ContractType != "deliverable_fx_future" {
		t.Fatalf("November contract type = %q", foundNov.ContractType)
	}
	if foundNov.SettlementType != "physical_delivery" {
		t.Fatalf("November settlement type = %q", foundNov.SettlementType)
	}
	if foundNov.AssetAddress != "0xf000000000000000000000000000000000000456" {
		t.Fatalf("November asset address = %q", foundNov.AssetAddress)
	}
	if foundNov.SubID != "1795996800" {
		t.Fatalf("November sub id = %q", foundNov.SubID)
	}
	if foundNov.ExpiryTimestamp != 1795996800 {
		t.Fatalf("November unexpected expiry window %+v", foundNov)
	}
	if foundNov.LastTradeTimestamp != nil {
		t.Fatalf("November expected nil last_trade_timestamp without trade history, got %+v", foundNov)
	}
	if foundNov.BaseAssetSymbol != "USDC" || foundNov.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("November unexpected base/quote %q/%q", foundNov.BaseAssetSymbol, foundNov.QuoteAssetSymbol)
	}
	if foundNov.TickSize != "1" {
		t.Fatalf("November tick size = %q", foundNov.TickSize)
	}

	// Verify May 2027 Future
	var foundMay *marketPresentation
	for i := range markets {
		if markets[i].Market == instruments.CNGNMay2027Symbol {
			foundMay = &markets[i]
			break
		}
	}
	if foundMay == nil {
		t.Fatal("May 2027 deliverable future missing from markets response")
	}

	if foundMay.ContractType != "deliverable_fx_future" {
		t.Fatalf("May 2027 contract type = %q", foundMay.ContractType)
	}
	if foundMay.SettlementType != "physical_delivery" {
		t.Fatalf("May 2027 settlement type = %q", foundMay.SettlementType)
	}
	if foundMay.AssetAddress != "0xf000000000000000000000000000000000000789" {
		t.Fatalf("May 2027 asset address = %q", foundMay.AssetAddress)
	}
	if foundMay.SubID != "1811721600" {
		t.Fatalf("May 2027 sub id = %q", foundMay.SubID)
	}
	if foundMay.ExpiryTimestamp != 1811721600 {
		t.Fatalf("May 2027 unexpected expiry window %+v", foundMay)
	}
	if foundMay.LastTradeTimestamp != nil {
		t.Fatalf("May 2027 expected nil last_trade_timestamp without trade history, got %+v", foundMay)
	}
	if foundMay.BaseAssetSymbol != "USDC" || foundMay.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("May 2027 unexpected base/quote %q/%q", foundMay.BaseAssetSymbol, foundMay.QuoteAssetSymbol)
	}
	if foundMay.TickSize != "1" {
		t.Fatalf("May 2027 tick size = %q", foundMay.TickSize)
	}
}

