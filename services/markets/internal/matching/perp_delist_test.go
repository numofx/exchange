package matching

import (
	"context"
	"encoding/json"
	"errors"
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

const (
	delistedModule = "0x00000000000000000000000000000000000000a1"
	delistedCash   = "0x00000000000000000000000000000000000000c1"
	delistedSRM    = "0x00000000000000000000000000000000000000d1"
)

// delistedMatcherConfig is the matcher after the perp's delisting: the shared module, cash and SRM
// set, the perp's asset unset.
func delistedMatcherConfig(rpc string) config.Config {
	return config.Config{
		ChainRPCURL:                rpc,
		MatchingAddress:            "0x9e90a9cd13d859bd6a08168082fb1f6f7405f191",
		CNGNPerpTradeModuleAddress: delistedModule,
		CNGNPerpCashAddress:        delistedCash,
		CNGNPerpSRMAddress:         delistedSRM,
	}
}

// With the perp delisted the matcher reads nothing of it: no margin check, no trading gate on its
// SRM, no position indexer.
func TestADelistedPerpHasNoMarginCheckGateOrIndexer(t *testing.T) {
	cfg := delistedMatcherConfig("http://rpc")
	if checker := newMarginChecker(cfg); checker != nil {
		t.Error("the perp margin check runs with the perp delisted")
	}
	if gate := newPerpTradingGate(cfg); gate != nil {
		t.Error("the perp trading gate runs with the perp delisted")
	}
	if indexer := newPositionIndexer(cfg, nil, nil); indexer != nil {
		t.Error("the perp position indexer runs with the perp delisted")
	}
}

// The shared module still has to settle in the configured cash: the future trades through it.
func TestTheSharedQuoteGuardStillRunsWithThePerpDelisted(t *testing.T) {
	onChainQuote := delistedCash
	rpc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": "0x" + strings.Repeat("0", 24) + onChainQuote[2:]})
	}))
	defer rpc.Close()
	cfg := delistedMatcherConfig(rpc.URL)
	if err := verifyPerpQuoteAsset(context.Background(), cfg); err != nil {
		t.Fatalf("matching cash: %v", err)
	}
	onChainQuote = "0x00000000000000000000000000000000000000ee"
	if err := verifyPerpQuoteAsset(context.Background(), cfg); !errors.Is(err, ErrQuoteAssetMismatch) {
		t.Fatalf("a module settling in other cash: %v, want ErrQuoteAssetMismatch", err)
	}
}

// The wiring: with the perp delisted, a crossing spot pair and a crossing future pair each settle.
func TestSpotAndTheFutureTradeWithThePerpDelisted(t *testing.T) {
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
	executor := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		submitted.Add(1)
		_, _ = io.ReadAll(r.Body)
		_, _ = w.Write([]byte(`{"accepted":true,"tx_hash":"0x` + strings.Repeat("ab", 32) + `","receipt_status":"success","block_number":"52391069"}`))
	}))
	defer executor.Close()

	// Markets of their own per run, so nothing left on another book can cross with these pairs.
	run := time.Now().UnixNano()
	spotAsset := fmt.Sprintf("0x%040x", run)
	futureAsset := fmt.Sprintf("0x%040x", run+1)
	chain := &futureChain{index: 1400, future: futureAsset, feed: "0x00000000000000000000000000000000000000fe",
		tm: delistedModule, engine: "0x00000000000000000000000000000000000000e9",
		size: new(big.Int).Mul(big.NewInt(1000), wad)}
	rpc := chain.serve(t)
	defer rpc.Close()
	cfg := delistedMatcherConfig(rpc.URL)
	cfg.ExecutorURL = executor.URL
	cfg.ExecutorTimeout = 5 * time.Second
	cfg.CNGNSpotAssetAddress = spotAsset
	cfg.CNGNFutureAssetAddress = futureAsset
	cfg.CNGNFutureExpiry = 1798675200
	cfg.CNGNFutureManagerAddress = chain.engine

	registry := instruments.DefaultRegistry(cfg)
	if item, ok := registry.BySymbol(instruments.CNGNPerpSymbol); ok && item.Enabled {
		t.Fatal("the perp is enabled with its asset unset")
	}
	spot, ok := registry.BySymbol(instruments.CNGNSpotSymbol)
	if !ok {
		t.Fatal("no spot instrument")
	}
	future, ok := registry.ByAssetAndSubID(futureAsset, cfg.FutureSubID())
	if !ok || !future.IsFuture() {
		t.Fatal("no future instrument")
	}

	ids := []string{}
	t.Cleanup(func() {
		for _, id := range ids {
			_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id = $1 or maker_order_id = $1", id)
			_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' = $1", id)
			_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", id)
		}
	})
	seed := func(id, asset, subID string, side orders.Side, ticks, amount, subaccount, owner string, isBid bool, age string) {
		ids = append(ids, id)
		nonce := fmt.Sprint(time.Now().UnixNano())
		action, _ := json.Marshal(map[string]any{
			"subaccount_id": subaccount,
			"nonce":         nonce,
			"module":        delistedModule,
			"data":          tradeDataHex(asset, subID, ticks+"000000000000000000", "1000000000000000000", isBid),
			"expiry":        fmt.Sprint(time.Now().Add(time.Hour).Unix()),
			"owner":         owner,
			"signer":        owner,
		})
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, $2, $3, $3, $4, $5, $6, $7, $8, '0', $9, $9, '2500000000000000000', $10, $11, '0x01', 'active', now() - $12::interval)`,
			id, strings.ToLower(owner), subaccount, nonce, side, strings.ToLower(asset), subID, amount, ticks,
			time.Now().Add(time.Hour).Unix(), action, age); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	suffix := fmt.Sprintf("delisted-%d", run)
	seed(suffix+"-spot-ask", spotAsset, "0", orders.SideSell, "1390", "1", "802", "0x2222222222222222222222222222222222222222", false, "2 seconds")
	seed(suffix+"-spot-bid", spotAsset, "0", orders.SideBuy, "1391", "1", "801", "0x1111111111111111111111111111111111111111", true, "1 second")
	// The index at 1,400 puts the future's band at 1,260-1,540.
	seed(suffix+"-future-ask", futureAsset, cfg.FutureSubID(), orders.SideSell, "1390", "1000", "804", "0x4444444444444444444444444444444444444444", false, "2 seconds")
	seed(suffix+"-future-bid", futureAsset, cfg.FutureSubID(), orders.SideBuy, "1395", "1000", "803", "0x3333333333333333333333333333333333333333", true, "1 second")

	e := NewEngine(cfg, pool)
	e.tickInstrument(ctx, spot)
	if got := submitted.Load(); got != 1 {
		t.Fatalf("spot with the perp delisted: %d settlements, want 1", got)
	}
	e.tickInstrument(ctx, future)
	if got := submitted.Load(); got != 2 {
		t.Fatalf("the future with the perp delisted: %d settlements, want 2", got)
	}
}
