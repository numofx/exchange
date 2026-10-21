package config

import (
	"fmt"
	"slices"
	"testing"
)

const (
	delistAsset  = "0x1111111111111111111111111111111111111111"
	delistModule = "0x2222222222222222222222222222222222222222"
	delistCash   = "0x3333333333333333333333333333333333333333"
	delistSRM    = "0x4444444444444444444444444444444444444444"
)

// Of the sixteen ways to set the perp's four addresses, three are accepted: all four (listed), the
// shared module, cash and SRM without the asset (delisted), and none. Every other combination,
// including each of the other three-of-four, is a deployment half configured and is refused.
func TestThePerpStackIsAllFourTheSharedThreeOrNone(t *testing.T) {
	for mask := 0; mask < 16; mask++ {
		asset, module, cash, srm := mask&1 != 0, mask&2 != 0, mask&4 != 0, mask&8 != 0
		c := Config{}
		if asset {
			c.CNGNPerpAssetAddress = delistAsset
			c.CNGNPerpCloseOnly = true // past the reopen guard, which is not under test here
		}
		if module {
			c.CNGNPerpTradeModuleAddress = delistModule
		}
		if cash {
			c.CNGNPerpCashAddress = delistCash
		}
		if srm {
			c.CNGNPerpSRMAddress = delistSRM
		}
		shared := module && cash && srm
		wantOK := (asset && shared) || (!asset && shared) || (!asset && !module && !cash && !srm)
		name := fmt.Sprintf("asset=%v module=%v cash=%v srm=%v", asset, module, cash, srm)
		if err := c.validatePerpStack(); (err == nil) != wantOK {
			t.Errorf("%s: err=%v, want accepted=%v", name, err, wantOK)
		}
	}
}

// Close-only and the close-only manager describe a listed perp; with the perp delisted they are a
// misconfiguration, not a no-op.
func TestCloseOnlyNeedsAListedPerp(t *testing.T) {
	delisted := Config{CNGNPerpTradeModuleAddress: delistModule, CNGNPerpCashAddress: delistCash, CNGNPerpSRMAddress: delistSRM}
	withCloseOnly := delisted
	withCloseOnly.CNGNPerpCloseOnly = true
	if err := withCloseOnly.validatePerpStack(); err == nil {
		t.Error("CNGN_PERP_CLOSE_ONLY with the perp delisted was accepted")
	}
	withManager := delisted
	withManager.CNGNPerpCloseOnlyManager = "0x5555555555555555555555555555555555555555"
	if err := withManager.validatePerpStack(); err == nil {
		t.Error("CNGN_PERP_CLOSE_ONLY_MANAGER with the perp delisted was accepted")
	}
	// No reopen acknowledgement is needed for a perp that is not listed.
	if err := delisted.validatePerpStack(); err != nil {
		t.Errorf("delisted, no close-only: %v", err)
	}
}

// The binaries load this config (api, matcher, migrate): with the asset unset and the shared stack
// set, spot and the future boot, the perp is off, USDC deposits default to the shared cash, and the
// cash stays withdrawable.
func TestLoadBootsSpotAndTheFutureWithThePerpDelisted(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://test")
	t.Setenv("APP_ENV", "test")
	t.Setenv("CHAIN_RPC_URL", "http://rpc")
	t.Setenv("CNGN_SPOT_ASSET_ADDRESS", "0x6666666666666666666666666666666666666666")
	t.Setenv("CNGN_PERP_ASSET_ADDRESS", "")
	t.Setenv("CNGN_PERP_TRADE_MODULE_ADDRESS", delistModule)
	t.Setenv("CNGN_PERP_CASH_ADDRESS", delistCash)
	t.Setenv("CNGN_PERP_SRM_ADDRESS", delistSRM)
	t.Setenv("CNGN_PERP_CLOSE_ONLY", "false")
	t.Setenv("CNGN_FUTURE_ASSET_ADDRESS", "0x7777777777777777777777777777777777777777")
	t.Setenv("CNGN_FUTURE_EXPIRY", "1796047200")
	t.Setenv("CNGN_FUTURE_MANAGER_ADDRESS", "0x8888888888888888888888888888888888888888")
	t.Setenv("DEPOSIT_ASSET_ADDRESSES", "")
	t.Setenv("WITHDRAWAL_ASSET_ADDRESSES", "")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("Load with the perp delisted: %v", err)
	}
	if cfg.PerpEnabled() || !cfg.PerpTradeStackConfigured() || !cfg.FutureEnabled() {
		t.Fatalf("PerpEnabled=%v PerpTradeStackConfigured=%v FutureEnabled=%v; want false, true, true",
			cfg.PerpEnabled(), cfg.PerpTradeStackConfigured(), cfg.FutureEnabled())
	}
	if !slices.Equal(cfg.DepositAssetAddresses, []string{delistCash}) {
		t.Errorf("DepositAssetAddresses = %v, want the shared cash %s", cfg.DepositAssetAddresses, delistCash)
	}
	if !slices.Contains(cfg.WithdrawalAssetAddresses, delistCash) {
		t.Errorf("WithdrawalAssetAddresses = %v, want the shared cash among them", cfg.WithdrawalAssetAddresses)
	}

	// The future still refuses to boot without the shared stack.
	t.Setenv("CNGN_PERP_SRM_ADDRESS", "")
	if _, err := Load(); err == nil {
		t.Error("the future booted without the shared stack's SRM")
	}
}
