package config

import (
	"strings"
	"testing"
)

// Delisting a spot market keeps its escrow withdrawable: futures accounts hold cNGN and EURC there.
func TestDelistedSpotEscrowsStayWithdrawable(t *testing.T) {
	cfg := Config{
		CNGNSpotAssetAddress: "0xf000000000000000000000000000000000000123",
		EURCSpotAssetAddress: "0xe000000000000000000000000000000000000456",
		CNGNSpotDelisted:     true,
		EURCSpotDelisted:     true,
	}
	got := strings.Join(withdrawalAssets(cfg), ",")
	for _, want := range []string{cfg.CNGNSpotAssetAddress, cfg.EURCSpotAssetAddress} {
		if !strings.Contains(got, want) {
			t.Fatalf("withdrawal assets %q lost %s", got, want)
		}
	}
}
