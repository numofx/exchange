package config

import (
	"reflect"
	"strings"
	"testing"
)

const (
	testV1Future   = "0xdcfa4ee0772647abd24e8592596b5fe4f001bc19"
	testV1Engine   = "0xa19e296021c9df25b90d96c2a0793cc3d0800758"
	testV2Future   = "0xcacee66ad41fd1472a47d7d5fe372ffbfac9aa75"
	testV2Engine   = "0x0705219a1594d5fc5dc2573da4082caf3e1b0950"
	testEURCFuture = "0x00000000000000000000000000000000000e0dc1" // placeholder: not deployed
	testExpiry     = int64(1796047200)
)

// The live deployment's three CNGN_FUTURE_* envs, as terraform sets them.
func setLegacyFutureEnv(t *testing.T) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgres://test")
	t.Setenv("APP_ENV", "test")
	t.Setenv("CHAIN_RPC_URL", "http://rpc")
	t.Setenv("CNGN_PERP_TRADE_MODULE_ADDRESS", "0xDea968188598BA0E3F58A56C0fdfF338C74F699f")
	t.Setenv("CNGN_PERP_CASH_ADDRESS", "0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272")
	t.Setenv("CNGN_PERP_SRM_ADDRESS", "0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4")
	t.Setenv("CNGN_FUTURE_ASSET_ADDRESS", "0xDCFa4Ee0772647aBd24E8592596b5fe4F001Bc19")
	t.Setenv("CNGN_FUTURE_EXPIRY", "1796047200")
	t.Setenv("CNGN_FUTURE_MANAGER_ADDRESS", "0xA19E296021c9DF25b90D96C2A0793CC3D0800758")
	t.Setenv("CNGN_FUTURE_CLOSE_ONLY", "")
	t.Setenv("FUTURE_SERIES", "")
}

// Today's envs alone list exactly today's series: v1's, inverse, open, under its old symbol.
func TestTheLegacyEnvsListTheOneV1Series(t *testing.T) {
	setLegacyFutureEnv(t)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	want := []FutureSeries{{AssetAddress: testV1Future, Expiry: testExpiry, ManagerAddress: testV1Engine, Kind: FutureKindInverse,
		BaseAsset: "cNGN", ContractSize: "1000"}}
	if got := cfg.FutureSeriesList(); !reflect.DeepEqual(got, want) {
		t.Fatalf("series %+v, want %+v", got, want)
	}
	if got := want[0].MarketSymbol(); got != "USDC-cNGN-30NOV26" {
		t.Fatalf("v1's symbol %s", got)
	}
	if got := want[0].ScaledAmount(); got != "1000000000000000" {
		t.Fatalf("v1's unit %s, want 1e15 (1 USDC)", got)
	}
}

// FUTURE_SERIES lists v2's series beside v1's, at the same expiry, each under its own symbol; v1 can be
// made close-only on its own.
func TestFutureSeriesListsV2BesideV1(t *testing.T) {
	setLegacyFutureEnv(t)
	t.Setenv("CNGN_FUTURE_CLOSE_ONLY", "true")
	t.Setenv("FUTURE_SERIES", `[
	  {"asset_address":"0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75","expiry":1796047200,"manager_address":"0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950","kind":"linear","base_asset":"cNGN","contract_size":"1000000"},
	  {"asset_address":"`+testEURCFuture+`","expiry":1796047200,"manager_address":"0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950","kind":"linear","base_asset":"EURC","contract_size":"1000"}
	]`)
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	list := cfg.FutureSeriesList()
	if len(list) != 3 {
		t.Fatalf("want three series: %+v", list)
	}
	for i, want := range []struct {
		symbol, asset, engine, scale string
		closeOnly                    bool
	}{
		{"USDC-cNGN-30NOV26", testV1Future, testV1Engine, "1000000000000000", true},
		{"cNGN-30NOV26", testV2Future, testV2Engine, "1000000000000", false},
		{"EURC-30NOV26", testEURCFuture, testV2Engine, "1000000000000000", false},
	} {
		got := list[i]
		if got.MarketSymbol() != want.symbol || got.AssetAddress != want.asset || got.ManagerAddress != want.engine ||
			got.ScaledAmount() != want.scale || got.CloseOnly != want.closeOnly || got.SubID() != "1796047200" {
			t.Errorf("series %d: %+v (%s, unit %s)", i, got, got.MarketSymbol(), got.ScaledAmount())
		}
	}
}

func TestAFutureSeriesListIsRefusedWhenAmbiguousOrPartial(t *testing.T) {
	v2 := `{"asset_address":"` + testV2Future + `","expiry":1796047200,"manager_address":"` + testV2Engine + `","kind":"linear","base_asset":"cNGN","contract_size":"1000000"}`
	for want, raw := range map[string]string{
		"not a JSON array":               `{"asset_address":"x"}`,
		"unknown field":                  `[{"asset_address":"` + testV2Future + `","closeonly":true}]`,
		"asset_address":                  `[{"asset_address":"0x12","expiry":1796047200,"manager_address":"` + testV2Engine + `","kind":"linear","base_asset":"cNGN","contract_size":"1"}]`,
		"expiry is not":                  `[{"asset_address":"` + testV2Future + `","manager_address":"` + testV2Engine + `","kind":"linear","base_asset":"cNGN","contract_size":"1"}]`,
		"manager_address":                `[{"asset_address":"` + testV2Future + `","expiry":1796047200,"kind":"linear","base_asset":"cNGN","contract_size":"1"}]`,
		`kind "" is neither`:             `[{"asset_address":"` + testV2Future + `","expiry":1796047200,"manager_address":"` + testV2Engine + `","base_asset":"cNGN","contract_size":"1"}]`,
		"base_asset is required":         `[{"asset_address":"` + testV2Future + `","expiry":1796047200,"manager_address":"` + testV2Engine + `","kind":"linear","contract_size":"1"}]`,
		"an inverse series is cNGN's":    `[{"asset_address":"` + testV2Future + `","expiry":1796047200,"manager_address":"` + testV2Engine + `","kind":"inverse","base_asset":"EURC","contract_size":"1000"}]`,
		"contract_size":                  `[{"asset_address":"` + testV2Future + `","expiry":1796047200,"manager_address":"` + testV2Engine + `","kind":"linear","base_asset":"cNGN"}]`,
		"1e18 / contract_size":           `[{"asset_address":"` + testV2Future + `","expiry":1796047200,"manager_address":"` + testV2Engine + `","kind":"linear","base_asset":"cNGN","contract_size":"3"}]`,
		"two series are listed on":       `[` + v2 + `,` + strings.Replace(v2, `"base_asset":"cNGN"`, `"base_asset":"cNGN","symbol":"cNGN-B"`, 1) + `]`,
		"two series are listed as":       `[` + v2 + `,` + strings.Replace(v2, testV2Future, testEURCFuture, 1) + `]`,
		"two series are listed on asset": `[` + strings.Replace(v2, testV2Future, testV1Future, 1) + `]`,
	} {
		t.Run(want, func(t *testing.T) {
			setLegacyFutureEnv(t)
			t.Setenv("FUTURE_SERIES", raw)
			if _, err := Load(); err == nil || !strings.Contains(err.Error(), want) {
				t.Fatalf("Load() = %v, want an error containing %q", err, want)
			}
		})
	}
}

// v2's series alone (v1 delisted after 30NOV26 settles) still needs the shared stack and the chain;
// close-only without v1's series is refused rather than ignored.
func TestFutureSeriesWithoutTheLegacySeries(t *testing.T) {
	c := Config{
		ChainRPCURL:                "http://rpc",
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
		CNGNPerpSRMAddress:         "0x4444444444444444444444444444444444444444",
		FutureSeries: []FutureSeries{{AssetAddress: testV2Future, Expiry: testExpiry, ManagerAddress: testV2Engine,
			Kind: FutureKindLinear, BaseAsset: "cNGN", ContractSize: "1000000"}},
	}
	if err := c.validateFutureStack(); err != nil || !c.FutureEnabled() {
		t.Fatalf("v2 alone: %v", err)
	}
	noRPC := c
	noRPC.ChainRPCURL = ""
	if err := noRPC.validateFutureStack(); err == nil || !strings.Contains(err.Error(), "without CHAIN_RPC_URL") {
		t.Fatalf("v2 without the chain: %v", err)
	}
	closeOnly := c
	closeOnly.CNGNFutureCloseOnly = true
	if err := closeOnly.validateFutureStack(); err == nil || !strings.Contains(err.Error(), "CNGN_FUTURE_CLOSE_ONLY") {
		t.Fatalf("close-only with no v1 series: %v", err)
	}
}
