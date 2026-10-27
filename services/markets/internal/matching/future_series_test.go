package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// Three series at one expiry, as 30NOV26 will be listed (exchange #228): v1's inverse USDC-cNGN on
// the v1 engine, v2's linear cNGN and EURC on the v2 engine. The EURC FutureAsset is a placeholder.
const (
	msExpiry   = int64(1796047200)
	msV1       = "0x00000000000000000000000000000000000000f1"
	msV2CNGN   = "0x00000000000000000000000000000000000000f2"
	msV2EURC   = "0x00000000000000000000000000000000000000f3"
	msCNGNFeed = "0x00000000000000000000000000000000000000fc"
	msEURCFeed = "0x00000000000000000000000000000000000000fd"
	msTM       = "0x00000000000000000000000000000000000000a1"
	msV1Engine = "0x00000000000000000000000000000000000000e1"
	msV2Engine = "0x00000000000000000000000000000000000000e2"
)

type msSeries struct {
	feed        string
	size, mark  *big.Int
	positionCap *big.Int
	positions   map[string]*big.Int
}

// msChain stubs each FutureAsset by address. A read of a series at another expiry, or of an asset it
// does not list, fails the test.
type msChain struct {
	series  map[string]*msSeries
	spot    map[string]*big.Int
	surplus map[string]*big.Int // engine -> getMargin(account, true), USD
}

func newMSChain() *msChain {
	cngnSpot := new(big.Int).Div(wad, big.NewInt(1400))
	eurcSpot := new(big.Int).Div(new(big.Int).Mul(big.NewInt(116), wad), big.NewInt(100))
	cap30 := new(big.Int).Mul(big.NewInt(30), wad)
	return &msChain{
		spot: map[string]*big.Int{msCNGNFeed: cngnSpot, msEURCFeed: eurcSpot},
		series: map[string]*msSeries{
			msV1:     {feed: msCNGNFeed, size: new(big.Int).Mul(big.NewInt(1000), wad), mark: new(big.Int).Mul(big.NewInt(1400), wad), positionCap: cap30},
			msV2CNGN: {feed: msCNGNFeed, size: new(big.Int).Mul(big.NewInt(1_000_000), wad), mark: new(big.Int).Set(cngnSpot), positionCap: cap30},
			msV2EURC: {feed: msEURCFeed, size: new(big.Int).Mul(big.NewInt(1000), wad), mark: new(big.Int).Set(eurcSpot), positionCap: cap30},
		},
		surplus: map[string]*big.Int{msV1Engine: new(big.Int).Mul(big.NewInt(200), wad), msV2Engine: new(big.Int).Mul(big.NewInt(200), wad)},
	}
}

func (c *msChain) serve(t *testing.T) *httptest.Server {
	word := func(v *big.Int) string {
		return fmt.Sprintf("%064x", new(big.Int).And(v, new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))))
	}
	addr := func(a string) string { return strings.Repeat("0", 24) + strings.TrimPrefix(a, "0x") }
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		switch req.Method {
		case "eth_getTransactionReceipt":
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
				"result": map[string]string{"blockNumber": "0x31f6e9d", "transactionIndex": "0x3"}})
			return
		case "eth_getLogs":
			var filter struct{ Address string }
			_ = json.Unmarshal(req.Params[0], &filter)
			if c.series[strings.ToLower(filter.Address)] == nil {
				t.Errorf("MarkSet logs read on %s", filter.Address)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": []any{}})
			return
		}
		var call struct{ To, Data string }
		_ = json.Unmarshal(req.Params[0], &call)
		to, sel := strings.ToLower(call.To), call.Data[:10]
		expiryAt := func(start int) {
			if expiry, _ := new(big.Int).SetString(call.Data[start:start+64], 16); expiry.Int64() != msExpiry {
				t.Errorf("%s read at expiry %s", sel, expiry)
			}
		}
		series := c.series[to]
		var result string
		switch {
		case series != nil && sel == "0x198cae76": // indexFeed()
			result = addr(series.feed)
		case c.spot[to] != nil && sel == "0x2b37269c": // getSpot()
			result = word(c.spot[to]) + word(wad)
		case series != nil && sel == "0x968564c5": // markIndexBand(uint64)
			result = word(new(big.Int).Div(wad, big.NewInt(10)))
		case series != nil && sel == "0x3d7cc610": // contractSize()
			result = word(series.size)
		case series != nil && sel == "0xc3c74b34": // futureContracts(uint256)
			expiryAt(10)
			result = word(big.NewInt(1)) + word(big.NewInt(0)) + word(big.NewInt(msExpiry)) +
				word(big.NewInt(time.Now().Add(24*time.Hour).Unix())) + word(big.NewInt(0)) + word(series.mark) + word(big.NewInt(0))
		case series != nil && sel == "0x745ab570": // totalPositionCap(address)
			result = word(series.positionCap)
		case series != nil && sel == "0x779e5012": // subAccounts()
			result = addr(futureLedger)
		case to == msTM && sel == "0x761822ef": // isDatedFutureAsset(address)
			result = word(big.NewInt(1))
		case (to == msV1Engine || to == msV2Engine) && sel == "0xac06ba05": // adjustmentsPaused()
			result = word(big.NewInt(0))
		case (to == msV1Engine || to == msV2Engine) && sel == "0xd21415a3": // assetDetails(address): whitelisted, Future, market 1
			result = word(big.NewInt(1)) + word(big.NewInt(4)) + word(big.NewInt(1))
		case (to == msV1Engine || to == msV2Engine) && sel == "0x84033e5e": // futureMarginRequirements(uint256): 15% MM, 25% IM
			result = word(new(big.Int).Div(new(big.Int).Mul(big.NewInt(15), wad), big.NewInt(100))) + word(new(big.Int).Div(wad, big.NewInt(4)))
		case (to == msV1Engine || to == msV2Engine) && sel == "0x623bb445": // getMargin(uint256,bool)
			result = word(c.surplus[to])
		case to == futureLedger && sel == "0x0806e640": // getBalance(uint256,address,uint256)
			account, _ := new(big.Int).SetString(call.Data[10:74], 16)
			held := c.series["0x"+call.Data[98:138]]
			expiryAt(138)
			if held == nil {
				t.Errorf("getBalance of unlisted asset 0x%s", call.Data[98:138])
				result = word(big.NewInt(0))
				break
			}
			position, ok := held.positions[account.String()]
			if !ok {
				position = big.NewInt(0)
			}
			result = word(position)
		default:
			t.Errorf("unexpected eth_call %s to %s", sel, to)
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "error": map[string]any{"message": "unexpected"}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": "0x" + result})
	}))
}

func msConfig(rpc string) config.Config {
	return config.Config{
		ChainRPCURL:                rpc,
		CNGNPerpTradeModuleAddress: msTM,
		CNGNFutureAssetAddress:     msV1, CNGNFutureExpiry: msExpiry, CNGNFutureManagerAddress: msV1Engine,
		FutureSeries: []config.FutureSeries{
			{AssetAddress: msV2CNGN, Expiry: msExpiry, ManagerAddress: msV2Engine, Kind: config.FutureKindLinear, BaseAsset: "cNGN", ContractSize: "1000000"},
			{AssetAddress: msV2EURC, Expiry: msExpiry, ManagerAddress: msV2Engine, Kind: config.FutureKindLinear, BaseAsset: "EURC", ContractSize: "1000"},
		},
	}
}

func msInstrument(t *testing.T, cfg config.Config, asset string) instruments.Metadata {
	t.Helper()
	instrument, ok := instruments.DefaultRegistry(cfg).ByAssetAndSubID(asset, fmt.Sprint(msExpiry))
	if !ok || !instrument.IsFuture() {
		t.Fatalf("series %s is not listed", asset)
	}
	return instrument
}

func msCandidate(takerAccount string) orders.MatchCandidate {
	return orders.MatchCandidate{
		Taker: orders.Order{OrderID: "taker-" + takerAccount, SubaccountID: takerAccount, Side: orders.SideBuy},
		Maker: orders.Order{OrderID: "maker-" + takerAccount, SubaccountID: "999", Side: orders.SideSell},
	}
}

// Every matcher read of a series goes through its own reader: the contract size it starts against, the
// gate, the band, the fee notional, the mark a fill settled at and the reduce-only position.
func TestTheMatcherReadsEachSeriesThroughItsOwnReader(t *testing.T) {
	chain := newMSChain()
	chain.series[msV2CNGN].positionCap = big.NewInt(0) // v2's cNGN not yet enabled
	chain.series[msV1].positions = map[string]*big.Int{"42": new(big.Int).Mul(big.NewInt(3), wad)}
	chain.series[msV2EURC].positions = map[string]*big.Int{"42": new(big.Int).Neg(wad)}
	rpc := chain.serve(t)
	defer rpc.Close()
	cfg := msConfig(rpc.URL)
	e := &Engine{futures: newFutureReaders(cfg), backoff: newMatchBackoff(), marginRefusals: newFutureMarginRefusals()}
	ctx := context.Background()

	v1Price := new(big.Int).Mul(big.NewInt(1400), wad)
	cngnPrice := chain.spot[msCNGNFeed]
	eurcPrice := chain.spot[msEURCFeed]
	for _, tc := range []struct {
		asset, symbol string
		open          bool
		price, wrong  *big.Int
		// fee is one contract's taker fee at price, 25 bps of its USDC notional
		fee, mark string
		position  *big.Int
	}{
		{msV1, "USDC-cNGN-30NOV26", true, v1Price, cngnPrice, "2500000000000000000", "1400", new(big.Int).Mul(big.NewInt(3), wad)},
		// 1,000,000 cNGN x 0.000714285714285714 = 714.285714285714 USDC; 25 bps
		{msV2CNGN, "cNGN-30NOV26", false, cngnPrice, v1Price, "1785714285714285000", "0.000714285714285714", big.NewInt(0)},
		// 1,000 EURC x 1.16 = 1,160 USDC; 25 bps
		{msV2EURC, "EURC-30NOV26", true, eurcPrice, v1Price, "2900000000000000000", "1.16", new(big.Int).Neg(wad)},
	} {
		instrument := msInstrument(t, cfg, tc.asset)
		if instrument.Symbol != tc.symbol {
			t.Errorf("%s: symbol %s", tc.asset, instrument.Symbol)
		}
		if err := verifyFutureContractSize(ctx, e.futureReader(instrument), instrument); err != nil {
			t.Errorf("%s: contract size: %v", tc.symbol, err)
		}
		if got := e.futureOpen(ctx, instrument); got != tc.open {
			t.Errorf("%s: open %v", tc.symbol, got)
		}
		if !e.futureFillInBand(ctx, instrument, msCandidate("1"), tc.price.String()) {
			t.Errorf("%s: a fill at its own index is refused", tc.symbol)
		}
		if e.futureFillInBand(ctx, instrument, msCandidate("2"), tc.wrong.String()) {
			t.Errorf("%s: a fill at another series' price passes its band", tc.symbol)
		}
		notional, err := e.feeNotionalPrice(ctx, instrument, tc.price.String())
		if err != nil {
			t.Fatalf("%s: %v", tc.symbol, err)
		}
		if fee, _ := takerFillFee(instrument.TakerFeeBps, notional, wad.String()); fee != tc.fee {
			t.Errorf("%s: one contract's fee %s, want %s", tc.symbol, fee, tc.fee)
		}
		if mark := e.futureMarkAt(ctx, instrument, "0xabc"); mark != tc.mark {
			t.Errorf("%s: fill mark %s, want %s", tc.symbol, mark, tc.mark)
		}
		position, err := e.chainPosition(ctx, instrument, nil, "42")
		if err != nil || position.Cmp(tc.position) != 0 {
			t.Errorf("%s: position %v %v, want %s", tc.symbol, position, err, tc.position)
		}
	}
}

// The margin pre-check prices each series on its own terms. With 200 USD of surplus under each engine,
// one v1 contract (1,000 USDC at 25%: 250) is refused, one v2 cNGN contract (714 USDC at the mark:
// 178.6, plus a 1.79 fee) carries, and two EURC contracts (2,320 USDC: 580) are refused.
func TestTheMarginPrecheckPricesEachSeriesOnItsOwnTerms(t *testing.T) {
	chain := newMSChain()
	rpc := chain.serve(t)
	defer rpc.Close()
	cfg := msConfig(rpc.URL)
	e := &Engine{futures: newFutureReaders(cfg), backoff: newMatchBackoff(), marginRefusals: newFutureMarginRefusals()}
	ctx := context.Background()

	for _, tc := range []struct {
		asset           string
		price, amount   *big.Int
		fee             string
		allowed         bool
		takerAccountTag string
	}{
		{msV1, new(big.Int).Mul(big.NewInt(1400), wad), wad, "2500000000000000000", false, "11"},
		{msV2CNGN, chain.spot[msCNGNFeed], wad, "1785714285714285000", true, "12"},
		{msV2EURC, chain.spot[msEURCFeed], new(big.Int).Mul(big.NewInt(2), wad), "5800000000000000000", false, "13"},
	} {
		instrument := msInstrument(t, cfg, tc.asset)
		candidate := msCandidate(tc.takerAccountTag)
		// the maker, 999, is under-margined too on a refused series; only the taker is checked here
		if got := e.futureMarginAllows(ctx, instrument, candidate, tc.price.String(), tc.amount.String(), tc.fee); got != tc.allowed {
			t.Errorf("%s: allowed %v, want %v", instrument.Symbol, got, tc.allowed)
		}
	}
}

// v1 close-only holds every v1 leg to its position, resting orders without the flag included, and
// leaves v2's series open.
func TestCloseOnlyIsPerSeries(t *testing.T) {
	cfg := msConfig("http://rpc")
	cfg.CNGNFutureCloseOnly = true
	e := &Engine{}
	leg := orders.Order{OrderID: "o", SubaccountID: "1"}
	for asset, want := range map[string]bool{msV1: true, msV2CNGN: false, msV2EURC: false} {
		if got := e.reduceOnlyLeg(msInstrument(t, cfg, asset), leg); got != want {
			t.Errorf("%s: reduce-only leg %v, want %v", asset, got, want)
		}
	}
}

// A linear fill's margin: IM on its notional at the mark, the fee, and a VM gain in USDC at par.
func TestLinearFutureFillShortfall(t *testing.T) {
	size := new(big.Int).Mul(big.NewInt(1_000_000), wad)
	rate := new(big.Int).Div(wad, big.NewInt(4))
	mark := new(big.Int).Div(new(big.Int).Mul(big.NewInt(7), wad), big.NewInt(10_000)) // 0.0007
	surplus := new(big.Int).Mul(big.NewInt(176), wad)
	side := futureSide{Surplus: surplus, Position: big.NewInt(0), Delta: new(big.Int).Set(wad), Fee: big.NewInt(0)}
	// one contract is 700 USDC at the mark: 175 of IM
	if short, post := futureFillShortfall(side, true, size, rate, mark, mark, big.NewInt(0)); short || post.Cmp(wad) != 0 {
		t.Fatalf("176 - 175 = 1 USD: short %v post %v", short, post)
	}
	side.Surplus = new(big.Int).Mul(big.NewInt(174), wad)
	if short, _ := futureFillShortfall(side, true, size, rate, mark, mark, big.NewInt(0)); !short {
		t.Fatal("174 of surplus cannot carry 175 of IM")
	}
	// bought 0.00001 under the mark: 1,000,000 x 0.00001 = 10 USDC of VM, at par
	below := new(big.Int).Sub(mark, new(big.Int).Div(wad, big.NewInt(100_000)))
	if short, post := futureFillShortfall(side, true, size, rate, below, mark, big.NewInt(0)); short || post.Cmp(new(big.Int).Mul(big.NewInt(9), wad)) != 0 {
		t.Fatalf("174 - 175 + 10 = 9 USD: short %v post %v", short, post)
	}
}

// The wiring: a real engine tick against the test database, v1's and v2's series listed side by side
// at one expiry, a crossed pair on v2's cNGN. It is checked against v2's band (USDC per cNGN), charged
// on v2's notional (1,000,000 cNGN at the fill price) and recorded with v2's mark; v1's book, at the
// same expiry, is not touched.
func TestEngineTickFillsAV2SeriesBesideV1(t *testing.T) {
	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()

	var submitted atomic.Int64
	var request ExecutorRequest
	executor := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		submitted.Add(1)
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &request)
		_, _ = w.Write([]byte(`{"accepted":true,"tx_hash":"0x` + strings.Repeat("ef", 32) + `","receipt_status":"success","block_number":"52391071"}`))
	}))
	defer executor.Close()

	// Assets of their own per run, so nothing left on another book can cross with this pair.
	chain := newMSChain()
	v1, v2 := fmt.Sprintf("0x%040x", time.Now().UnixNano()), fmt.Sprintf("0x%040x", time.Now().UnixNano()+1)
	chain.series[v1], chain.series[v2] = chain.series[msV1], chain.series[msV2CNGN]
	rpc := chain.serve(t)
	defer rpc.Close()
	cfg := msConfig(rpc.URL)
	cfg.ExecutorURL, cfg.ExecutorTimeout = executor.URL, 5*time.Second
	cfg.CNGNFutureAssetAddress = v1
	cfg.FutureSeries = cfg.FutureSeries[:1]
	cfg.FutureSeries[0].AssetAddress = v2
	instrument := msInstrument(t, cfg, v2)
	subID := fmt.Sprint(msExpiry)

	suffix := fmt.Sprintf("future-v2-%d", time.Now().UnixNano())
	bid, ask := suffix+"-bid", suffix+"-ask"
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id in ($1,$2) or maker_order_id in ($1,$2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bid, ask)
	})
	seed := func(id string, side orders.Side, price *big.Int, ticks, subaccount, owner string, isBid bool, age string) {
		nonce := fmt.Sprint(time.Now().UnixNano())
		action, _ := json.Marshal(map[string]any{
			"subaccount_id": subaccount, "nonce": nonce, "module": msTM,
			// one contract: 1,000,000 cNGN, 1,000,000 units of 1e12
			"data":   tradeDataHex(v2, subID, price.String(), "1000000000000000000", isBid),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()), "owner": owner, "signer": owner,
		})
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, $2, $3, $3, $4, $5, $6, $7, '1000000', '0', $8, $8, '2500000000000000000', $9, $10, '0x01', 'active', now() - $11::interval)`,
			id, strings.ToLower(owner), subaccount, nonce, side, v2, subID, ticks,
			time.Now().Add(time.Hour).Unix(), action, age); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	// 0.0007 and 0.00071 USDC per cNGN, inside v2's band 0.000643-0.000786. The ask is older: the
	// fill is at 0.0007.
	askPrice := new(big.Int).Div(new(big.Int).Mul(big.NewInt(7), wad), big.NewInt(10_000))
	bidPrice := new(big.Int).Div(new(big.Int).Mul(big.NewInt(71), wad), big.NewInt(100_000))
	seed(ask, orders.SideSell, askPrice, askPrice.String(), "742", "0x2222222222222222222222222222222222222222", false, "2 seconds")
	seed(bid, orders.SideBuy, bidPrice, bidPrice.String(), "741", "0x1111111111111111111111111111111111111111", true, "1 second")

	e := NewEngine(cfg, pool)
	if !e.futureOpen(ctx, instrument) {
		t.Fatal("v2's cNGN is open on the stub")
	}
	e.tickInstrument(ctx, instrument)
	if submitted.Load() != 1 {
		t.Fatalf("the in-band v2 fill must be submitted once, got %d", submitted.Load())
	}
	if got := request.OrderData.FillDetails[0].Price; got != askPrice.String() {
		t.Fatalf("submitted at %s, expected the maker's %s", got, askPrice)
	}
	// 1,000,000 cNGN x 0.0007 = 700 USDC; 25 bps
	if got := request.OrderData.TakerFee; got != "1750000000000000000" {
		t.Fatalf("taker fee %s, expected 1.75e18", got)
	}
	var mark *string
	if err := pool.QueryRow(ctx, "select mark_price from trade_fills where taker_order_id = $1", bid).Scan(&mark); err != nil {
		t.Fatal(err)
	}
	if mark == nil || *mark != "0.000714285714285714" {
		t.Fatalf("mark_price %v, expected v2's mark", mark)
	}
}
