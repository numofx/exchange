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

// A reduce-only order on a future fills no more than the account's position in the series, read from
// the chain at match time, and the venue cancels what is left: a 1-contract (1,000 USDC) reduce-only
// sell from an account long 0.4 contract fills 400 USDC and no more, so the account lands flat and
// never short.
func TestEngineTickClampsAReduceOnlyFutureOrderToThePosition(t *testing.T) {
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
		_, _ = w.Write([]byte(`{"accepted":true,"tx_hash":"0x` + strings.Repeat("cd", 32) + `","receipt_status":"success","block_number":"52391070"}`))
	}))
	defer executor.Close()

	asset := fmt.Sprintf("0x%040x", time.Now().UnixNano())
	closer, buyer := "731", "732"
	chain := &futureChain{index: 1400, future: asset, feed: "0x00000000000000000000000000000000000000fe",
		tm: "0x00000000000000000000000000000000000000a1", engine: "0x00000000000000000000000000000000000000e9",
		size:      new(big.Int).Mul(big.NewInt(1000), wad),
		positions: map[string]*big.Int{closer: new(big.Int).Div(new(big.Int).Mul(big.NewInt(4), wad), big.NewInt(10))}}
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

	suffix := fmt.Sprintf("future-ro-%d", time.Now().UnixNano())
	ask, bid := suffix+"-ask", suffix+"-bid"
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id in ($1,$2) or maker_order_id in ($1,$2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from perp_positions where subaccount_id in ($1, $2)", closer, buyer)
	})
	seed := func(id string, side orders.Side, subaccount, owner string, isBid, reduceOnly bool, age string) {
		nonce := fmt.Sprint(time.Now().UnixNano())
		action, _ := json.Marshal(map[string]any{
			"subaccount_id": subaccount, "nonce": nonce, "module": chain.tm,
			// one contract (1,000 USDC units) at 1,400 cNGN per USDC
			"data":   tradeDataHex(asset, cfg.FutureSubID(), "1400000000000000000000", "1000000000000000000", isBid),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()), "owner": owner, "signer": owner,
		})
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, reduce_only, created_at
) values ($1, $2, $2, $3, $3, $4, $5, $6, $7, '1000', '0', '1400', '1400', '2500000000000000000', $8, $9, '0x01', 'active', $10, now() - $11::interval)`,
			id, strings.ToLower(owner), subaccount, nonce, side, strings.ToLower(asset), cfg.FutureSubID(),
			time.Now().Add(time.Hour).Unix(), action, reduceOnly, age); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	// The reduce-only ask rests first; the bid takes it.
	seed(ask, orders.SideSell, closer, "0x3333333333333333333333333333333333333333", false, true, "2 seconds")
	seed(bid, orders.SideBuy, buyer, "0x4444444444444444444444444444444444444444", true, false, "1 second")

	e := NewEngine(cfg, pool)
	e.tickInstrument(ctx, instrument)
	if submitted.Load() != 1 {
		t.Fatalf("the clamped fill must be submitted once, got %d", submitted.Load())
	}
	// 400 venue units, 0.4 contract on chain: the position, not the 1,000 the order asked for.
	if got := request.OrderData.FillDetails[0].AmountFilled; got != "400000000000000000" {
		t.Fatalf("submitted %s, want the position's 4e17", got)
	}
	var status, filled string
	var reason *string
	if err := pool.QueryRow(ctx, "select status, filled_amount::text, cancel_reason from active_orders where order_id = $1", ask).Scan(&status, &filled, &reason); err != nil {
		t.Fatal(err)
	}
	if filled != "400" || status != string(orders.StatusCancelled) || reason == nil || *reason != orders.CancelReasonReduceOnlyDone {
		t.Fatalf("the reduce-only ask after its fill: %s filled %s reason %v", status, filled, reason)
	}
	// The ledger keeps the series under its own sub id, and it is flat after the fill.
	position, ok, err := e.orders.PerpPosition(ctx, closer, asset, cfg.FutureSubID())
	if err != nil || !ok || position.Sign() != 0 {
		t.Fatalf("ledger after the fill: %v ok %v err %v, want 0", position, ok, err)
	}
}
