package api

import (
	"context"
	"math/big"
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
)

// Every market's listing says the step intake enforces: amount_step is the normalization's step, min_size is a
// whole number of it, intake takes min_size and refuses half a step more. The future's listing used to say
// min_size 0.001 while intake refused anything but whole contracts, and the futures market maker sized to the
// listing (2026-10-13).
func TestEveryListingStatesTheAmountStepIntakeEnforces(t *testing.T) {
	cfg := futureConfig("http://127.0.0.1:1")
	cfg.CNGNSpotAssetAddress = "0x5555555555555555555555555555555555555556"
	cfg.SpotMarginManagerAddress = "0x7777777777777777777777777777777777777777"
	cfg.CNGNPerpAssetAddress = testPerpAsset
	cfg.CNGNPerpSRMAddress = testPerpSRM
	cfg.MatchingAddress = "0x1111111111111111111111111111111111111111"
	server := &Server{cfg: cfg, instruments: instruments.DefaultRegistry(cfg)}
	seen := map[string]bool{}
	for _, market := range server.instruments.Enabled() {
		p := server.presentMarket(context.Background(), market)
		if p.AmountStep == "" || p.AmountStep != amountAtomicStep(market) {
			t.Fatalf("%s: listing amount_step %q, intake enforces %q", market.Symbol, p.AmountStep, amountAtomicStep(market))
		}
		step, _ := new(big.Rat).SetString(p.AmountStep)
		minSize, ok := new(big.Rat).SetString(p.MinSize)
		if !ok || minSize.Sign() <= 0 || !new(big.Rat).Quo(minSize, step).IsInt() {
			t.Fatalf("%s: min_size %q is not a whole number of amount_step %q", market.Symbol, p.MinSize, p.AmountStep)
		}
		if _, err := normalizeDesiredAmount(market, p.MinSize); err != nil {
			t.Fatalf("%s: intake refuses the listing's own min_size %s: %v", market.Symbol, p.MinSize, err)
		}
		half := new(big.Rat).Add(minSize, new(big.Rat).Quo(step, big.NewRat(2, 1)))
		if _, err := normalizeDesiredAmount(market, half.FloatString(6)); err == nil {
			t.Fatalf("%s: intake takes %s, half a step past min_size", market.Symbol, half.FloatString(6))
		}
		seen[string(market.ContractType)] = true
	}
	for _, kind := range []string{"spot", "perpetual", "future"} {
		if !seen[kind] {
			t.Fatalf("no %s market in the registry under test: %v", kind, seen)
		}
	}
}
