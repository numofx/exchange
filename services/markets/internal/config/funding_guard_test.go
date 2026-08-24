package config

import (
	"strings"
	"testing"
)

func baseCfg() Config {
	return Config{
		AppEnv:              "production",
		EnforceFundingCheck: true,
		CashAssetAddress:    "0x2222222222222222222222222222222222222222",
		MatchingAddress:     "0x1111111111111111111111111111111111111111",
		ChainRPCURL:         "https://mainnet.base.org",
	}
}

func TestFundingGuardAcceptsAFullyConfiguredProduction(t *testing.T) {
	if err := baseCfg().validateFundingCheck(); err != nil {
		t.Fatalf("fully configured production must start: %v", err)
	}
}

func TestFundingGuardRefusesProductionWithoutEachRequiredVariable(t *testing.T) {
	cases := map[string]func(*Config){
		"CASH_ASSET_ADDRESS": func(c *Config) { c.CashAssetAddress = "" },
		"MATCHING_ADDRESS":   func(c *Config) { c.MatchingAddress = "" },
		"CHAIN_RPC_URL":      func(c *Config) { c.ChainRPCURL = "" },
	}

	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := baseCfg()
			mutate(&cfg)

			err := cfg.validateFundingCheck()
			if err == nil {
				t.Fatalf("production without %s must refuse to start", name)
			}
			if !strings.Contains(err.Error(), name) {
				t.Fatalf("error must name the missing variable, got: %v", err)
			}
			// the operator needs to know the deliberate way out, not just that something is wrong
			if !strings.Contains(err.Error(), "ENFORCE_FUNDING_CHECK=false") {
				t.Fatalf("error must offer the deliberate opt-out, got: %v", err)
			}
		})
	}
}

// A zero address is configuration that looks present and is not. It must be rejected the same as
// an empty one, or the guard passes while newFundingChecker still returns nil.
func TestFundingGuardRejectsTheZeroAddress(t *testing.T) {
	cfg := baseCfg()
	cfg.CashAssetAddress = "0x0000000000000000000000000000000000000000"
	if err := cfg.validateFundingCheck(); err == nil {
		t.Fatal("the zero address must not satisfy the guard")
	}
}

func TestFundingGuardRejectsAMalformedAddress(t *testing.T) {
	for _, bad := range []string{"0x123", "2222222222222222222222222222222222222222", "not-an-address"} {
		cfg := baseCfg()
		cfg.CashAssetAddress = bad
		if err := cfg.validateFundingCheck(); err == nil {
			t.Fatalf("malformed address %q must not satisfy the guard", bad)
		}
	}
}

// Opting out is allowed; falling into it is not.
func TestFundingGuardAllowsADeliberateOptOut(t *testing.T) {
	cfg := baseCfg()
	cfg.CashAssetAddress = ""
	cfg.EnforceFundingCheck = false

	if err := cfg.validateFundingCheck(); err != nil {
		t.Fatalf("an explicit opt-out must be honoured: %v", err)
	}
}

func TestFundingGuardDoesNotBlockDevelopment(t *testing.T) {
	for _, env := range []string{"", "dev", "development", "local", "test", "ci", "DEV", " dev "} {
		cfg := baseCfg()
		cfg.AppEnv = env
		cfg.CashAssetAddress = ""

		if err := cfg.validateFundingCheck(); err != nil {
			t.Fatalf("APP_ENV=%q must not be blocked: %v", env, err)
		}
	}
}

// An unrecognised APP_ENV is treated as production. A typo must fail safe rather than quietly
// turning the guard off.
func TestUnknownEnvironmentIsTreatedAsProduction(t *testing.T) {
	for _, env := range []string{"production", "prod", "staging", "mainnet", "prodution"} {
		cfg := baseCfg()
		cfg.AppEnv = env

		if !cfg.IsProduction() {
			t.Fatalf("APP_ENV=%q must be treated as production", env)
		}

		cfg.CashAssetAddress = ""
		if err := cfg.validateFundingCheck(); err == nil {
			t.Fatalf("APP_ENV=%q must refuse to start without CASH_ASSET_ADDRESS", env)
		}
	}
}

func TestFundingGuardNamesEveryMissingVariableAtOnce(t *testing.T) {
	cfg := baseCfg()
	cfg.CashAssetAddress = ""
	cfg.MatchingAddress = ""
	cfg.ChainRPCURL = ""

	err := cfg.validateFundingCheck()
	if err == nil {
		t.Fatal("expected a refusal")
	}
	for _, want := range []string{"CASH_ASSET_ADDRESS", "MATCHING_ADDRESS", "CHAIN_RPC_URL"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error must name %s so one restart fixes all of them, got: %v", want, err)
		}
	}
}
