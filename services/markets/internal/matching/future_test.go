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
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

var wad = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

// futureChain is a JSON-RPC stub of a FutureAsset series, its index feed, the TradeModule and the
// MarginEngine, enabled. index is the index in whole cNGN per USDC; the feed reports its inverse.
type futureChain struct {
	mu                       sync.Mutex
	index                    int64
	future, feed, tm, engine string
	size                     *big.Int
	// surplus is engine.getMargin(account, true) by account, USD; an account not in it has plenty.
	surplus map[string]*big.Int
	// positions is each account's balance of the series, signed, 18dp; an account not in it is flat.
	positions map[string]*big.Int
}

const futureLedger = "0x00000000000000000000000000000000000000ac"

func (c *futureChain) setIndex(v int64) {
	c.mu.Lock()
	c.index = v
	c.mu.Unlock()
}

func (c *futureChain) serve(t *testing.T) *httptest.Server {
	word := func(v *big.Int) string { return fmt.Sprintf("%064x", v) }
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		// The settled fill's transaction, and a block with no mark set in it.
		switch req.Method {
		case "eth_getTransactionReceipt":
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1,
				"result": map[string]string{"blockNumber": "0x31f6e9d", "transactionIndex": "0x3"}})
			return
		case "eth_getLogs":
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": []any{}})
			return
		}
		var call struct{ To, Data string }
		_ = json.Unmarshal(req.Params[0], &call)
		to, sel := strings.ToLower(call.To), call.Data[:10]
		c.mu.Lock()
		index := c.index
		c.mu.Unlock()
		var result string
		switch {
		case to == c.future && sel == "0x198cae76": // indexFeed()
			result = strings.Repeat("0", 24) + c.feed[2:]
		case to == c.feed && sel == "0x2b37269c": // getSpot()
			result = word(new(big.Int).Div(wad, big.NewInt(index))) + word(wad)
		case to == c.future && sel == "0x968564c5": // markIndexBand(uint64)
			result = word(new(big.Int).Div(wad, big.NewInt(10)))
		case to == c.future && sel == "0x3d7cc610": // contractSize()
			result = word(c.size)
		case to == c.future && sel == "0xc3c74b34": // futureContracts(uint256)
			result = word(big.NewInt(1)) + word(big.NewInt(0)) + word(big.NewInt(1798675200)) +
				word(big.NewInt(time.Now().Add(24*time.Hour).Unix())) + word(big.NewInt(0)) + word(new(big.Int).Mul(big.NewInt(index), wad)) + word(big.NewInt(0))
		case to == c.tm && sel == "0x761822ef": // isDatedFutureAsset(address)
			result = word(big.NewInt(1))
		case to == c.future && sel == "0x745ab570": // totalPositionCap(address)
			result = word(new(big.Int).Mul(big.NewInt(30), wad))
		case to == c.engine && sel == "0xac06ba05": // adjustmentsPaused()
			result = word(big.NewInt(0))
		case to == c.engine && sel == "0xd21415a3": // assetDetails(address): whitelisted, Future, market 1
			result = word(big.NewInt(1)) + word(big.NewInt(4)) + word(big.NewInt(1))
		case to == c.engine && sel == "0x84033e5e": // futureMarginRequirements(uint256): 20% MM, 25% IM
			result = word(new(big.Int).Div(wad, big.NewInt(5))) + word(new(big.Int).Div(wad, big.NewInt(4)))
		case to == c.engine && sel == "0x623bb445": // getMargin(uint256,bool)
			account, _ := new(big.Int).SetString(call.Data[10:74], 16)
			c.mu.Lock()
			surplus, ok := c.surplus[account.String()]
			c.mu.Unlock()
			if !ok {
				surplus = new(big.Int).Mul(big.NewInt(1_000_000), wad)
			}
			result = word(new(big.Int).And(surplus, new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))))
		case to == c.future && sel == "0x779e5012": // subAccounts()
			result = strings.Repeat("0", 24) + futureLedger[2:]
		case to == futureLedger && sel == "0x0806e640": // getBalance(uint256,address,uint256)
			account := new(big.Int)
			account.SetString(call.Data[10:74], 16)
			c.mu.Lock()
			position, ok := c.positions[account.String()]
			c.mu.Unlock()
			if !ok {
				position = big.NewInt(0)
			}
			result = word(new(big.Int).And(position, new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))))
		default:
			t.Errorf("unexpected eth_call %s to %s", sel, to)
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "error": map[string]any{"message": "unexpected"}})
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": "0x" + result})
	}))
}

// The fee a future fill is charged is the notional in USDC, contracts x contract size, not price x
// amount: at 1,000 USDC a contract and 25 bps, 2.5 USDC a contract, whatever the price in cNGN.
func TestAFutureFillIsChargedOnItsContractSizeNotItsPrice(t *testing.T) {
	c := &futureChain{index: 1400, future: "0x00000000000000000000000000000000000000f0", feed: "0x00000000000000000000000000000000000000fe",
		size: new(big.Int).Mul(big.NewInt(1000), wad)}
	srv := c.serve(t)
	defer srv.Close()
	cfg := config.Config{ChainRPCURL: srv.URL, CNGNFutureAssetAddress: c.future, CNGNFutureExpiry: 1798675200, CNGNFutureManagerAddress: "0x00000000000000000000000000000000000000e9"}
	e := &Engine{futures: newFutureReaders(cfg)}
	future := instruments.DefaultRegistry(cfg).Enabled()[0]
	if !future.IsFuture() {
		t.Fatalf("expected the future, got %s", future.Symbol)
	}
	notional, err := e.feeNotionalPrice(context.Background(), future, "1400000000000000000000")
	if err != nil {
		t.Fatal(err)
	}
	fee, err := takerFillFee(future.TakerFeeBps, notional, wad.String())
	if err != nil {
		t.Fatal(err)
	}
	if fee != "2500000000000000000" {
		t.Fatalf("one contract's fee is %s, expected 2.5e18", fee)
	}
	if err := verifyFutureContractSize(context.Background(), e.futureReader(future), future); err != nil {
		t.Fatalf("the registry's contract size is the chain's: %v", err)
	}
	c.size = new(big.Int).Mul(big.NewInt(100), wad)
	if err := verifyFutureContractSize(context.Background(), (&Engine{futures: newFutureReaders(cfg)}).futureReader(future), future); err == nil {
		t.Fatal("a registry contract size that is not the chain's must stop the matcher")
	}
}

// The wiring: a real engine tick against the test database, a crossed futures pair, the chain stubbed.
// Out of the band, the pair is held back and never reaches the executor; once the index comes back,
// the same pair is submitted at its price, with the futures fee.
func TestEngineTickHoldsAFutureFillOutsideTheBandAndSubmitsItInside(t *testing.T) {
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
		_, _ = w.Write([]byte(`{"accepted":true,"tx_hash":"0x` + strings.Repeat("ab", 32) + `","receipt_status":"success","block_number":"52391069"}`))
	}))
	defer executor.Close()

	// A series of its own per run, so nothing left on another book can cross with this pair.
	asset := fmt.Sprintf("0x%040x", time.Now().UnixNano())
	chain := &futureChain{index: 1600, future: asset, feed: "0x00000000000000000000000000000000000000fe",
		tm: "0x00000000000000000000000000000000000000a1", engine: "0x00000000000000000000000000000000000000e9",
		size: new(big.Int).Mul(big.NewInt(1000), wad)}
	rpc := chain.serve(t)
	defer rpc.Close()
	cfg := config.Config{
		ExecutorURL:                executor.URL,
		ExecutorTimeout:            5 * time.Second,
		ChainRPCURL:                rpc.URL,
		CNGNPerpTradeModuleAddress: chain.tm,
		CNGNFutureAssetAddress:     asset,
		CNGNFutureExpiry:           1798675200,
		CNGNFutureManagerAddress:   chain.engine,
	}
	instrument, ok := instruments.DefaultRegistry(cfg).ByAssetAndSubID(asset, cfg.FutureSubID())
	if !ok || !instrument.IsFuture() {
		t.Fatal("no future instrument")
	}

	suffix := fmt.Sprintf("future-%d", time.Now().UnixNano())
	bid, ask := suffix+"-bid", suffix+"-ask"
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id in ($1,$2) or maker_order_id in ($1,$2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bid, ask)
	})
	seed := func(id string, side orders.Side, ticks, subaccount, owner string, isBid bool, age string) {
		nonce := fmt.Sprint(time.Now().UnixNano())
		action, _ := json.Marshal(map[string]any{
			"subaccount_id": subaccount,
			"nonce":         nonce,
			"module":        chain.tm,
			// one contract (1,000 USDC units), at ticks whole cNGN per USDC
			"data":   tradeDataHex(asset, cfg.FutureSubID(), ticks+"000000000000000000", "1000000000000000000", isBid),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()),
			"owner":  owner,
			"signer": owner,
		})
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, $2, $3, $3, $4, $5, $6, $7, '1000', '0', $8, $8, '2500000000000000000', $9, $10, '0x01', 'active', now() - $11::interval)`,
			id, strings.ToLower(owner), subaccount, nonce, side, strings.ToLower(asset), cfg.FutureSubID(), ticks,
			time.Now().Add(time.Hour).Unix(), action, age); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	// The resting ask is older, so the bid is the taker and the fill is at the ask, 1390.
	seed(ask, orders.SideSell, "1390", "702", "0x2222222222222222222222222222222222222222", false, "2 seconds")
	seed(bid, orders.SideBuy, "1395", "701", "0x1111111111111111111111111111111111111111", true, "1 second")

	// The index at 1,600 puts the band at 1,440-1,760: 1,390 is outside it.
	e := NewEngine(cfg, pool)
	e.tickInstrument(ctx, instrument)
	if submitted.Load() != 0 {
		t.Fatal("a fill outside the band reached the executor")
	}
	var status string
	if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", ask).Scan(&status); err != nil || status != "active" {
		t.Fatalf("the held-back maker must be back on the book, status %q %v", status, err)
	}

	// The index back at 1,400 puts the band at 1,260-1,540. A fresh engine: no backoff, no cached band.
	chain.setIndex(1400)
	e = NewEngine(cfg, pool)
	e.tickInstrument(ctx, instrument)
	if submitted.Load() != 1 {
		t.Fatalf("the in-band fill must be submitted once, got %d", submitted.Load())
	}
	if got := request.OrderData.FillDetails[0].Price; got != "1390000000000000000000" {
		t.Fatalf("submitted at %s, expected the maker's 1390e18", got)
	}
	if got := request.OrderData.TakerFee; got != "2500000000000000000" {
		t.Fatalf("taker fee %s, expected 2.5e18 for one contract of 1,000 USDC at 25 bps", got)
	}
	// The fill is recorded with the mark it settled against: the series' mark in its block, 1,400.
	var mark *string
	if err := pool.QueryRow(ctx, "select mark_price from trade_fills where taker_order_id = $1", bid).Scan(&mark); err != nil {
		t.Fatal(err)
	}
	if mark == nil || *mark != "1400" {
		t.Fatalf("mark_price %v, expected the block's mark 1400", mark)
	}
}

// The wiring: an under-margined maker at the best price, a healthy maker behind it, one taker. The short
// maker is refused and held back, the taker fills against the healthy maker on the next tick, and after
// three refusals over a minute the short maker is cancelled as insufficient_margin.
func TestEngineTickPassesOverAnUnderMarginedFuturesOrderThenCancelsIt(t *testing.T) {
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

	var mu sync.Mutex
	var submitted []ExecutorRequest
	executor := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var request ExecutorRequest
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &request)
		mu.Lock()
		submitted = append(submitted, request)
		mu.Unlock()
		_, _ = w.Write([]byte(`{"accepted":true,"tx_hash":"0x` + strings.Repeat("ab", 32) + `","receipt_status":"success","block_number":"52391069"}`))
	}))
	defer executor.Close()

	asset := fmt.Sprintf("0x%040x", time.Now().UnixNano())
	chain := &futureChain{index: 1400, future: asset, feed: "0x00000000000000000000000000000000000000fe",
		tm: "0x00000000000000000000000000000000000000a1", engine: "0x00000000000000000000000000000000000000e9",
		size: new(big.Int).Mul(big.NewInt(1000), wad),
		// 10 USD: one contract needs 250
		surplus: map[string]*big.Int{"803": new(big.Int).Mul(big.NewInt(10), wad)}}
	rpc := chain.serve(t)
	defer rpc.Close()
	cfg := config.Config{
		ExecutorURL: executor.URL, ExecutorTimeout: 5 * time.Second, ChainRPCURL: rpc.URL,
		CNGNPerpTradeModuleAddress: chain.tm, CNGNFutureAssetAddress: asset, CNGNFutureExpiry: 1798675200,
		CNGNFutureManagerAddress: chain.engine,
	}
	instrument, _ := instruments.DefaultRegistry(cfg).ByAssetAndSubID(asset, cfg.FutureSubID())

	suffix := fmt.Sprintf("future-margin-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1 or maker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
	})
	seed := func(id string, side orders.Side, ticks, subaccount string, isBid bool, age string) string {
		orderID := suffix + "-" + id
		nonce := fmt.Sprint(time.Now().UnixNano())
		owner := fmt.Sprintf("0x%040s", subaccount)
		action, _ := json.Marshal(map[string]any{
			"subaccount_id": subaccount, "nonce": nonce, "module": chain.tm,
			"data":   tradeDataHex(asset, cfg.FutureSubID(), ticks+"000000000000000000", "1000000000000000000", isBid),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()), "owner": owner, "signer": owner,
		})
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, $2, $3, $3, $4, $5, $6, $7, '1000', '0', $8, $8, '2500000000000000000', $9, $10, '0x01', 'active', now() - $11::interval)`,
			orderID, owner, subaccount, nonce, side, strings.ToLower(asset), cfg.FutureSubID(), ticks,
			time.Now().Add(time.Hour).Unix(), action, age); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
		return orderID
	}
	statusOf := func(orderID string) (string, string) {
		var status string
		var reason *string
		_ = pool.QueryRow(ctx, "select status, cancel_reason from active_orders where order_id = $1", orderID).Scan(&status, &reason)
		if reason == nil {
			return status, ""
		}
		return status, *reason
	}

	shortAsk := seed("short-ask", orders.SideSell, "1395", "803", false, "3 seconds") // the best ask, under-margined
	goodAsk := seed("good-ask", orders.SideSell, "1398", "802", false, "2 seconds")
	seed("bid-1", orders.SideBuy, "1400", "801", true, "1 second")

	e := NewEngine(cfg, pool)
	now := time.Now()
	e.marginRefusals.now = func() time.Time { return now }

	e.tickInstrument(ctx, instrument)
	if len(submitted) != 0 {
		t.Fatal("a fill against the under-margined maker reached the executor")
	}
	e.tickInstrument(ctx, instrument)
	if len(submitted) != 1 || submitted[0].OrderData.FillDetails[0].Price != "1398000000000000000000" {
		t.Fatalf("the taker must fill against the healthy maker behind the short one: %+v", submitted)
	}
	if status, _ := statusOf(goodAsk); status != "filled" {
		t.Fatalf("the healthy maker: %s", status)
	}

	// New takers keep meeting the short maker: refused again 30s and 61s after the first, it is cancelled.
	first := now
	for i, at := range []time.Duration{futureMarginRetry, futureMarginRetry + 31*time.Second} {
		seed(fmt.Sprintf("bid-%d", i+2), orders.SideBuy, "1400", fmt.Sprint(810+i), true, "0 seconds")
		now = first.Add(at)
		e.tickInstrument(ctx, instrument)
	}
	if status, reason := statusOf(shortAsk); status != "cancelled" || reason != CancelReasonInsufficientMargin {
		t.Fatalf("the short maker after three refusals over a minute: %s %q", status, reason)
	}
	if len(submitted) != 1 {
		t.Fatalf("nothing more may reach the executor against the short maker: %d", len(submitted))
	}
}
