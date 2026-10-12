package futures

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func e18(s string) *big.Int {
	v, ok := new(big.Rat).SetString(s)
	if !ok {
		panic(s)
	}
	v.Mul(v, new(big.Rat).SetInt(one18))
	if !v.IsInt() {
		panic(s)
	}
	return new(big.Int).Set(v.Num())
}

// The edges are FutureAsset's own: the last price it admits passes, one wei further does not.
func TestBandAllowsExactlyWhatTheChainAdmits(t *testing.T) {
	band := Band{Index: e18("1400.123456789"), Width: e18("0.1")}
	// diff * 1e18 <= index * width, so the largest admitted diff is floor(index * width / 1e18)
	maxDiff := new(big.Int).Div(new(big.Int).Mul(band.Index, band.Width), one18)
	above := new(big.Int).Add(band.Index, maxDiff)
	below := new(big.Int).Sub(band.Index, maxDiff)
	if !band.Allows(above) || !band.Allows(below) || !band.Allows(band.Index) {
		t.Fatal("a price on the band's edge must pass")
	}
	if band.Allows(new(big.Int).Add(above, big.NewInt(1))) || band.Allows(new(big.Int).Sub(below, big.NewInt(1))) {
		t.Fatal("one wei past the edge must fail")
	}
	if band.High().Cmp(above) != 0 || band.Low().Cmp(below) != 0 {
		t.Fatalf("edges: low %s high %s, expected %s %s", band.Low(), band.High(), below, above)
	}
}

func TestZeroWidthIsNoCheckAsOnChain(t *testing.T) {
	band := Band{Index: e18("1400"), Width: big.NewInt(0)}
	if !band.Allows(e18("1")) || !band.Allows(e18("100000")) {
		t.Fatal("FutureAsset skips the check when markIndexBand is zero")
	}
}

func TestDecimal(t *testing.T) {
	for in, want := range map[string]string{
		"1400.1234": "1400.1234", "0.000000000000000001": "0.000000000000000001", "1000": "1000", "-2.5": "-2.5",
	} {
		if got := Decimal(e18(in)); got != want {
			t.Errorf("Decimal(%s) = %s", in, got)
		}
	}
}

// A JSON-RPC stub of the future, its index feed, a TradeModule and a manager.
type chain struct {
	spot, width, cap      *big.Int
	listed, settled       bool
	lastTrade             int64
	dated, paused, stale  bool
	calls                 atomic.Int64
	future, feed, tm, mgr string
}

func newChain() *chain {
	return &chain{
		spot: new(big.Int).Div(new(big.Int).Mul(one18, one18), e18("1400")), width: e18("0.1"), cap: e18("30"),
		listed: true, lastTrade: time.Now().Add(24 * time.Hour).Unix(), dated: true,
		future: "0x00000000000000000000000000000000000000f0", feed: "0x00000000000000000000000000000000000000fe",
		tm: "0x00000000000000000000000000000000000000a1", mgr: "0x00000000000000000000000000000000000000e9",
	}
}

func w(v *big.Int) string { return fmt.Sprintf("%064x", v) }
func b(v bool) string {
	if v {
		return w(big.NewInt(1))
	}
	return w(big.NewInt(0))
}

func (c *chain) serve(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		c.calls.Add(1)
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct{ To, Data string }
		_ = json.Unmarshal(req.Params[0], &call)
		reply := func(result string) {
			_ = json.NewEncoder(rw).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": "0x" + result})
		}
		to, sel := strings.ToLower(call.To), call.Data[:10]
		switch {
		case to == c.future && sel == sigIndexFeed:
			reply(strings.Repeat("0", 24) + c.feed[2:])
		case to == c.feed && sel == sigGetSpot:
			if c.stale {
				_ = json.NewEncoder(rw).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
					"error": map[string]any{"code": 3, "message": "execution reverted", "data": errDataTooOld}})
				return
			}
			reply(w(c.spot) + w(one18))
		case to == c.future && sel == sigMarkIndexBand:
			reply(w(c.width))
		case to == c.future && sel == sigFutureContracts:
			reply(b(c.listed) + b(c.settled) + w(big.NewInt(1798675200)) + w(big.NewInt(c.lastTrade)) +
				w(big.NewInt(0)) + w(e18("1400")) + w(big.NewInt(0)))
		case to == c.future && sel == sigContractSize:
			reply(w(e18("1000")))
		case to == c.tm && sel == sigIsDatedFutureAsset:
			reply(b(c.dated))
		case to == c.future && sel == sigTotalPositionCap:
			reply(w(c.cap))
		case to == c.mgr && sel == sigAdjustmentsPaused:
			reply(b(c.paused))
		default:
			t.Errorf("unexpected eth_call to %s %s", to, sel)
			_ = json.NewEncoder(rw).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "error": map[string]any{"message": "unexpected"}})
		}
	}))
}

func TestReaderReadsTheBandAsTheChainComputesIt(t *testing.T) {
	c := newChain()
	srv := c.serve(t)
	defer srv.Close()
	r := NewReader(srv.URL, c.future, 1798675200, time.Minute, time.Minute)
	band, err := r.Band(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	wantIndex := new(big.Int).Div(one36, c.spot)
	if band.Index.Cmp(wantIndex) != 0 || band.Width.Cmp(c.width) != 0 {
		t.Fatalf("band %s/%s, expected %s/%s", band.Index, band.Width, wantIndex, c.width)
	}
	before := c.calls.Load()
	if _, err := r.Band(context.Background()); err != nil || c.calls.Load() != before {
		t.Fatal("a second read inside the TTL must come from the cache")
	}
	size, err := r.ContractSize(context.Background())
	if err != nil || size.Cmp(e18("1000")) != 0 {
		t.Fatalf("contract size %v %v", size, err)
	}
}

func TestAStaleIndexIsErrIndexStale(t *testing.T) {
	c := newChain()
	c.stale = true
	srv := c.serve(t)
	defer srv.Close()
	_, err := NewReader(srv.URL, c.future, 1798675200, time.Minute, time.Minute).Band(context.Background())
	if !errors.Is(err, ErrIndexStale) {
		t.Fatalf("expected ErrIndexStale, got %v", err)
	}
}

func TestTradingOpenNamesEveryReasonAFillCouldNotSettle(t *testing.T) {
	cases := map[string]func(*chain){
		"":                         func(*chain) {},
		"not listed":               func(c *chain) { c.listed = false },
		"has settled":              func(c *chain) { c.settled = true },
		"past its last trade time": func(c *chain) { c.lastTrade = time.Now().Add(-time.Second).Unix() },
		"dated future":             func(c *chain) { c.dated = false },
		"no position cap":          func(c *chain) { c.cap = big.NewInt(0) },
		"paused":                   func(c *chain) { c.paused = true },
	}
	for want, mutate := range cases {
		c := newChain()
		mutate(c)
		srv := c.serve(t)
		open, reason, err := NewReader(srv.URL, c.future, 1798675200, time.Minute, time.Minute).TradingOpen(context.Background(), c.tm, c.mgr)
		srv.Close()
		if err != nil {
			t.Fatalf("%q: %v", want, err)
		}
		if want == "" {
			if !open {
				t.Fatalf("an enabled series must be open, got %q", reason)
			}
			continue
		}
		if open || !strings.Contains(reason, want) {
			t.Fatalf("expected closed with %q, got open=%v %q", want, open, reason)
		}
	}
}

func TestSelectorsMatchTheirSignatures(t *testing.T) {
	if _, err := exec.LookPath("cast"); err != nil {
		t.Skip("cast not installed; selectorcheck covers these against the compiled ABIs")
	}
	for sig, sel := range map[string]string{
		"indexFeed()": sigIndexFeed, "getSpot()": sigGetSpot, "markIndexBand(uint64)": sigMarkIndexBand,
		"futureContracts(uint256)": sigFutureContracts, "contractSize()": sigContractSize,
		"isDatedFutureAsset(address)": sigIsDatedFutureAsset, "totalPositionCap(address)": sigTotalPositionCap,
		"adjustmentsPaused()": sigAdjustmentsPaused, "BLF_DataTooOld()": errDataTooOld,
	} {
		out, err := exec.Command("cast", "sig", sig).Output()
		if err != nil {
			t.Fatal(err)
		}
		if got := strings.TrimSpace(string(out)); got != sel {
			t.Errorf("%s: cast sig %s, pinned %s", sig, got, sel)
		}
	}
}
