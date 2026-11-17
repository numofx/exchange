package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// scriptedChain answers the three reads the verifier makes, from maps a test sets.
type scriptedChain struct {
	mu       sync.Mutex
	receipts map[string]uint64 // tx -> status
	txs      map[string][2]any // tx -> from, nonce
	nonces   map[string]uint64 // from -> latest
}

func newScriptedChain() *scriptedChain {
	return &scriptedChain{receipts: map[string]uint64{}, txs: map[string][2]any{}, nonces: map[string]uint64{}}
}

func (c *scriptedChain) serve(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		_ = json.Unmarshal(body, &req)
		var arg string
		_ = json.Unmarshal(req.Params[0], &arg)
		c.mu.Lock()
		defer c.mu.Unlock()
		var result any
		switch req.Method {
		case "eth_getTransactionReceipt":
			if s, ok := c.receipts[arg]; ok {
				result = map[string]string{"status": fmt.Sprintf("0x%x", s)}
			}
		case "eth_getTransactionByHash":
			if tx, ok := c.txs[arg]; ok {
				result = map[string]string{"from": tx[0].(string), "nonce": fmt.Sprintf("0x%x", tx[1].(uint64))}
			}
		case "eth_getTransactionCount":
			result = fmt.Sprintf("0x%x", c.nonces[arg])
		default:
			http.Error(w, "unexpected "+req.Method, http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": result})
	}))
	t.Cleanup(srv.Close)
	return srv
}

type verifierFixture struct {
	t                 *testing.T
	ctx               context.Context
	pool              *pgxpool.Pool
	repo              *orders.Repository
	asset             string
	subID             string
	primary, fallback *scriptedChain
	verifier          *settlementVerifier
	alerts            []string
	alertsMu          sync.Mutex
	clock             time.Time
}

const verifierExpiry = 1796050800

func newVerifierFixture(t *testing.T) *verifierFixture {
	t.Helper()
	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	f := &verifierFixture{t: t, ctx: context.Background(), pool: pool, repo: orders.NewRepository(pool),
		asset: fmt.Sprintf("0x%040x", time.Now().UnixNano()), subID: fmt.Sprint(verifierExpiry),
		primary: newScriptedChain(), fallback: newScriptedChain()}
	t.Cleanup(func() {
		ctx := context.Background()
		_, _ = pool.Exec(ctx, "delete from trade_fills where asset_address = $1", f.asset)
		_, _ = pool.Exec(ctx, "delete from trade_fills_voided where asset_address = $1", f.asset)
		_, _ = pool.Exec(ctx, "delete from market_events where market_key = $1", f.asset+":"+f.subID)
		_, _ = pool.Exec(ctx, "delete from active_orders where asset_address = $1", f.asset)
		_, _ = pool.Exec(ctx, "delete from perp_positions where asset_address = $1", f.asset)
	})
	fee := 5
	cfg := config.Config{
		ChainRPCURL:         f.primary.serve(t).URL,
		ChainRPCFallbackURL: f.fallback.serve(t).URL,
		FutureSeries: []config.FutureSeries{{AssetAddress: f.asset, Expiry: verifierExpiry, ManagerAddress: "0x00000000000000000000000000000000000000e9",
			Kind: config.FutureKindLinear, BaseAsset: "EURC", ContractSize: "1000", TakerFeeBps: &fee}},
	}
	alerts := newSettlementAlerter("http://alerts.invalid")
	alerts.post = func(_ context.Context, _, text string) error {
		f.alertsMu.Lock()
		f.alerts = append(f.alerts, text)
		f.alertsMu.Unlock()
		return nil
	}
	f.verifier = newSettlementVerifier(cfg, f.repo, instruments.DefaultRegistry(cfg), alerts)
	f.clock = time.Now()
	f.verifier.now = func() time.Time { return f.clock }
	return f
}

// fill records a matcher fill of `size` between a fresh taker buy (desired = size: the fill completes it) and a
// fresh maker sell (desired 10x: it stays active), as FinalizeMatchWithPrice does after a broadcast.
func (f *verifierFixture) fill(tx string, size string) (taker, maker string, tradeID int64) {
	f.t.Helper()
	n := time.Now().UnixNano()
	taker, maker = fmt.Sprintf("v-%d-taker", n), fmt.Sprintf("v-%d-maker", n)
	seed := func(id, side, subaccount, desired string) {
		if _, err := f.pool.Exec(f.ctx, `
insert into active_orders (order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at)
values ($1, '0x01', '0x01', $2, $2, $3, $4, $5, $6, $7, '0', '1.1', '1100000000000000000', '0', $8, '{}', '0x01', 'matching', now())`,
			id, subaccount, fmt.Sprint(n)+subaccount, side, f.asset, f.subID, desired, time.Now().Add(time.Hour).Unix()); err != nil {
			f.t.Fatalf("seed %s: %v", id, err)
		}
	}
	seed(taker, "buy", "701", size)
	seed(maker, "sell", "702", size+"0")
	if err := f.repo.FinalizeMatchWithPrice(f.ctx, taker, maker, "1.1", size, orders.FillSettlement{TxHash: tx}); err != nil {
		f.t.Fatal(err)
	}
	if err := f.pool.QueryRow(f.ctx, `select trade_id from trade_fills where taker_order_id = $1`, taker).Scan(&tradeID); err != nil {
		f.t.Fatal(err)
	}
	return taker, maker, tradeID
}

func (f *verifierFixture) tick() {
	f.t.Helper()
	if err := f.verifier.tick(f.ctx); err != nil {
		f.t.Fatal(err)
	}
}

func (f *verifierFixture) settlement(tradeID int64) string {
	var s *string
	err := f.pool.QueryRow(f.ctx, `select settlement from trade_fills where trade_id = $1`, tradeID).Scan(&s)
	if err != nil {
		return "gone"
	}
	if s == nil {
		return "null"
	}
	return *s
}

func (f *verifierFixture) order(id string) (status, filled string) {
	f.t.Helper()
	if err := f.pool.QueryRow(f.ctx, `select status, filled_amount from active_orders where order_id = $1`, id).Scan(&status, &filled); err != nil {
		f.t.Fatal(err)
	}
	return status, filled
}

func (f *verifierFixture) voidReason(tradeID int64) string {
	var reason string
	if err := f.pool.QueryRow(f.ctx, `select void_reason from trade_fills_voided where trade_id = $1`, tradeID).Scan(&reason); err != nil {
		return ""
	}
	return reason
}

func (f *verifierFixture) alertTexts() string {
	time.Sleep(50 * time.Millisecond) // send() posts on a goroutine
	f.alertsMu.Lock()
	defer f.alertsMu.Unlock()
	return strings.Join(f.alerts, "\n---\n")
}

func txHash(n int) string { return fmt.Sprintf("0x%064x", time.Now().UnixNano()+int64(n)) }

func TestSettlementVerifierConfirmsAMinedFillAndLeavesItAlone(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(1)
	taker, maker, id := f.fill(tx, "2")
	if got := f.settlement(id); got != "pending" {
		t.Fatalf("a broadcast fill is recorded pending, got %s", got)
	}
	f.primary.receipts[tx] = 1
	f.tick()
	if got := f.settlement(id); got != "confirmed" {
		t.Fatalf("settlement %s, want confirmed", got)
	}
	if s, filled := f.order(taker); s != "filled" || filled != "2" {
		t.Fatalf("taker %s %s", s, filled)
	}
	if s, filled := f.order(maker); s != "active" || filled != "2" {
		t.Fatalf("maker %s %s", s, filled)
	}
}

// The 2026-11-16 phantom: a broadcast no node ever received. It waits while it could still be in flight, then goes.
func TestSettlementVerifierVoidsAFillNoNodeEverSaw(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(2)
	taker, maker, id := f.fill(tx, "2")
	f.tick()
	if got := f.settlement(id); got != "pending" {
		t.Fatalf("unseen for under 10 minutes it waits: %s", got)
	}
	f.clock = f.clock.Add(11 * time.Minute)
	f.tick()
	if got := f.settlement(id); got != "gone" {
		t.Fatalf("unseen for 11 minutes on both RPCs it is voided: %s", got)
	}
	if r := f.voidReason(id); !strings.Contains(r, "never seen by any node") {
		t.Fatalf("void reason %q", r)
	}
	if s, filled := f.order(taker); s != "cancelled" || filled != "0" {
		t.Fatalf("the taker the fill had completed is cancelled with nothing filled, got %s %s", s, filled)
	}
	if s, filled := f.order(maker); s != "active" || filled != "0" {
		t.Fatalf("the resting maker keeps resting with nothing filled, got %s %s", s, filled)
	}
	var events int
	_ = f.pool.QueryRow(f.ctx, `select count(*) from market_events where channel = 'trades' and payload->>'trade_id' = $1`, fmt.Sprint(id)).Scan(&events)
	if events != 0 {
		t.Fatalf("its public trades event must go with it: %d left", events)
	}
	if a := f.alertTexts(); !strings.Contains(a, "NUMO FILL VOIDED") || !strings.Contains(a, tx) {
		t.Fatalf("the void is posted with its transaction: %q", a)
	}
}

func TestSettlementVerifierVoidsARevertedFill(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(3)
	_, _, id := f.fill(tx, "3")
	f.primary.receipts[tx] = 0
	f.tick()
	if got, r := f.settlement(id), f.voidReason(id); got != "gone" || r != "reverted on chain" {
		t.Fatalf("a reverted fill is voided at once: %s %q", got, r)
	}
}

func TestSettlementVerifierWaitsOnTheMempoolAndVoidsOnceTheNonceIsTakenElsewhere(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(4)
	_, _, id := f.fill(tx, "2")
	from := "0x00000000000000000000000000000000000000ee"
	f.primary.txs[tx] = [2]any{from, uint64(253)}
	f.primary.nonces[from] = 253
	f.clock = f.clock.Add(time.Hour)
	f.tick()
	if got := f.settlement(id); got != "pending" {
		t.Fatalf("a transaction in the mempool, its nonce not yet used, waits however old: %s", got)
	}
	if a := f.alertTexts(); !strings.Contains(a, "not mined") {
		t.Fatalf("an hour unmined is posted: %q", a)
	}
	f.tick()
	if n := strings.Count(f.alertTexts(), "not mined"); n != 1 {
		t.Fatalf("posted once, not every pass: %d", n)
	}
	f.primary.nonces[from] = 254
	f.tick()
	if got, r := f.settlement(id), f.voidReason(id); got != "gone" || !strings.Contains(r, "replaced: nonce 253") {
		t.Fatalf("nonce 253 used by something else, no receipt: voided; got %s %q", got, r)
	}
}

func TestSettlementVerifierConfirmsWhenTheNonceWasUsedByThisVeryTransaction(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(5)
	_, _, id := f.fill(tx, "2")
	from := "0x00000000000000000000000000000000000000ee"
	f.primary.txs[tx] = [2]any{from, uint64(253)}
	f.primary.nonces[from] = 254
	f.fallback.receipts[tx] = 1 // the primary's node lags behind the receipt
	f.tick()
	if got := f.settlement(id); got != "confirmed" {
		t.Fatalf("a consumed nonce with a receipt on the fallback is this transaction mined: %s", got)
	}
}

func TestSettlementVerifierWaitsWhileOnlyTheFallbackKnowsTheTransaction(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(6)
	_, _, id := f.fill(tx, "2")
	f.fallback.txs[tx] = [2]any{"0x00000000000000000000000000000000000000ee", uint64(9)}
	f.clock = f.clock.Add(time.Hour)
	f.tick()
	if got := f.settlement(id); got != "pending" {
		t.Fatalf("known to any node, it is not taken as never sent: %s", got)
	}
}

func TestSettlementVerifierDefersWhileAnOrderIsMidMatch(t *testing.T) {
	f := newVerifierFixture(t)
	tx := txHash(7)
	_, maker, id := f.fill(tx, "2")
	if _, err := f.pool.Exec(f.ctx, `update active_orders set status = 'matching' where order_id = $1`, maker); err != nil {
		t.Fatal(err)
	}
	f.primary.receipts[tx] = 0
	f.tick()
	if got := f.settlement(id); got != "pending" {
		t.Fatalf("an order reserved by another match is not touched; the void waits: %s", got)
	}
	if _, err := f.pool.Exec(f.ctx, `update active_orders set status = 'active' where order_id = $1`, maker); err != nil {
		t.Fatal(err)
	}
	f.tick()
	if got := f.settlement(id); got != "gone" {
		t.Fatalf("released, it is voided: %s", got)
	}
}

func TestSettlementVerifierMovesTheReduceOnlyLedgerBack(t *testing.T) {
	f := newVerifierFixture(t)
	for _, acc := range []string{"701", "702"} {
		if _, err := f.pool.Exec(f.ctx, `insert into perp_positions (subaccount_id, asset_address, sub_id, position) values ($1, $2, $3::numeric, 0)`,
			acc, f.asset, f.subID); err != nil {
			t.Fatal(err)
		}
	}
	tx := txHash(8)
	// The ledger as the fill left it: taker (701, buy) +2 units, maker (702, sell) -2 units, 1e15 a unit.
	_, _, id := f.fill(tx, "2")
	for acc, pos := range map[string]string{"701": "2000000000000000", "702": "-2000000000000000"} {
		if _, err := f.pool.Exec(f.ctx, `update perp_positions set position = $3::numeric where subaccount_id = $1 and asset_address = $2`, acc, f.asset, pos); err != nil {
			t.Fatal(err)
		}
	}
	f.primary.receipts[tx] = 0
	f.tick()
	if f.settlement(id) != "gone" {
		t.Fatal("not voided")
	}
	for _, acc := range []string{"701", "702"} {
		var pos string
		if err := f.pool.QueryRow(f.ctx, `select position::text from perp_positions where subaccount_id = $1 and asset_address = $2`, acc, f.asset).Scan(&pos); err != nil {
			t.Fatal(err)
		}
		if pos != "0" {
			t.Fatalf("account %s ledger %s after the void, want 0", acc, pos)
		}
	}
}

// A fill the verifier cannot put back safely (the perp, whose ledger the position indexer also moves, or a series the
// venue no longer lists) is posted for a person, once, and left on the tape.
func TestSettlementVerifierOnlyPostsAFillOnAMarketItCannotVoid(t *testing.T) {
	f := newVerifierFixture(t)
	f.asset = fmt.Sprintf("0x%040x", time.Now().UnixNano()+99) // not in the registry
	t.Cleanup(func() {
		_, _ = f.pool.Exec(context.Background(), "delete from trade_fills where asset_address = $1", f.asset)
		_, _ = f.pool.Exec(context.Background(), "delete from active_orders where asset_address = $1", f.asset)
		_, _ = f.pool.Exec(context.Background(), "delete from market_events where market_key = $1", f.asset+":"+f.subID)
	})
	tx := txHash(9)
	_, _, id := f.fill(tx, "2")
	f.primary.receipts[tx] = 0
	f.tick()
	f.tick()
	if got := f.settlement(id); got != "pending" {
		t.Fatalf("not voided automatically: %s", got)
	}
	a := f.alertTexts()
	if !strings.Contains(a, "void it by hand") || strings.Count(a, "void it by hand") != 1 || strings.Contains(a, "NUMO FILL VOIDED") {
		t.Fatalf("posted once for a person, never as voided: %q", a)
	}
}
