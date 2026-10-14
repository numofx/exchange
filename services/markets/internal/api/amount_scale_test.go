package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func futureInstrument(t *testing.T) instruments.Metadata {
	t.Helper()
	for _, market := range instruments.DefaultRegistry(futureConfig("http://127.0.0.1:1")).Enabled() {
		if market.IsFuture() {
			return market
		}
	}
	t.Fatal("no future in the registry under test")
	return instruments.Metadata{}
}

func tradeAction(asset, subID, desiredAmount string) json.RawMessage {
	return json.RawMessage(`{"data":"` + mustTradeDataHex(asset, subID, "1380000000000000000000", desiredAmount, true) + `"}`)
}

// The future is sized in whole USDC of notional, 0.001 of a contract signed as 1e15, so its smallest
// order is 1 USDC. Intake takes that scale and no other: the matcher crosses two orders only at one
// shared scale, and cancels an order off it.
func TestFutureIntakeTakesOnlyItsUSDCScale(t *testing.T) {
	future := futureInstrument(t)
	asset, subID := future.AssetAddress, future.SubID

	for _, ok := range []struct{ desired, signed string }{
		{"1", "1000000000000000"},         // 1 USDC, 0.001 contract
		{"1000", "1000000000000000000"},   // one contract
		{"12345", "12345000000000000000"}, // 12.345 contracts
	} {
		if err := validateActionDataInvariants(tradeAction(asset, subID, ok.signed), orders.SideBuy, asset, subID, "1380", ok.desired, future); err != nil {
			t.Fatalf("desired_amount %s signed %s refused: %v", ok.desired, ok.signed, err)
		}
	}
	for _, bad := range []struct{ desired, signed string }{
		{"1", "1000000000000000000"}, // a whole contract per unit: the old scale
		{"1", "999999999999999"},
		{"2", "3000000000000000"},
	} {
		err := validateActionDataInvariants(tradeAction(asset, subID, bad.signed), orders.SideBuy, asset, subID, "1380", bad.desired, future)
		if err == nil || !strings.Contains(err.Error(), "x 1000000000000000") {
			t.Fatalf("desired_amount %s signed %s: want the scale refusal, got %v", bad.desired, bad.signed, err)
		}
	}
}

// Spot fixes its unit at one whole cNGN (1e18), what the app and the market maker sign; the perp, close-only,
// still takes any whole scale.
func TestSpotTakesOnlyWholeCNGNAndThePerpAnyScale(t *testing.T) {
	cfg := futureConfig("http://127.0.0.1:1")
	cfg.CNGNSpotAssetAddress = "0x5555555555555555555555555555555555555556"
	cfg.CNGNPerpAssetAddress = testPerpAsset
	var spot, perp instruments.Metadata
	for _, market := range instruments.DefaultRegistry(cfg).Enabled() {
		switch {
		case market.ContractType == instruments.ContractTypeSpot:
			spot = market
		case market.IsPerpetual():
			perp = market
		}
	}
	if spot.Symbol == "" {
		t.Fatal("no spot market in the registry under test")
	}
	ok := func(market instruments.Metadata, signed string) error {
		return validateActionDataInvariants(tradeAction(market.AssetAddress, market.SubID, signed), orders.SideBuy, market.AssetAddress, market.SubID, "1380", "5", market)
	}
	if err := ok(spot, "5000000000000000000"); err != nil {
		t.Fatalf("spot at 1e18 a cNGN refused: %v", err)
	}
	if err := ok(spot, "5000000000000000"); err == nil || !strings.Contains(err.Error(), "x 1000000000000000000") {
		t.Fatalf("spot at 1e15 a cNGN: want the scale refusal, got %v", err)
	}
	if perp.Symbol == "" {
		t.Fatal("no perp market in the registry under test")
	}
	{
		for _, signed := range []string{"5000000000000000000", "5000000000000000"} {
			if err := ok(perp, signed); err != nil {
				t.Fatalf("perp signed %s refused: %v", signed, err)
			}
		}
	}
}

func TestFutureListingServesItsAmountScale(t *testing.T) {
	cfg := futureConfig("http://127.0.0.1:1")
	server := &Server{cfg: cfg, instruments: instruments.DefaultRegistry(cfg)}
	future := futureInstrument(t)
	p := server.presentMarket(context.Background(), future)
	if p.AmountScale != "1000000000000000" || p.MinSize != "1" || p.AmountStep != "1" || p.ContractMultiplier != "1000" {
		t.Fatalf("future listing: amount_scale %q min_size %q amount_step %q contract_multiplier %q",
			p.AmountScale, p.MinSize, p.AmountStep, p.ContractMultiplier)
	}
}
