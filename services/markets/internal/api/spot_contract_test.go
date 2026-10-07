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

// The ui_intent is the engine order: a UI BUY of 160,000 cNGN at 0.000625 USDC per cNGN is an
// engine BUY of 160,000 cNGN at 0.000625, and fills as cNGN +160,000 / USDC -100. A SELL is the
// reverse.
func TestUIIntentIsTheEngineOrderWithTheDeltasSigned(t *testing.T) {
	for _, tc := range []struct {
		side, cngn, usdc string
	}{
		{"buy", "+160000", "-100"},
		{"sell", "-160000", "+100"},
	} {
		echo, err := translateSpotUIIntent(spotOrderEntrySpec, &spotOrderIntent{Side: tc.side, Price: "0.000625", Size: "160000"})
		if err != nil {
			t.Fatalf("%s: %v", tc.side, err)
		}
		if echo.EngineOrder.Side != tc.side {
			t.Fatalf("UI %s must be engine %s, got %q", tc.side, tc.side, echo.EngineOrder.Side)
		}
		if !decimalStringsMatch(echo.EngineOrder.Price, "0.000625") {
			t.Fatalf("engine price must be the ui price, got %q", echo.EngineOrder.Price)
		}
		if !decimalStringsMatch(echo.EngineOrder.Amount, "160000") {
			t.Fatalf("engine amount must be the ui size, got %q", echo.EngineOrder.Amount)
		}
		if echo.BalanceDelta.CNGN != tc.cngn || echo.BalanceDelta.USDC != tc.usdc {
			t.Fatalf("UI %s deltas = cNGN %s / USDC %s, want %s / %s", tc.side, echo.BalanceDelta.CNGN, echo.BalanceDelta.USDC, tc.cngn, tc.usdc)
		}
	}
}

// The history echo is the engine order at the UI's scales: ten places of price, six of size.
func TestEngineOrderEchoesAtTheUIScales(t *testing.T) {
	echo, err := deriveSpotOrderContractEchoFromEngine(spotOrderEntrySpec, orders.SideSell, "0.000727802037845705", "1000.5")
	if err != nil {
		t.Fatal(err)
	}
	if echo.UIIntent.Side != "sell" || echo.UIIntent.Price != "0.000727802" || echo.UIIntent.Size != "1000.5" {
		t.Fatalf("ui_intent = %+v", echo.UIIntent)
	}
	if echo.BalanceDelta.CNGN != "-1000.5" || echo.BalanceDelta.USDC != "+0.728166" {
		t.Fatalf("deltas = %+v", echo.BalanceDelta)
	}
}

func TestValidateSpotUIIntentMismatch(t *testing.T) {
	_, _, _, err := validateOrTranslateSpotUIIntent(
		spotOrderEntrySpec,
		spotOrderEntrySpec,
		&spotOrderIntent{Side: "buy", Price: "0.000625", Size: "160000"},
		orders.SideSell, // a UI buy is an engine buy
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "side does not match") {
		t.Fatalf("expected side mismatch error, got %v", err)
	}
	_, _, _, err = validateOrTranslateSpotUIIntent(
		spotOrderEntrySpec,
		spotOrderEntrySpec,
		&spotOrderIntent{Side: "buy", Price: "0.000625", Size: "160000"},
		orders.SideBuy,
		"1600", // the old cNGN-per-USDC price
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "limit_price does not match") {
		t.Fatalf("expected price mismatch error, got %v", err)
	}
}

// The perp shares spot's contract under its own spec: a UI long of 138,900 cNGN at 0.00072 is an
// engine BUY of 138,900 cNGN of the perp at 0.00072.
func TestPerpUIIntentIsTheEngineOrderUnderItsOwnSpec(t *testing.T) {
	echo, err := translateSpotUIIntent(instruments.PerpOrderEntrySpec, &spotOrderIntent{Side: "buy", Price: "0.00072", Size: "138900"})
	if err != nil {
		t.Fatalf("translate: %v", err)
	}
	if echo.Spec != instruments.PerpOrderEntrySpec {
		t.Fatalf("echo spec = %q, want the perp spec", echo.Spec)
	}
	if echo.EngineOrder.Side != string(orders.SideBuy) {
		t.Fatalf("UI long must be an engine BUY of the cNGN perp, got %q", echo.EngineOrder.Side)
	}
	if !decimalStringsMatch(echo.EngineOrder.Amount, "138900") || !decimalStringsMatch(echo.EngineOrder.Price, "0.00072") {
		t.Fatalf("engine order = %+v, want 138900 cNGN at 0.00072", echo.EngineOrder)
	}
}

// An intent signed for one market's spec is refused on the other's, so a spot ticket cannot be
// replayed as a perp order or the reverse.
func TestUIIntentForAnotherMarketsSpecIsRefused(t *testing.T) {
	_, _, _, err := validateOrTranslateSpotUIIntent(
		instruments.PerpOrderEntrySpec,
		spotOrderEntrySpec,
		&spotOrderIntent{Side: "buy", Price: "0.00072", Size: "138900"},
		"",
		"",
		"",
	)
	if err == nil || !strings.Contains(err.Error(), "order_entry_spec must be") {
		t.Fatalf("expected a spec mismatch, got %v", err)
	}
}
