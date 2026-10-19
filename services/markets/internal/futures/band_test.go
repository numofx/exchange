package futures

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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

// The edges are the last prices Allows admits, whatever the index. 1400.123456789 x 0.1 is a whole
// number of wei, so the case above cannot tell index x (1 - w) from index - floor(index x w); an index
// that does not divide can (the live series' index on 2026-10-13, where fill_band_low read 1 wei below
// the chain's edge).
func TestBandEdgesAreTheLastAdmittedPricesWhenIndexTimesWidthDoesNotDivide(t *testing.T) {
	for _, band := range []Band{
		{Index: e18("1365.749460529001828479"), Width: e18("0.1")},
		{Index: e18("1386.044666769033003345"), Width: e18("0.013")},
		{Index: big.NewInt(7), Width: e18("0.5")},
	} {
		if new(big.Int).Mod(new(big.Int).Mul(band.Index, band.Width), one18).Sign() == 0 {
			t.Fatalf("fixture %s x %s divides: it cannot catch the rounding", band.Index, band.Width)
		}
		low, high := band.Low(), band.High()
		if !band.Allows(low) || band.Allows(new(big.Int).Sub(low, big.NewInt(1))) {
			t.Errorf("index %s: Low %s is not the lowest admitted price", band.Index, low)
		}
		if !band.Allows(high) || band.Allows(new(big.Int).Add(high, big.NewInt(1))) {
			t.Errorf("index %s: High %s is not the highest admitted price", band.Index, high)
		}
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
		"getPendingVM(uint256,uint256)": sigGetPendingVM, "getMargin(uint256,bool)": sigGetMargin,
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

// A fill's mark is read at the fill's own block, past the cache, so the VM recorded with it is the
// one the chain settled rather than a mark up to stateTTL old.
func TestMarkAtReadsTheMarkAtTheGivenBlock(t *testing.T) {
	c := newChain()
	inner := c.serve(t)
	defer inner.Close()
	var tags []string
	srv := httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.Unmarshal(body, &req)
		var tag string
		_ = json.Unmarshal(req.Params[1], &tag)
		tags = append(tags, tag)
		resp, err := http.Post(inner.URL, "application/json", bytes.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		_, _ = io.Copy(rw, resp.Body)
	}))
	defer srv.Close()

	reader := NewReader(srv.URL, c.future, 1798675200, time.Minute, time.Minute)
	for range 2 {
		mark, err := reader.MarkAt(context.Background(), 52646406)
		if err != nil {
			t.Fatal(err)
		}
		if mark.Cmp(e18("1400")) != 0 {
			t.Fatalf("mark %s, want 1400e18", mark)
		}
	}
	if len(tags) != 2 || tags[0] != "0x3235206" || tags[1] != "0x3235206" {
		t.Fatalf("block tags %v, want two reads at 0x3235206 (52646406), uncached", tags)
	}
}

// A block with the fill at transaction index 5: MarkSets at the given indexes, each moving the mark
// from old to new, and the mark the block ends on.
func markBlockServer(t *testing.T, future string, marks [][3]string, endMark string) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		reply := func(result any) {
			_ = json.NewEncoder(rw).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": result})
		}
		switch req.Method {
		case "eth_getTransactionReceipt":
			reply(map[string]string{"blockNumber": "0x3235206", "transactionIndex": "0x5"})
		case "eth_getLogs":
			var filter struct {
				Address, FromBlock, ToBlock string
				Topics                      []string
			}
			_ = json.Unmarshal(req.Params[0], &filter)
			if filter.Address != future || filter.FromBlock != "0x3235206" || filter.ToBlock != "0x3235206" ||
				len(filter.Topics) != 2 || filter.Topics[0] != topicMarkSet || filter.Topics[1] != "0x"+w(big.NewInt(1798675200)) {
				t.Errorf("unexpected log filter %+v", filter)
			}
			logs := []map[string]string{}
			for i, m := range marks {
				logs = append(logs, map[string]string{
					"transactionIndex": m[0], "logIndex": fmt.Sprintf("0x%x", i),
					"data": "0x" + w(big.NewInt(1)) + w(e18(m[1])) + w(e18(m[2])) + w(big.NewInt(0)) + b(true),
				})
			}
			reply(logs)
		case "eth_call":
			var tag string
			_ = json.Unmarshal(req.Params[1], &tag)
			if tag != "0x3235206" {
				t.Errorf("mark read at %s, want the fill's block", tag)
			}
			reply("0x" + b(true) + b(false) + w(big.NewInt(1798675200)) + w(big.NewInt(0)) + w(big.NewInt(0)) + w(e18(endMark)) + w(big.NewInt(0)))
		default:
			t.Errorf("unexpected %s", req.Method)
		}
	}))
}

func TestMarkAtFillIsTheMarkTheFillSaw(t *testing.T) {
	const future = "0x00000000000000000000000000000000000000f0"
	cases := []struct {
		name  string
		marks [][3]string
		want  string
	}{
		{"no mark in the block", nil, "1400"},
		{"a mark before the fill", [][3]string{{"0x2", "1390", "1400"}}, "1400"},
		{"a mark after the fill", [][3]string{{"0x9", "1400", "1410"}}, "1400"},
		{"marks before and after", [][3]string{{"0x2", "1380", "1390"}, {"0x9", "1390", "1400"}}, "1390"},
		{"two marks after: the first", [][3]string{{"0xa", "1395", "1400"}, {"0x7", "1390", "1395"}}, "1390"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			srv := markBlockServer(t, future, tc.marks, "1400")
			defer srv.Close()
			mark, err := NewReader(srv.URL, future, 1798675200, time.Minute, time.Minute).MarkAtFill(context.Background(), "0xabc")
			if err != nil {
				t.Fatal(err)
			}
			if mark.Cmp(e18(tc.want)) != 0 {
				t.Fatalf("mark %s, want %se18", mark, tc.want)
			}
		})
	}
}

func TestTopicMarkSetMatchesItsSignature(t *testing.T) {
	if _, err := exec.LookPath("cast"); err != nil {
		t.Skip("cast not installed")
	}
	out, err := exec.Command("cast", "keccak", "MarkSet(uint96,uint64,uint256,uint256,int256,bool)").Output()
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(out)); got != topicMarkSet {
		t.Fatalf("cast keccak %s, pinned %s", got, topicMarkSet)
	}
}
