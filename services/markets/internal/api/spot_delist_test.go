package api

import (
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

// A delisted spot takes no orders, the other spot still does. Before the Enabled check, a delisted spot kept its
// address in the registry and isAllowedInstrument admitted its orders.
func TestDelistedSpotTakesNoOrders(t *testing.T) {
	cfg := config.Config{
		CNGNSpotAssetAddress: "0xf000000000000000000000000000000000000123",
		EURCSpotAssetAddress: "0xe000000000000000000000000000000000000456",
		CNGNSpotDelisted:     true,
	}
	if isAllowedInstrument(cfg, "0xf000000000000000000000000000000000000123", "0") {
		t.Fatalf("a delisted cNGN-USDC order was admitted")
	}
	if !isAllowedInstrument(cfg, "0xe000000000000000000000000000000000000456", "0") {
		t.Fatalf("a listed EURC-USDC order was refused")
	}
}
