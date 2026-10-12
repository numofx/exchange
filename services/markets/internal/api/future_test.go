package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

var testWad = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

const (
	testFuture       = "0x00000000000000000000000000000000000000f0"
	testFutureFeed   = "0x00000000000000000000000000000000000000fe"
	testFutureLedger = "0x00000000000000000000000000000000000000ac"
	testFutureTM     = "0x2222222222222222222222222222222222222222"
	testFutureEngine = "0x00000000000000000000000000000000000000e9"
	testFutureExpiry = int64(1798675200)
)

// futureRPC stubs the series, its feed, SubAccounts, the TradeModule and the engine. spot is the feed's
// USDC per cNGN at 18dp; managers maps an account to its manager (the engine by default).
type futureRPC struct {
	mu        sync.Mutex
	spot      *big.Int
	stale     bool
	lastTrade int64
	managers  map[string]string
}

func newFutureRPC() *futureRPC {
	// 1/1400 USDC per cNGN: the index is 1e36 / spot = 1400.000000000000000280 cNGN per USDC
	return &futureRPC{spot: new(big.Int).Div(testWad, big.NewInt(1400)), lastTrade: time.Now().Add(24 * time.Hour).Unix(), managers: map[string]string{}}
}

func (f *futureRPC) server(t *testing.T) *httptest.Server {
	word := func(v *big.Int) string { return fmt.Sprintf("%064x", v) }
	addr := func(a string) string { return strings.Repeat("0", 24) + strings.TrimPrefix(a, "0x") }
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct{ To, Data string }
		_ = json.Unmarshal(req.Params[0], &call)
		to, sel := strings.ToLower(call.To), call.Data[:10]
		f.mu.Lock()
		defer f.mu.Unlock()
		reply := func(result string) {
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": "0x" + result})
		}
		switch {
		case to == testFuture && sel == "0x198cae76": // indexFeed()
			reply(addr(testFutureFeed))
		case to == testFutureFeed && sel == "0x2b37269c": // getSpot()
			if f.stale {
				_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
					"error": map[string]any{"code": 3, "message": "execution reverted", "data": "0x1141796d"}})
				return
			}
			reply(word(f.spot) + word(testWad))
		case to == testFuture && sel == "0x968564c5": // markIndexBand(uint64)
			reply(word(new(big.Int).Div(testWad, big.NewInt(10))))
		case to == testFuture && sel == "0xc3c74b34": // futureContracts(uint256)
			reply(word(big.NewInt(1)) + word(big.NewInt(0)) + word(big.NewInt(testFutureExpiry)) + word(big.NewInt(f.lastTrade)) +
				word(big.NewInt(0)) + word(new(big.Int).Mul(big.NewInt(1400), testWad)) + word(big.NewInt(0)))
		case to == testFuture && sel == "0x3d7cc610": // contractSize()
			reply(word(new(big.Int).Mul(big.NewInt(1000), testWad)))
		case to == testFuture && sel == "0x779e5012": // subAccounts()
			reply(addr(testFutureLedger))
		case to == testFutureLedger && sel == "0x52981457": // manager(uint256)
			account := new(big.Int)
			account.SetString(call.Data[10:], 16)
			manager, ok := f.managers[account.String()]
			if !ok {
				manager = testFutureEngine
			}
			reply(addr(manager))
		case to == testFutureTM && sel == "0x761822ef": // isDatedFutureAsset(address)
			reply(word(big.NewInt(1)))
		case to == testFuture && sel == "0x745ab570": // totalPositionCap(address)
			reply(word(new(big.Int).Mul(big.NewInt(30), testWad)))
		case to == testFutureEngine && sel == "0xac06ba05": // adjustmentsPaused()
			reply(word(big.NewInt(0)))
		default:
			t.Errorf("unexpected eth_call %s to %s", sel, to)
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "error": map[string]any{"message": "unexpected"}})
		}
	}))
}

func futureConfig(rpc string) config.Config {
	return config.Config{
		ChainRPCURL:                rpc,
		CNGNPerpTradeModuleAddress: testFutureTM,
		CNGNPerpCashAddress:        "0x4444444444444444444444444444444444444444",
		CNGNFutureAssetAddress:     testFuture,
		CNGNFutureExpiry:           testFutureExpiry,
		CNGNFutureManagerAddress:   testFutureEngine,
	}
}

func futureServer(t *testing.T, rpc string) *Server {
	t.Helper()
	cfg := futureConfig(rpc)
	return &Server{cfg: cfg, instruments: instruments.DefaultRegistry(cfg), future: newFutureStateReader(cfg)}
}

func futureEntry(t *testing.T, s *Server) map[string]any {
	t.Helper()
	rec := httptest.NewRecorder()
	s.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var entries []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("markets: %v %s", err, rec.Body.String())
	}
	for _, entry := range entries {
		if entry["asset_address"] == testFuture && entry["sub_id"] == fmt.Sprint(testFutureExpiry) {
			return entry
		}
	}
	t.Fatalf("the future is not on /v1/markets: %s", rec.Body.String())
	return nil
}

// enableGate runs the enable batch's own fills gate (propose_margin_engine_batch.py fills_gate and
// chain_fill_band) on the entry, with the chain's spot and band: the listing must pass the gate it
// was built for, judged by the gate's code, not by a restatement of it here.
func enableGate(t *testing.T, entry map[string]any, spot *big.Int) (bool, string) {
	t.Helper()
	ops, _ := filepath.Abs("../../../../contracts/risk-core/scripts/ops")
	if _, err := os.Stat(filepath.Join(ops, "propose_margin_engine_batch.py")); err != nil {
		t.Skip("the enable proposer is not in this checkout")
	}
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	listing, _ := json.Marshal(entry)
	script := `
import json, sys
sys.path.insert(0, sys.argv[1])
import propose_margin_engine_batch as p
low, high = p.chain_fill_band(int(sys.argv[3]), int(sys.argv[4]))
gate = p.fills_gate(json.loads(sys.argv[2]), low, high)
print(("PASS " if gate.ok else "FAIL ") + gate.detail)
`
	out, err := exec.Command("python3", "-c", script, ops, string(listing), spot.String(), new(big.Int).Div(testWad, big.NewInt(10)).String()).CombinedOutput()
	if err != nil {
		t.Fatalf("the enable gate did not run: %v %s", err, out)
	}
	return strings.HasPrefix(string(out), "PASS"), strings.TrimSpace(string(out))
}

func TestMarketsListsTheFutureWithTheBandTheEnableGateChecks(t *testing.T) {
	rpc := newFutureRPC()
	srv := rpc.server(t)
	defer srv.Close()
	entry := futureEntry(t, futureServer(t, srv.URL))

	if entry["fill_band_enforced"] != true || entry["contract_type"] != "future" {
		t.Fatalf("entry: %v", entry)
	}
	// index 1e36 / floor(1e18 / 1400), -/+ 10%
	index := new(big.Int).Div(new(big.Int).Mul(testWad, testWad), rpc.spot)
	wantLow := new(big.Int).Div(new(big.Int).Mul(index, big.NewInt(9)), big.NewInt(10))
	wantHigh := new(big.Int).Div(new(big.Int).Mul(index, big.NewInt(11)), big.NewInt(10))
	low, _ := new(big.Rat).SetString(entry["fill_band_low"].(string))
	high, _ := new(big.Rat).SetString(entry["fill_band_high"].(string))
	if low.Cmp(new(big.Rat).SetFrac(wantLow, testWad)) != 0 || high.Cmp(new(big.Rat).SetFrac(wantHigh, testWad)) != 0 {
		t.Fatalf("band %v-%v, expected %s-%s (18dp)", entry["fill_band_low"], entry["fill_band_high"], wantLow, wantHigh)
	}
	future := entry["future"].(map[string]any)
	if future["band_status"] != "ok" || future["trading_open"] != true || future["contract_size_usdc"] != "1000" {
		t.Fatalf("future block: %v", future)
	}

	if ok, detail := enableGate(t, entry, rpc.spot); !ok {
		t.Fatalf("the enable gate refuses the listing: %s", detail)
	}
	// and refuses one whose band is not the chain's
	shifted := map[string]any{}
	for k, v := range entry {
		shifted[k] = v
	}
	shifted["fill_band_high"] = "1600"
	if ok, detail := enableGate(t, shifted, rpc.spot); ok {
		t.Fatalf("the enable gate passed a band that is not the chain's: %s", detail)
	}
}

// A stale index is not a wide band: the edges are withheld, the status says why, and the enable gate
// refuses, as the chain refuses every fill until the feed updates.
func TestMarketsWithholdsTheBandWhileTheIndexIsStale(t *testing.T) {
	rpc := newFutureRPC()
	rpc.stale = true
	srv := rpc.server(t)
	defer srv.Close()
	entry := futureEntry(t, futureServer(t, srv.URL))
	if _, ok := entry["fill_band_low"]; ok {
		t.Fatalf("a stale index must not show a band: %v", entry)
	}
	if entry["future"].(map[string]any)["band_status"] != "index_stale" {
		t.Fatalf("future block: %v", entry["future"])
	}
	if ok, detail := enableGate(t, entry, rpc.spot); ok {
		t.Fatalf("the enable gate passed a listing with no band: %s", detail)
	}
}

func futureOrder(account, limitPrice string) orders.CreateOrderParams {
	action, _ := json.Marshal(map[string]any{
		"subaccount_id": account, "nonce": "1", "module": testFutureTM,
		"data":   mustTradeDataHex(testFuture, fmt.Sprint(testFutureExpiry), limitPrice, "1000000000000000000", true),
		"expiry": "100", "owner": "0xabc", "signer": "0xabc",
	})
	return orders.CreateOrderParams{OrderID: "o-" + account, SubaccountID: account, AssetAddress: testFuture, SubID: fmt.Sprint(testFutureExpiry), ActionJSON: action}
}

func TestAFuturesOrderIsAdmittedOnlyWhenItCouldSettle(t *testing.T) {
	maxDiff := func(index *big.Int) *big.Int { return new(big.Int).Div(index, big.NewInt(10)) }
	rpc := newFutureRPC()
	index := new(big.Int).Div(new(big.Int).Mul(testWad, testWad), rpc.spot)
	edge := new(big.Int).Add(index, maxDiff(index))
	rpc.managers["9"] = "0x0000000000000000000000000000000000000005"
	srv := rpc.server(t)
	defer srv.Close()
	s := futureServer(t, srv.URL)
	instrument, _ := s.instruments.ByAssetAndSubID(testFuture, fmt.Sprint(testFutureExpiry))

	for name, tc := range map[string]struct {
		account, price string
		status         int
		says           string
	}{
		"on the band's edge":       {"7", edge.String(), 0, ""},
		"one wei past the edge":    {"7", new(big.Int).Add(edge, big.NewInt(1)).String(), http.StatusUnprocessableEntity, "outside the band"},
		"an account under the SRM": {"9", index.String(), http.StatusUnprocessableEntity, "only MarginEngine accounts"},
	} {
		status, msg := s.admitFuture(context.Background(), instrument, futureOrder(tc.account, tc.price))
		if status != tc.status || !strings.Contains(msg, tc.says) {
			t.Errorf("%s: %d %q", name, status, msg)
		}
	}

	stale := newFutureRPC()
	stale.stale = true
	staleSrv := stale.server(t)
	defer staleSrv.Close()
	if status, msg := futureServer(t, staleSrv.URL).admitFuture(context.Background(), instrument, futureOrder("7", index.String())); status != http.StatusServiceUnavailable || !strings.Contains(msg, "stale") {
		t.Errorf("stale index: %d %q", status, msg)
	}
	closed := newFutureRPC()
	closed.lastTrade = time.Now().Add(-time.Minute).Unix()
	closedSrv := closed.server(t)
	defer closedSrv.Close()
	if status, msg := futureServer(t, closedSrv.URL).admitFuture(context.Background(), instrument, futureOrder("7", index.String())); status != http.StatusConflict || !strings.Contains(msg, "last trade time") {
		t.Errorf("past last trade: %d %q", status, msg)
	}
}

// The wiring: POST /v1/orders, against the test database, refuses an out-of-band futures order before
// it is stored, and stores one inside the band.
func TestCreateOrderRefusesAFuturesOrderOutsideTheBand(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	rpc := newFutureRPC()
	srv := rpc.server(t)
	defer srv.Close()
	cfg := futureConfig(srv.URL)
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	server.custody = fakeCustodyChecker{allow: map[string]bool{"7": true}}
	suffix := fmt.Sprintf("future-intake-%d", time.Now().UnixNano())
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%") })

	submit := func(id, ticks string) *httptest.ResponseRecorder {
		action := map[string]any{"subaccount_id": "7", "nonce": id, "module": testFutureTM,
			"data":   mustTradeDataHex(testFuture, fmt.Sprint(testFutureExpiry), ticks+"000000000000000000", "1000000000000000000", true),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()), "owner": "0xabc", "signer": "0xabc"}
		body, _ := json.Marshal(map[string]any{
			"order_id": suffix + "-" + id, "owner_address": "0xabc", "signer_address": "0xabc", "subaccount_id": "7", "recipient_id": "7",
			"nonce": id, "side": "buy", "asset_address": testFuture, "sub_id": fmt.Sprint(testFutureExpiry), "desired_amount": "1",
			"filled_amount": "0", "limit_price": ticks, "worst_fee": "2500000000000000000", "expiry": time.Now().Add(time.Hour).Unix(),
			"action_json": action, "signature": "0xsig",
		})
		rec := httptest.NewRecorder()
		server.handleCreateOrder(rec, httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body)))
		return rec
	}
	stored := func(id string) bool {
		var n int
		_ = pool.QueryRow(ctx, "select count(*) from active_orders where order_id = $1", suffix+"-"+id).Scan(&n)
		return n == 1
	}

	// band 1,260-1,540
	if rec := submit("1", "1600"); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "fill_band") || stored("1") {
		t.Fatalf("out of band: %d %s, stored %v", rec.Code, rec.Body.String(), stored("1"))
	}
	if rec := submit("2", "1400"); rec.Code >= 300 || !stored("2") {
		t.Fatalf("in band: %d %s, stored %v", rec.Code, rec.Body.String(), stored("2"))
	}
}

// The integrations endpoints are spot-pair formats (base volume is the amount, target volume price x
// amount): neither holds for a future, so it is not listed there and its ticker is refused.
func TestIntegrationsLeaveTheFutureOut(t *testing.T) {
	rpc := newFutureRPC()
	srv := rpc.server(t)
	defer srv.Close()
	s := futureServer(t, srv.URL)
	symbol := instruments.FutureSymbol(testFutureExpiry)
	for _, path := range []string{"/v1/integrations/orderbook?ticker_id=" + symbol, "/v1/integrations/trades?ticker_id=" + symbol} {
		rec := httptest.NewRecorder()
		handler := s.handleIntegrationOrderbook
		if strings.Contains(path, "trades") {
			handler = s.handleIntegrationTrades
		}
		handler(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), "dated future") {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
	}
	rec := httptest.NewRecorder()
	s.handleIntegrationTickers(rec, httptest.NewRequest(http.MethodGet, "/v1/integrations/tickers", nil))
	if strings.Contains(rec.Body.String(), symbol) {
		t.Fatalf("tickers list the future: %s", rec.Body.String())
	}
}
