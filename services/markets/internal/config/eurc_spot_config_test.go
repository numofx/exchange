package config

import (
	"math/big"
	"reflect"
	"strings"
	"testing"
)

const (
	testEURCEscrow = "0x00000000000000000000000000000000000e0dc0"
	testCNGNEscrow = "0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493"
	testQuote      = "0x364058aff6f36e01505fb2cc870f8b6bd4835e84"
)

func TestEURCSpotIsOffUntilItsEscrowIsConfigured(t *testing.T) {
	cfg := loadWithdrawalTestConfig(t, map[string]string{"QUOTE_ASSET_ADDRESS": testQuote, "CNGN_SPOT_ASSET_ADDRESS": testCNGNEscrow})
	if cfg.EURCSpotAssetAddress != "" {
		t.Fatalf("EURC escrow = %q with nothing configured", cfg.EURCSpotAssetAddress)
	}
	// Unset, the withdrawal default is exactly what it was before EURC existed.
	if want := []string{testQuote, testCNGNEscrow}; !reflect.DeepEqual(cfg.WithdrawalAssetAddresses, want) {
		t.Fatalf("withdrawal assets = %v, want %v", cfg.WithdrawalAssetAddresses, want)
	}
}

// Set, the EURC escrow is read lowercased and is withdrawable by default, like the cNGN spot escrow.
func TestEURCSpotEscrowIsAWithdrawalAssetByDefault(t *testing.T) {
	cfg := loadWithdrawalTestConfig(t, map[string]string{
		"QUOTE_ASSET_ADDRESS":     testQuote,
		"CNGN_SPOT_ASSET_ADDRESS": testCNGNEscrow,
		"EURC_SPOT_ASSET_ADDRESS": " 0x00000000000000000000000000000000000E0dC0 ",
	})
	if cfg.EURCSpotAssetAddress != testEURCEscrow {
		t.Fatalf("EURC escrow = %q", cfg.EURCSpotAssetAddress)
	}
	if want := []string{testQuote, testCNGNEscrow, testEURCEscrow}; !reflect.DeepEqual(cfg.WithdrawalAssetAddresses, want) {
		t.Fatalf("withdrawal assets = %v, want %v", cfg.WithdrawalAssetAddresses, want)
	}
}

// The registry keys markets by (asset, sub_id): an EURC escrow that is another market's asset would put two markets
// under one key, so the process refuses to start rather than answer one market with the other's book.
func TestEURCSpotEscrowMustBeAnAddressOfItsOwn(t *testing.T) {
	cases := map[string]map[string]string{
		"not an address":   {"EURC_SPOT_ASSET_ADDRESS": "eurc"},
		"the zero address": {"EURC_SPOT_ASSET_ADDRESS": "0x0000000000000000000000000000000000000000"},
		// in another case: a hex address has none of its own
		"the cNGN spot asset": {"CNGN_SPOT_ASSET_ADDRESS": testCNGNEscrow, "EURC_SPOT_ASSET_ADDRESS": "0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493"},
		"the quote asset":     {"QUOTE_ASSET_ADDRESS": testQuote, "EURC_SPOT_ASSET_ADDRESS": testQuote},
	}
	for name, env := range cases {
		t.Run(name, func(t *testing.T) {
			t.Setenv("DATABASE_URL", "postgres://test")
			t.Setenv("APP_ENV", "test")
			for _, key := range []string{"CNGN_SPOT_ASSET_ADDRESS", "QUOTE_ASSET_ADDRESS", "EURC_SPOT_ASSET_ADDRESS"} {
				t.Setenv(key, "")
			}
			for key, value := range env {
				t.Setenv(key, value)
			}
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EURC_SPOT_ASSET_ADDRESS") {
				t.Fatalf("Load() error = %v, want a refusal naming EURC_SPOT_ASSET_ADDRESS", err)
			}
		})
	}
}

// EURC deposits are data-driven: a DEPOSIT_ASSETS entry for the EURC escrow at its own 6-decimal minimum.
func TestEURCIsDepositableThroughDepositAssets(t *testing.T) {
	got, err := parseDepositAssets("0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272:USDC:10000000,0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98:cNGN:15000000000,0x00000000000000000000000000000000000E0dC0:EURC:10000000", nil, big.NewInt(1))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[2].Address != testEURCEscrow || got[2].Symbol != "EURC" || got[2].MinAmount.Int64() != 10_000_000 {
		t.Fatalf("parsed %+v", got)
	}
}
