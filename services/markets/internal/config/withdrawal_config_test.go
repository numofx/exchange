package config

import (
	"reflect"
	"testing"
	"time"
)

func loadWithdrawalTestConfig(t *testing.T, env map[string]string) Config {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgres://test")
	t.Setenv("APP_ENV", "test")
	for _, key := range []string{"WITHDRAWAL_ASSET_ADDRESSES", "WITHDRAWAL_MODULE_ADDRESS", "EXECUTOR_WITHDRAW_URL", "EXECUTOR_WITHDRAW_TIMEOUT"} {
		t.Setenv(key, "")
	}
	for key, value := range env {
		t.Setenv(key, value)
	}
	cfg, err := Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	return cfg
}

// Unset, a withdrawal may pay out of exactly the two assets the venue settles in: the quote asset and cNGN.
func TestWithdrawalAssetsDefaultToTheAssetsTheVenueSettlesIn(t *testing.T) {
	cfg := loadWithdrawalTestConfig(t, map[string]string{
		"QUOTE_ASSET_ADDRESS":     "0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84",
		"CNGN_SPOT_ASSET_ADDRESS": "0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493",
	})

	want := []string{"0x364058aff6f36e01505fb2cc870f8b6bd4835e84", "0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493"}
	if !reflect.DeepEqual(cfg.WithdrawalAssetAddresses, want) {
		t.Fatalf("withdrawal assets = %v, want %v", cfg.WithdrawalAssetAddresses, want)
	}
	if cfg.ExecutorWithdrawTimeout != 45*time.Second {
		t.Fatalf("EXECUTOR_WITHDRAW_TIMEOUT default = %s, want 45s", cfg.ExecutorWithdrawTimeout)
	}
}

func TestWithdrawalAssetsCanBeNamedExplicitly(t *testing.T) {
	cfg := loadWithdrawalTestConfig(t, map[string]string{
		"QUOTE_ASSET_ADDRESS":        "0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84",
		"CNGN_SPOT_ASSET_ADDRESS":    "0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493",
		"WITHDRAWAL_ASSET_ADDRESSES": " 0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84 , ",
		"WITHDRAWAL_MODULE_ADDRESS":  " 0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB ",
	})

	if want := []string{"0x364058aff6f36e01505fb2cc870f8b6bd4835e84"}; !reflect.DeepEqual(cfg.WithdrawalAssetAddresses, want) {
		t.Fatalf("withdrawal assets = %v, want %v", cfg.WithdrawalAssetAddresses, want)
	}
	if cfg.WithdrawalModuleAddress != "0x0a10ae2f5d2482ce1e43bc309d430b8861c2b5ab" {
		t.Fatalf("withdrawal module = %q", cfg.WithdrawalModuleAddress)
	}
}
