package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

func gateRPC(t *testing.T, allowed, positionCap int64, fail bool) *httptest.Server {
	return gateRPCPaused(t, allowed, positionCap, 0, fail)
}

func gateRPCPaused(t *testing.T, allowed, positionCap, paused int64, fail bool) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if fail {
			http.Error(w, "down", http.StatusBadGateway)
			return
		}
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct {
			Data string `json:"data"`
		}
		_ = json.Unmarshal(req.Params[0], &call)
		value := allowed
		if strings.HasPrefix(strings.ToLower(call.Data), totalPositionCapSelector) {
			value = positionCap
		}
		if strings.HasPrefix(strings.ToLower(call.Data), adjustmentsPausedSelector) {
			value = paused
		}
		_, _ = w.Write([]byte(fmt.Sprintf(`{"jsonrpc":"2.0","id":1,"result":"0x%064x"}`, value)))
	}))
}

func gateFor(url string) *perpTradingGate {
	return newPerpTradingGate(config.Config{
		ChainRPCURL:                url,
		MatchingAddress:            "0x1111111111111111111111111111111111111111",
		CNGNPerpAssetAddress:       "0x3333333333333333333333333333333333333333",
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x4444444444444444444444444444444444444444",
		CNGNPerpSRMAddress:         "0x5555555555555555555555555555555555555555",
	})
}

func TestPerpGateOpensOnlyWithModuleAndCap(t *testing.T) {
	for _, tc := range []struct {
		name          string
		allowed, cap_ int64
		want          bool
	}{
		{"deployed, not enabled", 0, 0, false},
		{"module allowlisted but cap still 0", 1, 0, false},
		{"cap raised but module not allowlisted", 0, 50, false},
		{"both halves of the enable action", 1, 50, true},
	} {
		srv := gateRPC(t, tc.allowed, tc.cap_, false)
		if got := gateFor(srv.URL).Open(context.Background()); got != tc.want {
			t.Errorf("%s: open = %v, want %v", tc.name, got, tc.want)
		}
		srv.Close()
	}
}

// The guardian's pause closes the gate on its own: enabled, capped, and paused is not open.
func TestPerpGateClosesWhileTheGuardianPauseHolds(t *testing.T) {
	srv := gateRPCPaused(t, 1, 50, 1, false)
	defer srv.Close()
	if gateFor(srv.URL).Open(context.Background()) {
		t.Fatal("a paused SRM must read as closed")
	}
}

// Not knowing whether the market is open is not a reason to cross orders into it.
func TestPerpGateFailsClosedWhenTheChainIsUnreadable(t *testing.T) {
	srv := gateRPC(t, 1, 50, true)
	defer srv.Close()
	if gateFor(srv.URL).Open(context.Background()) {
		t.Fatal("an unreadable chain must read as closed")
	}
}
