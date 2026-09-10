package matching

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

const (
	testTradeModule = "0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c"
	testCashAsset   = "0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6"
	testWrappedUSDC = "0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84"
)

// rpcReturning answers every eth_call with the given address, and records the calldata so a test
// can prove it asked for quoteAsset() rather than something that merely happened to work.
func rpcReturning(t *testing.T, addr string, seen *[]string) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		if len(req.Params) > 0 {
			var call struct {
				Data string `json:"data"`
			}
			_ = json.Unmarshal(req.Params[0], &call)
			if seen != nil {
				*seen = append(*seen, call.Data)
			}
		}
		word := "0x" + strings.Repeat("0", 24) + strings.ToLower(strings.TrimPrefix(addr, "0x"))
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"` + word + `"}`))
	}))
}

func pairingConfig(rpcURL, quote string) config.Config {
	return config.Config{
		ChainRPCURL:        rpcURL,
		TradeModuleAddress: testTradeModule,
		CashAssetAddress:   quote,
	}
}

func TestQuoteAssetPairingMatches(t *testing.T) {
	var seen []string
	srv := rpcReturning(t, testCashAsset, &seen)
	defer srv.Close()

	if err := verifyQuoteAssetMatchesTradeModule(context.Background(), pairingConfig(srv.URL, testCashAsset)); err != nil {
		t.Fatalf("matching pair must be accepted, got %v", err)
	}
	if len(seen) != 1 || seen[0] != quoteAssetSelector {
		t.Fatalf("must call quoteAsset() exactly once, saw %v", seen)
	}
}

// The failure this whole check exists for: TRADE_MODULE_ADDRESS moved to a wrapped-quote module
// and QUOTE_ASSET_ADDRESS did not, so every buy would be judged against a cash balance while
// settlement debits wrapped USDC.
func TestQuoteAssetPairingMismatchIsFatal(t *testing.T) {
	srv := rpcReturning(t, testWrappedUSDC, nil)
	defer srv.Close()

	err := verifyQuoteAssetMatchesTradeModule(context.Background(), pairingConfig(srv.URL, testCashAsset))
	if err == nil {
		t.Fatal("a mismatched pair must refuse to start")
	}
	if !errors.Is(err, ErrQuoteAssetMismatch) {
		t.Fatalf("must be identifiable as a pairing mismatch, got %v", err)
	}
	for _, want := range []string{testCashAsset, testWrappedUSDC, testTradeModule} {
		if !strings.Contains(strings.ToLower(err.Error()), strings.ToLower(want)) {
			t.Fatalf("error must name %s so an operator can fix it: %v", want, err)
		}
	}
}

func TestQuoteAssetPairingIsCaseInsensitive(t *testing.T) {
	srv := rpcReturning(t, strings.ToUpper(strings.TrimPrefix(testCashAsset, "0x")), nil)
	defer srv.Close()

	if err := verifyQuoteAssetMatchesTradeModule(context.Background(), pairingConfig(srv.URL, strings.ToLower(testCashAsset))); err != nil {
		t.Fatalf("address comparison must not depend on checksum casing, got %v", err)
	}
}

// An unreachable RPC says nothing about whether the config is right. Crash-looping the matcher
// over a flaky endpoint would take matching down for a reason unrelated to the fault this guards.
func TestQuoteAssetPairingUnreachableRPCIsNotFatal(t *testing.T) {
	srv := rpcReturning(t, testCashAsset, nil)
	srv.Close() // closed on purpose

	if err := verifyQuoteAssetMatchesTradeModule(context.Background(), pairingConfig(srv.URL, testCashAsset)); err != nil {
		t.Fatalf("an unreachable RPC must not be fatal, got %v", err)
	}
}

func TestQuoteAssetPairingUnconfiguredIsNotFatal(t *testing.T) {
	for name, cfg := range map[string]config.Config{
		"no rpc":          {TradeModuleAddress: testTradeModule, CashAssetAddress: testCashAsset},
		"no trade module": {ChainRPCURL: "http://127.0.0.1:1", CashAssetAddress: testCashAsset},
		"no quote asset":  {ChainRPCURL: "http://127.0.0.1:1", TradeModuleAddress: testTradeModule},
	} {
		if err := verifyQuoteAssetMatchesTradeModule(context.Background(), cfg); err != nil {
			t.Fatalf("%s: must not be fatal, got %v", name, err)
		}
	}
}
