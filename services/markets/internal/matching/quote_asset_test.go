package matching

import (
	"context"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

const (
	cashAsset    = "0x2222222222222222222222222222222222222222"
	wrappedQuote = "0x364058aff6f36e01505fb2cc870f8b6bd4835e84"
)

// A wrapped-quote TradeModule settles the quote leg in a WrappedERC20Asset, not in the CashAsset.
// The funding check has to follow it there. Reading the cash ledger for a wrapped-quote module is
// worse than not checking at all: a buyer with no cash and plenty of wrapped USDC is rejected, and
// a buyer with cash and no wrapped USDC is waved through into a fill that reverts on chain.
func TestFundingCheckerReadsTheConfiguredQuoteAsset(t *testing.T) {
	var seen []string
	srv := newStubRPC(t, "0x3333333333333333333333333333333333333333", word("de0b6b3a7640000"), func(data string) {
		seen = append(seen, data)
	})
	defer srv.Close()

	cfg := testCfg(srv.URL)
	cfg.QuoteAssetAddress = wrappedQuote

	checker := newFundingChecker(cfg)
	if checker == nil {
		t.Fatal("checker must be constructed when configured")
	}
	if _, err := checker.QuoteBalance(context.Background(), "42"); err != nil {
		t.Fatalf("QuoteBalance: %v", err)
	}

	last := seen[len(seen)-1]
	wantArgs := word("2a") + word("364058aff6f36e01505fb2cc870f8b6bd4835e84") + word("0")
	if last[10:] != wantArgs {
		t.Fatalf("balance call read the wrong asset\n got %s\nwant %s", last[10:], wantArgs)
	}
	if last[10:] == word("2a")+word("2222222222222222222222222222222222222222")+word("0") {
		t.Fatal("balance call still reads the cash asset")
	}
}

// Every deployment that predates the wrapped-quote migration sets only CASH_ASSET_ADDRESS. It must
// keep reading exactly the contract it always did, with no new variable to set.
func TestFundingCheckerFallsBackToCashAssetWhenQuoteAssetUnset(t *testing.T) {
	var seen []string
	srv := newStubRPC(t, "0x3333333333333333333333333333333333333333", word("de0b6b3a7640000"), func(data string) {
		seen = append(seen, data)
	})
	defer srv.Close()

	cfg := testCfg(srv.URL) // sets CashAssetAddress, leaves QuoteAssetAddress empty
	if cfg.QuoteAssetAddress != "" {
		t.Fatal("fixture must leave QuoteAssetAddress unset")
	}

	if _, err := newFundingChecker(cfg).QuoteBalance(context.Background(), "42"); err != nil {
		t.Fatalf("QuoteBalance: %v", err)
	}

	last := seen[len(seen)-1]
	wantArgs := word("2a") + word("2222222222222222222222222222222222222222") + word("0")
	if last[10:] != wantArgs {
		t.Fatalf("fallback did not read the cash asset\n got %s\nwant %s", last[10:], wantArgs)
	}
}

func TestQuoteAssetResolution(t *testing.T) {
	cases := map[string]struct {
		cfg  config.Config
		want string
	}{
		"quote set wins": {
			cfg:  config.Config{CashAssetAddress: cashAsset, QuoteAssetAddress: wrappedQuote},
			want: wrappedQuote,
		},
		"quote unset falls back": {
			cfg:  config.Config{CashAssetAddress: cashAsset},
			want: cashAsset,
		},
		"both unset stays empty": {
			cfg:  config.Config{},
			want: "",
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := tc.cfg.QuoteAsset(); got != tc.want {
				t.Fatalf("QuoteAsset() = %q, want %q", got, tc.want)
			}
		})
	}
}

// The funding check is inert without a quote asset, and says so. A silently inert guard is the
// failure mode this whole path exists to avoid, and it is the one a half-finished migration --
// CASH_ASSET_ADDRESS removed, QUOTE_ASSET_ADDRESS not yet added -- lands in.
func TestFundingCheckerIsInertWithNoQuoteAssetAtAll(t *testing.T) {
	cfg := testCfg("http://127.0.0.1:1")
	cfg.CashAssetAddress = ""
	cfg.QuoteAssetAddress = ""

	if checker := newFundingChecker(cfg); checker != nil {
		t.Fatal("checker must be nil when no quote asset is configured")
	}
}
