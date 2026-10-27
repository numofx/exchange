package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// Three series listed side by side, as 30NOV26 will be (exchange #228): v1's inverse USDC-cNGN on the
// v1 engine, and v2's linear cNGN and EURC on the v2 engine, all at the same expiry on different
// FutureAssets. The EURC FutureAsset is a placeholder: it is not deployed.
const (
	seriesExpiry   = int64(1796047200) // 2026-11-30 14:00 UTC
	seriesV1       = "0x00000000000000000000000000000000000000f1"
	seriesV2CNGN   = "0x00000000000000000000000000000000000000f2"
	seriesV2EURC   = "0x00000000000000000000000000000000000000f3"
	seriesCNGNFeed = "0x00000000000000000000000000000000000000fc"
	seriesEURCFeed = "0x00000000000000000000000000000000000000fd"
	seriesV1Engine = "0x00000000000000000000000000000000000000e1"
	seriesV2Engine = "0x00000000000000000000000000000000000000e2"
)

// seriesStub is one FutureAsset series on the multi-series chain.
type seriesStub struct {
	feed      string
	size      *big.Int // contractSize(), 18dp
	mark      *big.Int // the series' own price unit, 18dp
	lastTrade int64
	// positionCap is totalPositionCap(engine); zero is a series not yet enabled.
	positionCap *big.Int
	positions   map[string]*big.Int
	pendingVM   map[string]*big.Int
}

// seriesChain stubs every FutureAsset by address, their feeds, SubAccounts, the TradeModule and both
// engines. A call for another expiry, or an asset it does not list, fails the test: a series read at
// another's address or expiry is the bug #228 is about.
type seriesChain struct {
	mu     sync.Mutex
	series map[string]*seriesStub
	spot   map[string]*big.Int // feed -> getSpot, USDC per base
	// managers maps an account to its manager; absent is the v1 engine.
	managers map[string]string
	// surplus maps an engine to getMargin(account, true) for every account, USD.
	surplus map[string]*big.Int
}

func newSeriesChain() *seriesChain {
	later := time.Now().Add(24 * time.Hour).Unix()
	cngnSpot := new(big.Int).Div(testWad, big.NewInt(1400)) // 0.000714285714285714 USDC per cNGN
	eurcSpot := new(big.Int).Div(new(big.Int).Mul(big.NewInt(116), testWad), big.NewInt(100))
	cap30 := new(big.Int).Mul(big.NewInt(30), testWad)
	return &seriesChain{
		spot: map[string]*big.Int{seriesCNGNFeed: cngnSpot, seriesEURCFeed: eurcSpot},
		series: map[string]*seriesStub{
			seriesV1: {feed: seriesCNGNFeed, size: new(big.Int).Mul(big.NewInt(1000), testWad),
				mark: new(big.Int).Mul(big.NewInt(1400), testWad), lastTrade: later, positionCap: cap30},
			seriesV2CNGN: {feed: seriesCNGNFeed, size: new(big.Int).Mul(big.NewInt(1_000_000), testWad),
				mark: new(big.Int).Set(cngnSpot), lastTrade: later, positionCap: cap30},
			seriesV2EURC: {feed: seriesEURCFeed, size: new(big.Int).Mul(big.NewInt(1000), testWad),
				mark: new(big.Int).Set(eurcSpot), lastTrade: later, positionCap: cap30},
		},
		managers: map[string]string{},
		surplus:  map[string]*big.Int{seriesV1Engine: new(big.Int).Mul(big.NewInt(500), testWad), seriesV2Engine: new(big.Int).Mul(big.NewInt(700), testWad)},
	}
}

func (c *seriesChain) server(t *testing.T) *httptest.Server {
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
		c.mu.Lock()
		defer c.mu.Unlock()
		reply := func(result string) {
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": "0x" + result})
		}
		expiryAt := func(start int) {
			if expiry, _ := new(big.Int).SetString(call.Data[start:start+64], 16); expiry.Int64() != seriesExpiry {
				t.Errorf("%s read at expiry %s", sel, expiry)
			}
		}
		series := c.series[to]
		switch {
		case series != nil && sel == "0x198cae76": // indexFeed()
			reply(addr(series.feed))
		case c.spot[to] != nil && sel == "0x2b37269c": // getSpot()
			reply(word(c.spot[to]) + word(testWad))
		case series != nil && sel == "0x968564c5": // markIndexBand(uint64)
			reply(word(new(big.Int).Div(testWad, big.NewInt(10))))
		case series != nil && sel == "0xc3c74b34": // futureContracts(uint256)
			expiryAt(10)
			reply(word(big.NewInt(1)) + word(big.NewInt(0)) + word(big.NewInt(seriesExpiry)) + word(big.NewInt(series.lastTrade)) +
				word(big.NewInt(testFutureLastMark)) + word(series.mark) + word(big.NewInt(0)))
		case series != nil && sel == "0x3d7cc610": // contractSize()
			reply(word(series.size))
		case series != nil && sel == "0x779e5012": // subAccounts()
			reply(addr(testFutureLedger))
		case series != nil && sel == "0x745ab570": // totalPositionCap(address)
			reply(word(series.positionCap))
		case series != nil && sel == "0x22b97c45": // getPendingVM(uint256,uint256)
			account, _ := new(big.Int).SetString(call.Data[10:74], 16)
			expiryAt(74)
			reply(int256Word(series.pendingVM[account.String()]))
		case to == testFutureLedger && sel == "0x52981457": // manager(uint256)
			account, _ := new(big.Int).SetString(call.Data[10:], 16)
			manager, ok := c.managers[account.String()]
			if !ok {
				manager = seriesV1Engine
			}
			reply(addr(manager))
		case to == testFutureLedger && sel == "0x0806e640": // getBalance(uint256,address,uint256)
			account, _ := new(big.Int).SetString(call.Data[10:74], 16)
			asset := "0x" + call.Data[98:138]
			expiryAt(138)
			held := c.series[asset]
			if held == nil {
				t.Errorf("getBalance of unlisted asset %s", asset)
				reply(word(big.NewInt(0)))
				return
			}
			reply(int256Word(held.positions[account.String()]))
		case to == testFutureTM && sel == "0x761822ef": // isDatedFutureAsset(address)
			reply(word(big.NewInt(1)))
		case (to == seriesV1Engine || to == seriesV2Engine) && sel == "0xac06ba05": // adjustmentsPaused()
			reply(word(big.NewInt(0)))
		case (to == seriesV1Engine || to == seriesV2Engine) && sel == "0x623bb445": // getMargin(uint256,bool)
			reply(word(c.surplus[to]))
		default:
			t.Errorf("unexpected eth_call %s to %s", sel, to)
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "error": map[string]any{"message": "unexpected"}})
		}
	}))
}

// seriesConfig lists v1's series the way every deployment does today (CNGN_FUTURE_*), and v2's two
// through FUTURE_SERIES. v2's cNGN-30NOV26 is the deployed one's shape: 1,000,000 cNGN a contract.
func seriesConfig(rpc string) config.Config {
	cfg := futureConfig(rpc)
	cfg.CNGNFutureAssetAddress, cfg.CNGNFutureExpiry, cfg.CNGNFutureManagerAddress = seriesV1, seriesExpiry, seriesV1Engine
	cfg.FutureSeries = []config.FutureSeries{
		{AssetAddress: seriesV2CNGN, Expiry: seriesExpiry, ManagerAddress: seriesV2Engine, Kind: config.FutureKindLinear, BaseAsset: "cNGN", ContractSize: "1000000"},
		{AssetAddress: seriesV2EURC, Expiry: seriesExpiry, ManagerAddress: seriesV2Engine, Kind: config.FutureKindLinear, BaseAsset: "EURC", ContractSize: "1000"},
	}
	return cfg
}

func seriesServer(t *testing.T, cfg config.Config) *Server {
	t.Helper()
	registry := instruments.DefaultRegistry(cfg)
	return &Server{cfg: cfg, instruments: registry, futureSeries: newFutureSeriesReaders(cfg, registry)}
}

func seriesInstrument(t *testing.T, s *Server, asset string) instruments.Metadata {
	t.Helper()
	instrument, ok := s.instruments.ByAssetAndSubID(asset, fmt.Sprint(seriesExpiry))
	if !ok {
		t.Fatalf("series %s is not listed", asset)
	}
	return instrument
}

func ratOf(t *testing.T, v any) *big.Rat {
	t.Helper()
	text, _ := v.(string)
	r, ok := new(big.Rat).SetString(text)
	if !ok {
		t.Fatalf("%v is not a number", v)
	}
	return r
}

// band18 is the chain's band around index (18dp): index -/+ floor(index / 10), as a decimal.
func band18(index *big.Int) (*big.Rat, *big.Rat) {
	diff := new(big.Int).Div(index, big.NewInt(10))
	return new(big.Rat).SetFrac(new(big.Int).Sub(index, diff), testWad), new(big.Rat).SetFrac(new(big.Int).Add(index, diff), testWad)
}

func TestMarketsListsEachSeriesWithItsOwnBandMarkAndState(t *testing.T) {
	chain := newSeriesChain()
	chain.series[seriesV2CNGN].positionCap = big.NewInt(0) // v2 closed until enable
	cfg := seriesConfig("")
	cfg.CNGNFutureCloseOnly = true // step 4: v1 close-only
	srv := chain.server(t)
	defer srv.Close()
	cfg.ChainRPCURL = srv.URL

	rec := httptest.NewRecorder()
	seriesServer(t, cfg).handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var entries []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("markets: %v %s", err, rec.Body.String())
	}
	byAsset := map[string]map[string]any{}
	for _, entry := range entries {
		if entry["contract_type"] == "future" {
			byAsset[entry["asset_address"].(string)] = entry
		}
	}
	if len(byAsset) != 3 {
		t.Fatalf("want three series: %s", rec.Body.String())
	}

	v1Index := new(big.Int).Div(new(big.Int).Mul(testWad, testWad), chain.spot[seriesCNGNFeed])
	for asset, want := range map[string]struct {
		symbol, base, quote, label, multiplier, scale, mark string
		index                                               *big.Int
		open, closeOnly                                     bool
		contractUSDC, contractSize, contractAsset           string
		manager                                             string
	}{
		seriesV1: {"USDC-cNGN-30NOV26", "USDC", "cNGN", "cNGN per USDC", "1000", "1000000000000000", "1400", v1Index,
			true, true, "1000", "", "", seriesV1Engine},
		seriesV2CNGN: {"cNGN-30NOV26", "cNGN", "USDC", "USDC per cNGN", "1000000", "1000000000000", "0.000714285714285714", chain.spot[seriesCNGNFeed],
			false, false, "", "1000000", "cNGN", seriesV2Engine},
		seriesV2EURC: {"EURC-30NOV26", "EURC", "USDC", "USDC per EURC", "1000", "1000000000000000", "1.16", chain.spot[seriesEURCFeed],
			true, false, "", "1000", "EURC", seriesV2Engine},
	} {
		entry := byAsset[asset]
		future := entry["future"].(map[string]any)
		if entry["market"] != want.symbol || entry["base_asset_symbol"] != want.base || entry["quote_asset_symbol"] != want.quote ||
			entry["display_label"] != want.label || entry["contract_multiplier"] != want.multiplier || entry["amount_scale"] != want.scale ||
			entry["margin_manager_address"] != want.manager || entry["sub_id"] != fmt.Sprint(seriesExpiry) {
			t.Errorf("%s: entry %v", want.symbol, entry)
		}
		low, high := band18(want.index)
		if ratOf(t, entry["fill_band_low"]).Cmp(low) != 0 || ratOf(t, entry["fill_band_high"]).Cmp(high) != 0 {
			t.Errorf("%s: band %v-%v, want %s-%s", want.symbol, entry["fill_band_low"], entry["fill_band_high"], low.FloatString(18), high.FloatString(18))
		}
		if ratOf(t, future["index_price"]).Cmp(new(big.Rat).SetFrac(want.index, testWad)) != 0 || future["mark_price"] != want.mark {
			t.Errorf("%s: index %v mark %v", want.symbol, future["index_price"], future["mark_price"])
		}
		if future["trading_open"] != want.open {
			t.Errorf("%s: trading_open %v (%v)", want.symbol, future["trading_open"], future["trading_closed_reason"])
		}
		if closeOnly, _ := future["close_only"].(bool); closeOnly != want.closeOnly {
			t.Errorf("%s: close_only %v", want.symbol, future["close_only"])
		}
		if (future["contract_size_usdc"] != nil || want.contractUSDC != "") && future["contract_size_usdc"] != want.contractUSDC {
			t.Errorf("%s: contract_size_usdc %v", want.symbol, future["contract_size_usdc"])
		}
		if (future["contract_size"] != nil || want.contractSize != "") && (future["contract_size"] != want.contractSize || future["contract_size_asset"] != want.contractAsset) {
			t.Errorf("%s: contract_size %v %v", want.symbol, future["contract_size"], future["contract_size_asset"])
		}
	}
	if reason := byAsset[seriesV2CNGN]["future"].(map[string]any)["trading_closed_reason"]; !strings.Contains(fmt.Sprint(reason), "no position cap") {
		t.Errorf("v2's cNGN is closed for its own cap: %v", reason)
	}
}

// seriesOrder is a buy of one unit on the series at price (18dp), from account.
func seriesOrder(asset, account string, price *big.Int) orders.CreateOrderParams {
	action, _ := json.Marshal(map[string]any{
		"subaccount_id": account, "nonce": "1", "module": testFutureTM,
		"data":   mustTradeDataHex(asset, fmt.Sprint(seriesExpiry), price.String(), "1000000000000000", true),
		"expiry": "100", "owner": "0xabc", "signer": "0xabc",
	})
	return orders.CreateOrderParams{OrderID: "o-" + account, SubaccountID: account, AssetAddress: asset, SubID: fmt.Sprint(seriesExpiry), ActionJSON: action}
}

// Each order is admitted against its own series: its band, its last trade time, its engine. A v1 price
// (cNGN per USDC) is far outside v2's band (USDC per cNGN), and the reverse.
func TestAFuturesOrderIsAdmittedAgainstItsOwnSeries(t *testing.T) {
	chain := newSeriesChain()
	chain.managers["20"] = seriesV2Engine
	chain.series[seriesV2EURC].lastTrade = time.Now().Add(-time.Minute).Unix()
	srv := chain.server(t)
	defer srv.Close()
	s := seriesServer(t, seriesConfig(srv.URL))

	v1Price := new(big.Int).Mul(big.NewInt(1400), testWad)
	v2Price := chain.spot[seriesCNGNFeed]
	for name, tc := range map[string]struct {
		asset, account string
		price          *big.Int
		status         int
		says           string
	}{
		"v1 at its index, a v1 account":       {seriesV1, "10", v1Price, 0, ""},
		"v2 cNGN at its index, a v2 account":  {seriesV2CNGN, "20", v2Price, 0, ""},
		"a v1 price on v2 cNGN":               {seriesV2CNGN, "20", v1Price, http.StatusUnprocessableEntity, "USDC per cNGN is outside the band"},
		"a v2 price on v1":                    {seriesV1, "10", v2Price, http.StatusUnprocessableEntity, "cNGN per USDC is outside the band"},
		"a v1 account on v2 cNGN":             {seriesV2CNGN, "10", v2Price, http.StatusUnprocessableEntity, "not the MarginEngine " + seriesV2Engine},
		"a v2 account on v1":                  {seriesV1, "20", v1Price, http.StatusUnprocessableEntity, "not the MarginEngine " + seriesV1Engine},
		"EURC past its own last trade time":   {seriesV2EURC, "20", chain.spot[seriesEURCFeed], http.StatusConflict, "EURC-30NOV26 is past its last trade time"},
		"v2 cNGN open while EURC has stopped": {seriesV2CNGN, "20", v2Price, 0, ""},
	} {
		instrument := seriesInstrument(t, s, tc.asset)
		status, msg := s.admitFuture(context.Background(), instrument, seriesOrder(tc.asset, tc.account, tc.price))
		if status != tc.status || !strings.Contains(msg, tc.says) {
			t.Errorf("%s: %d %q", name, status, msg)
		}
	}
}

// Reduce-only reads the account's position in the order's own series, and close-only is per series:
// v1 close-only takes v1's orders as reduce-only and leaves v2's alone.
func TestReduceOnlyAndCloseOnlyArePerSeries(t *testing.T) {
	chain := newSeriesChain()
	chain.series[seriesV1].positions = map[string]*big.Int{"42": contractsWad(3, 0)}
	chain.series[seriesV2CNGN].positions = map[string]*big.Int{"42": new(big.Int).Neg(contractsWad(2, 0))}
	srv := chain.server(t)
	defer srv.Close()
	cfg := seriesConfig(srv.URL)
	cfg.CNGNFutureCloseOnly = true
	s := seriesServer(t, cfg)

	for asset, want := range map[string]*big.Int{seriesV1: contractsWad(3, 0), seriesV2CNGN: new(big.Int).Neg(contractsWad(2, 0)), seriesV2EURC: big.NewInt(0)} {
		got, err := s.reduceOnlyChainPosition(context.Background(), seriesInstrument(t, s, asset), "42")
		if err != nil || got.Cmp(want) != 0 {
			t.Errorf("%s: position %v %v, want %s", asset, got, err, want)
		}
	}
	for asset, want := range map[string]bool{seriesV1: true, seriesV2CNGN: false, seriesV2EURC: false} {
		if got := s.closeOnlyOrder(seriesOrder(asset, "42", big.NewInt(1))).ReduceOnly; got != want {
			t.Errorf("%s: reduce-only %v, want %v", asset, got, want)
		}
	}
}

// An account under v2 holding both v2 series is shown each at its own mark, with v2's VM in USDC and
// its notional at the mark, and its margin under v2, the engine it is under; a v1 account's is v1's.
func TestPositionsReadsEachSeriesAndTheEngineTheAccountIsUnder(t *testing.T) {
	chain := newSeriesChain()
	chain.managers["20"] = seriesV2Engine
	chain.series[seriesV1].positions = map[string]*big.Int{"10": contractsWad(1, 0)}
	chain.series[seriesV1].pendingVM = map[string]*big.Int{"10": new(big.Int).Mul(big.NewInt(-50), testWad)}
	chain.series[seriesV2CNGN].positions = map[string]*big.Int{"20": contractsWad(2, 0)}
	chain.series[seriesV2CNGN].pendingVM = map[string]*big.Int{"20": new(big.Int).Mul(big.NewInt(3), testWad)}
	chain.series[seriesV2EURC].positions = map[string]*big.Int{"20": new(big.Int).Neg(contractsWad(1, 5))}
	srv := chain.server(t)
	defer srv.Close()
	s := seriesServer(t, seriesConfig(srv.URL))

	body, raw := getPositions(t, s, "20")
	if len(body.Futures) != 2 {
		t.Fatalf("the v2 account holds two series: %s", raw)
	}
	byMarket := map[string]presentedFuturePosition{}
	for _, position := range body.Futures {
		byMarket[position.Market] = position
	}
	// 2 contracts x 1,000,000 cNGN x 0.000714285714285714 USDC
	if got := byMarket["cNGN-30NOV26"]; got.Contracts != "2" || got.Side != "long" || got.MarkPrice != "0.000714285714285714" ||
		got.NotionalUSDC != "1428.571428571428" || got.PendingVMUSDC != "3" || got.PendingVMCNGN != "" {
		t.Errorf("cNGN-30NOV26: %s", show(got))
	}
	// 1.5 contracts x 1,000 EURC x 1.16 USDC
	if got := byMarket["EURC-30NOV26"]; got.Contracts != "-1.5" || got.Side != "short" || got.MarkPrice != "1.16" ||
		got.NotionalUSDC != "1740" || got.PendingVMUSDC != "0" {
		t.Errorf("EURC-30NOV26: %s", show(got))
	}
	want := presentedFuturesAccount{SubaccountID: "20", Manager: seriesV2Engine, IMSurplusUSD: "700", MMSurplusUSD: "700"}
	if body.FuturesAccount == nil || *body.FuturesAccount != want {
		t.Errorf("futures_account %+v, want %+v", body.FuturesAccount, want)
	}

	body, raw = getPositions(t, s, "10")
	if len(body.Futures) != 1 {
		t.Fatalf("the v1 account holds v1's series: %s", raw)
	}
	if got := body.Futures[0]; got.Market != "USDC-cNGN-30NOV26" || got.NotionalUSDC != "1000" || got.PendingVMCNGN != "-50" || got.PendingVMUSDC != "" {
		t.Errorf("USDC-cNGN-30NOV26: %s", show(got))
	}
	want = presentedFuturesAccount{SubaccountID: "10", Manager: seriesV1Engine, IMSurplusUSD: "500", MMSurplusUSD: "500"}
	if body.FuturesAccount == nil || *body.FuturesAccount != want {
		t.Errorf("futures_account %+v, want %+v", body.FuturesAccount, want)
	}

	chain.managers["30"] = "0x00000000000000000000000000000000000000aa"
	if _, raw := getPositions(t, s, "30"); strings.Contains(raw, "futures_account") {
		t.Errorf("an account under neither engine has no futures_account: %s", raw)
	}
}

// A v2 fill's VM is USDC: the gap to the mark times its cNGN notional, under vm_usdc, not vm_cngn.
func TestALinearFillsVMIsUSDC(t *testing.T) {
	chain := newSeriesChain()
	srv := chain.server(t)
	defer srv.Close()
	s := seriesServer(t, seriesConfig(srv.URL))
	mark := "0.0008"
	fills := s.presentFills([]orders.OwnerFill{{TradeFill: orders.TradeFill{AssetAddress: seriesV2CNGN, SubID: fmt.Sprint(seriesExpiry),
		Price: "0.0007", Size: "1000"}, OrderSide: orders.SideBuy, MarkPrice: &mark}})
	// 1,000 units x 1e12 / 1e18 x 1,000,000 cNGN = 1,000 cNGN; x 0.0001 USDC per cNGN = 0.1 USDC
	if fills[0].VMUSDC != "0.1" || fills[0].VMCNGN != "" || fills[0].Market != "cNGN-30NOV26" {
		t.Fatalf("fill: %s", show(fills[0]))
	}
}

// The wiring: POST /v1/orders, against the test database, with v1's and v2's series listed at one
// expiry. A v2 cNGN order in v2's band (USDC per cNGN) is stored; one at a v1 price is refused before it
// is stored; and with v1 close-only, an order on v1 from an account holding none of it is refused as a
// reduce-only order with nothing to reduce, while v2 is untouched.
func TestCreateOrderAdmitsEachSeriesOnItsOwnTerms(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	chain := newSeriesChain()
	chain.managers["21"] = seriesV2Engine
	rpc := chain.server(t)
	defer rpc.Close()
	cfg := seriesConfig(rpc.URL)
	cfg.CNGNFutureCloseOnly = true
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	server.custody = fakeCustodyChecker{allow: map[string]bool{"11": true, "21": true}}
	suffix := fmt.Sprintf("future-series-intake-%d", time.Now().UnixNano())
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%") })

	submit := func(id, asset, account, price, priceWei, amount, amountWei string) *httptest.ResponseRecorder {
		action := map[string]any{"subaccount_id": account, "nonce": id, "module": testFutureTM,
			"data":   mustTradeDataHex(asset, fmt.Sprint(seriesExpiry), priceWei, amountWei, true),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()), "owner": "0xabc", "signer": "0xabc"}
		body, _ := json.Marshal(map[string]any{
			"order_id": suffix + "-" + id, "owner_address": "0xabc", "signer_address": "0xabc", "subaccount_id": account, "recipient_id": account,
			"nonce": id, "side": "buy", "asset_address": asset, "sub_id": fmt.Sprint(seriesExpiry), "desired_amount": amount,
			"filled_amount": "0", "limit_price": price, "worst_fee": "2500000000000000000", "expiry": time.Now().Add(time.Hour).Unix(),
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

	// one v2 contract, 1,000,000 cNGN, at 0.0007 USDC per cNGN
	if rec := submit("1", seriesV2CNGN, "21", "0.0007", "700000000000000", "1000000", "1000000000000000000"); rec.Code >= 300 || !stored("1") {
		t.Fatalf("v2 in its band: %d %s, stored %v", rec.Code, rec.Body.String(), stored("1"))
	}
	if rec := submit("2", seriesV2CNGN, "21", "1400", "1400000000000000000000", "1000000", "1000000000000000000"); rec.Code != http.StatusUnprocessableEntity ||
		!strings.Contains(rec.Body.String(), "fill_band") || stored("2") {
		t.Fatalf("a v1 price on v2: %d %s, stored %v", rec.Code, rec.Body.String(), stored("2"))
	}
	// one v1 contract, 1,000 USDC, at 1,400 cNGN per USDC: in v1's band, but v1 is close-only
	if rec := submit("3", seriesV1, "11", "1400", "1400000000000000000000", "1000", "1000000000000000000"); rec.Code != http.StatusUnprocessableEntity ||
		!strings.Contains(rec.Body.String(), "no position to reduce") || stored("3") {
		t.Fatalf("v1 close-only: %d %s, stored %v", rec.Code, rec.Body.String(), stored("3"))
	}
}
