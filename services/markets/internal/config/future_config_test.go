package config

import (
	"strings"
	"testing"
)

func TestTheFutureIsAllOrNothingAndNeedsTheSharedStackAndTheChain(t *testing.T) {
	perp := Config{
		ChainRPCURL:                "http://rpc",
		CNGNPerpAssetAddress:       "0x1111111111111111111111111111111111111111",
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
		CNGNPerpSRMAddress:         "0x4444444444444444444444444444444444444444",
	}
	future := perp
	future.CNGNFutureAssetAddress = "0x5555555555555555555555555555555555555555"
	future.CNGNFutureExpiry = 1798675200
	future.CNGNFutureManagerAddress = "0x6666666666666666666666666666666666666666"
	if err := future.validateFutureStack(); err != nil || !future.FutureEnabled() || future.FutureSubID() != "1798675200" {
		t.Fatalf("a full future config: %v", err)
	}
	if err := perp.validateFutureStack(); err != nil || perp.FutureEnabled() {
		t.Fatalf("no future is no future: %v", err)
	}

	for want, mutate := range map[string]func(*Config){
		"CNGN_FUTURE_EXPIRY missing":          func(c *Config) { c.CNGNFutureExpiry = 0 },
		"CNGN_FUTURE_MANAGER_ADDRESS missing": func(c *Config) { c.CNGNFutureManagerAddress = "" },
		"without the shared stack":            func(c *Config) { c.CNGNPerpTradeModuleAddress = "" },
		"without CHAIN_RPC_URL":               func(c *Config) { c.ChainRPCURL = "" },
		"is the perp's asset":                 func(c *Config) { c.CNGNFutureAssetAddress = c.CNGNPerpAssetAddress },
	} {
		c := future
		mutate(&c)
		if err := c.validateFutureStack(); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", want, err)
		}
	}
}

// The future trades on the shared module and settles in the shared cash, not on the perp's listing:
// with the perp delisted (its asset unset) the future still boots.
func TestTheFutureRunsWithThePerpDelisted(t *testing.T) {
	c := Config{
		ChainRPCURL:                "http://rpc",
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
		CNGNPerpSRMAddress:         "0x4444444444444444444444444444444444444444",
		CNGNFutureAssetAddress:     "0x5555555555555555555555555555555555555555",
		CNGNFutureExpiry:           1798675200,
		CNGNFutureManagerAddress:   "0x6666666666666666666666666666666666666666",
	}
	if err := c.validateFutureStack(); err != nil {
		t.Fatalf("future with the perp delisted: %v", err)
	}
	if c.PerpEnabled() || !c.PerpTradeStackConfigured() {
		t.Fatalf("PerpEnabled=%v PerpTradeStackConfigured=%v; want false, true", c.PerpEnabled(), c.PerpTradeStackConfigured())
	}
}
