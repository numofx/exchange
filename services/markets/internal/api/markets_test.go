package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

func TestHandleMarketsIncludesSpotMetadata(t *testing.T) {
	registry := instruments.DefaultRegistry(config.Config{
		CNGNSpotAssetAddress: "0xf000000000000000000000000000000000000123",
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

	var found *marketPresentation
	for i := range markets {
		if markets[i].Market == instruments.CNGNSpotSymbol {
			found = &markets[i]
			break
		}
	}
	if found == nil {
		t.Fatal("spot market missing from markets response")
	}

	if found.ContractType != "spot" {
		t.Fatalf("spot contract type = %q", found.ContractType)
	}
	if found.SettlementType != "spot" {
		t.Fatalf("spot settlement type = %q", found.SettlementType)
	}
	if found.AssetAddress != "0xf000000000000000000000000000000000000123" {
		t.Fatalf("spot asset address = %q", found.AssetAddress)
	}
	if found.SubID != "0" {
		t.Fatalf("spot sub id = %q", found.SubID)
	}
	if found.ExpiryTimestamp != 0 {
		t.Fatalf("spot should carry no expiry, got %d", found.ExpiryTimestamp)
	}
	if found.LastTradeTimestamp != nil {
		t.Fatalf("expected nil last_trade_timestamp without trade history, got %+v", found)
	}
	if found.BaseAssetSymbol != "USDC" || found.QuoteAssetSymbol != "cNGN" {
		t.Fatalf("spot unexpected base/quote %q/%q", found.BaseAssetSymbol, found.QuoteAssetSymbol)
	}
	if found.TickSize != "0.000000000000000001" {
		t.Fatalf("spot tick size = %q", found.TickSize)
	}
	if found.MinSize != "0.000001" {
		t.Fatalf("spot min size = %q", found.MinSize)
	}
	if found.ContractMultiplier != "1" {
		t.Fatalf("spot contract multiplier = %q", found.ContractMultiplier)
	}
	if found.OrderEntrySpec != "usdc_cngn_spot_v1" {
		t.Fatalf("spot order entry spec = %q", found.OrderEntrySpec)
	}
}

func TestHandleMarketsOmitsUnconfiguredMarkets(t *testing.T) {
	server := NewServer(config.Config{}, nil, instruments.DefaultRegistry(config.Config{}))

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
	if len(markets) != 0 {
		t.Fatalf("expected no markets without configuration, got %d", len(markets))
	}
}
