package config

import (
	"strings"
	"testing"
)

func prodCfg() Config {
	return Config{
		AppEnv:             "production",
		TradeModuleAddress: "0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c",
	}
}

// TRADE_MODULE_ADDRESS used to be loaded and never read, which made it look as though the Go
// service enforced a module allowlist when the only enforcement was in execution-service. It is
// now what every submitted order is pinned to, so an unset value silently reopens the book to
// orders naming any module -- including the one a quote-asset migration is moving away from.
func TestValidateTradeModuleRequiresTheAddressInProduction(t *testing.T) {
	for _, bad := range []string{"", "   ", "not-an-address", "0x0000000000000000000000000000000000000000", "0x123"} {
		cfg := prodCfg()
		cfg.TradeModuleAddress = bad

		err := cfg.validateTradeModule()
		if err == nil {
			t.Fatalf("TRADE_MODULE_ADDRESS=%q must be refused in production", bad)
		}
		if !strings.Contains(err.Error(), "TRADE_MODULE_ADDRESS") {
			t.Fatalf("error must name the variable, got: %v", err)
		}
	}
}

func TestValidateTradeModuleAcceptsAConfiguredAddress(t *testing.T) {
	if err := prodCfg().validateTradeModule(); err != nil {
		t.Fatalf("a configured module must be accepted: %v", err)
	}
}

// Dev and test environments must keep starting with nothing set, exactly as they do today.
func TestValidateTradeModuleIsNotEnforcedOutsideProduction(t *testing.T) {
	for _, env := range []string{"", "dev", "development", "local", "test", "ci"} {
		cfg := Config{AppEnv: env}
		if err := cfg.validateTradeModule(); err != nil {
			t.Fatalf("APP_ENV=%q must not require TRADE_MODULE_ADDRESS: %v", env, err)
		}
	}
}

// The funding check now validates the resolved quote asset, so a deployment that sets only
// CASH_ASSET_ADDRESS still starts -- and one that sets only QUOTE_ASSET_ADDRESS does too.
func TestValidateFundingCheckAcceptsEitherQuoteVariable(t *testing.T) {
	base := Config{
		AppEnv:              "production",
		EnforceFundingCheck: true,
		MatchingAddress:     "0x1111111111111111111111111111111111111111",
		ChainRPCURL:         "https://rpc.example",
	}

	onlyCash := base
	onlyCash.CashAssetAddress = "0x2222222222222222222222222222222222222222"
	if err := onlyCash.validateFundingCheck(); err != nil {
		t.Fatalf("CASH_ASSET_ADDRESS alone must still satisfy the guard: %v", err)
	}

	onlyQuote := base
	onlyQuote.QuoteAssetAddress = "0x364058aff6f36e01505fb2cc870f8b6bd4835e84"
	if err := onlyQuote.validateFundingCheck(); err != nil {
		t.Fatalf("QUOTE_ASSET_ADDRESS alone must satisfy the guard: %v", err)
	}

	neither := base
	if err := neither.validateFundingCheck(); err == nil {
		t.Fatal("neither variable set must be refused in production")
	}
}
