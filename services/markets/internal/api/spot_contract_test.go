package api

import (
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func TestSpotRegistryGating(t *testing.T) {
	registry := instruments.DefaultRegistry(config.Config{})
	if item, ok := registry.BySymbol(instruments.CNGNSpotSymbol); ok && item.Enabled {
		t.Fatalf("spot market must be disabled without CNGN_SPOT_ASSET_ADDRESS")
	}

	registry = instruments.DefaultRegistry(config.Config{
		CNGNSpotAssetAddress: "0xe2387F04d3858e7Cb64Ef5Ed6617f9B2fcEEAfa2",
	})
	item, ok := registry.BySymbol(instruments.CNGNSpotSymbol)
	if !ok || !item.Enabled {
		t.Fatalf("spot market should be enabled when CNGN_SPOT_ASSET_ADDRESS is set")
	}
	if item.SubID != "0" || item.ContractType != "spot" {
		t.Fatalf("unexpected spot metadata: sub_id=%q contract_type=%q", item.SubID, item.ContractType)
	}
	if !isSpotContractInstrument(item) {
		t.Fatalf("registry spot entry should be recognized as the spot contract instrument")
	}
}

func TestTranslateSpotUIIntentBuy(t *testing.T) {
	// UI BUY 100 USDC @ 1600 cNGN/USDC -> engine SELL 160000 cNGN @ 1/1600 USDC per cNGN.
	echo, err := translateSpotUIIntent(spotOrderEntrySpec, &spotOrderIntent{Side: "buy", Price: "1600", Size: "100"})
	if err != nil {
		t.Fatal(err)
	}
	if echo.EngineOrder.Side != string(orders.SideSell) {
		t.Fatalf("UI BUY must invert to engine SELL, got %q", echo.EngineOrder.Side)
	}
	if !decimalStringsMatch(echo.EngineOrder.Price, "0.000625") {
		t.Fatalf("engine price should be 1/1600, got %q", echo.EngineOrder.Price)
	}
	if !decimalStringsMatch(echo.EngineOrder.Amount, "160000") {
		t.Fatalf("engine amount should be ui_size*ui_price, got %q", echo.EngineOrder.Amount)
	}
	if !decimalStringsMatch(echo.BalanceDelta.USDC, "100") || !decimalStringsMatch(echo.BalanceDelta.CNGN, "-160000") {
		t.Fatalf("UI BUY deltas should be +100 USDC / -160000 cNGN, got %q / %q", echo.BalanceDelta.USDC, echo.BalanceDelta.CNGN)
	}
}

func TestTranslateSpotUIIntentSell(t *testing.T) {
	echo, err := translateSpotUIIntent(spotOrderEntrySpec, &spotOrderIntent{Side: "sell", Price: "1600", Size: "100"})
	if err != nil {
		t.Fatal(err)
	}
	if echo.EngineOrder.Side != string(orders.SideBuy) {
		t.Fatalf("UI SELL must invert to engine BUY, got %q", echo.EngineOrder.Side)
	}
	if !decimalStringsMatch(echo.BalanceDelta.USDC, "-100") || !decimalStringsMatch(echo.BalanceDelta.CNGN, "160000") {
		t.Fatalf("UI SELL deltas should be -100 USDC / +160000 cNGN, got %q / %q", echo.BalanceDelta.USDC, echo.BalanceDelta.CNGN)
	}
}

func TestValidateSpotUIIntentMismatch(t *testing.T) {
	_, _, _, err := validateOrTranslateSpotUIIntent(
		spotOrderEntrySpec,
		spotOrderEntrySpec,
		&spotOrderIntent{Side: "buy", Price: "1600", Size: "100"},
		orders.SideBuy, // must be engine SELL after inversion
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "side does not match") {
		t.Fatalf("expected side mismatch error, got %v", err)
	}
}

// The perp shares spot's translation -- USD per NGN on chain, NGN per USD on screen -- under its
// own spec: a UI long of 100 USDC at 1,389 NGN/USD is an engine SELL of 138,900 NGN at 1/1389.
func TestPerpUIIntentTranslatesLikeSpotUnderItsOwnSpec(t *testing.T) {
	echo, err := translateSpotUIIntent(instruments.PerpOrderEntrySpec, &spotOrderIntent{Side: "buy", Price: "1389", Size: "100"})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if echo.Spec != instruments.PerpOrderEntrySpec {
		t.Fatalf("echo spec = %q, want the perp spec", echo.Spec)
	}
	if echo.EngineOrder.Side != string(orders.SideSell) {
		t.Fatalf("UI long must be an engine SELL of the NGN perp, got %q", echo.EngineOrder.Side)
	}
	if !decimalStringsMatch(echo.EngineOrder.Amount, "138900") {
		t.Fatalf("engine amount = %q, want 138900 NGN", echo.EngineOrder.Amount)
	}
}

// An intent signed for one market's spec is refused on the other's, so a spot ticket cannot be
// replayed as a perp order or the reverse.
func TestUIIntentForAnotherMarketsSpecIsRefused(t *testing.T) {
	_, _, _, err := validateOrTranslateSpotUIIntent(
		instruments.PerpOrderEntrySpec,
		spotOrderEntrySpec,
		&spotOrderIntent{Side: "buy", Price: "1389", Size: "100"},
		"",
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "order_entry_spec must be") {
		t.Fatalf("expected a spec mismatch, got %v", err)
	}
}
