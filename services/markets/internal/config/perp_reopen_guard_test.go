package config

import (
	"strings"
	"testing"
)

// loadPerpEnv loads the config from the environment with a whole perp stack and the given close-only
// switch and acknowledgement ("" leaves a variable unset).
func loadPerpEnv(t *testing.T, closeOnly, ack string) (Config, error) {
	t.Helper()
	t.Setenv("DATABASE_URL", "postgres://test")
	t.Setenv("APP_ENV", "test")
	t.Setenv("CNGN_PERP_ASSET_ADDRESS", "0x3333333333333333333333333333333333333333")
	t.Setenv("CNGN_PERP_TRADE_MODULE_ADDRESS", "0x2222222222222222222222222222222222222222")
	t.Setenv("CNGN_PERP_CASH_ADDRESS", "0x4444444444444444444444444444444444444444")
	t.Setenv("CNGN_PERP_SRM_ADDRESS", "0x5555555555555555555555555555555555555555")
	t.Setenv("CNGN_PERP_CLOSE_ONLY", closeOnly)
	t.Setenv("CNGN_PERP_REOPEN_ACK", ack)
	return Load()
}

// A configured perp may not boot out of close-only until numofx/trading-app#131 is fixed, whichever
// path deploys it: Load refuses unless CNGN_PERP_REOPEN_ACK names the issue, and says why.
func TestThePerpCannotBootOutOfCloseOnlyWithoutTheAck(t *testing.T) {
	for _, tc := range []struct {
		name, closeOnly, ack string
		boots                bool
	}{
		{"close-only", "true", "", true},
		{"close-only, ack set too", "true", PerpReopenAck, true},
		{"close-only unset", "", "", false},
		{"close-only off", "false", "", false},
		{"close-only off, wrong ack", "false", "yes", false},
		{"close-only off, ack", "false", PerpReopenAck, true},
		{"close-only off, ack with spaces", "false", "  " + PerpReopenAck + " ", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := loadPerpEnv(t, tc.closeOnly, tc.ack)
			if tc.boots && err != nil {
				t.Fatalf("want it to boot, got %v", err)
			}
			if !tc.boots {
				if err == nil {
					t.Fatal("want it refused")
				}
				for _, why := range []string{"trading-app#131", "CNGN_PERP_CLOSE_ONLY=true", "CNGN_PERP_REOPEN_ACK=" + PerpReopenAck} {
					if !strings.Contains(err.Error(), why) {
						t.Fatalf("the refusal must say %q: %v", why, err)
					}
				}
			}
		})
	}
}

// Without a perp the switch and the acknowledgement mean nothing, and boot is unaffected.
func TestNoPerpBootsWithoutTheAck(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://test")
	t.Setenv("APP_ENV", "test")
	for _, key := range []string{"CNGN_PERP_ASSET_ADDRESS", "CNGN_PERP_TRADE_MODULE_ADDRESS", "CNGN_PERP_CASH_ADDRESS", "CNGN_PERP_SRM_ADDRESS", "CNGN_PERP_CLOSE_ONLY", "CNGN_PERP_REOPEN_ACK"} {
		t.Setenv(key, "")
	}
	if _, err := Load(); err != nil {
		t.Fatalf("no perp must boot: %v", err)
	}
}
