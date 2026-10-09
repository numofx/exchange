package matching

import (
	"context"
	"encoding/json"
	"errors"
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

// capture is a webhook that records what it is sent.
type capture struct {
	mu   sync.Mutex
	got  []string
	seen chan string
}

func newCapture() (*capture, *httptest.Server) {
	c := &capture{seen: make(chan string, 16)}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ Text string }
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		c.mu.Lock()
		c.got = append(c.got, body.Text)
		c.mu.Unlock()
		c.seen <- body.Text
	}))
	return c, srv
}

func (c *capture) next(t *testing.T) string {
	t.Helper()
	select {
	case text := <-c.seen:
		return text
	case <-time.After(3 * time.Second):
		t.Fatal("no alert was posted")
		return ""
	}
}

func (c *capture) none(t *testing.T) {
	t.Helper()
	select {
	case text := <-c.seen:
		t.Fatalf("unexpected alert: %q", text)
	case <-time.After(200 * time.Millisecond):
	}
}

func alerterAt(url string, now *time.Time) *settlementAlerter {
	a := newSettlementAlerter(url)
	a.now = func() time.Time { return *now }
	return a
}

func TestSettlementAlerterFailingRepeatsAndRecovers(t *testing.T) {
	c, srv := newCapture()
	defer srv.Close()
	now := time.Date(2026, 10, 9, 18, 44, 43, 0, time.UTC)
	a := alerterAt(srv.URL, &now)
	cause := errors.New("executor returned status 500: Missing or invalid parameters.\nDouble check you have provided the correct parameters.")

	a.Failed("cNGN-USDC", "executor_error", "spot-025b", "mm:cNGN-USDC:sell:229", cause)
	first := c.next(t)
	if !strings.HasPrefix(first, "NUMO SETTLEMENT FAILING") || !strings.Contains(first, "mm:cNGN-USDC:sell:229") || !strings.Contains(first, "Missing or invalid parameters") {
		t.Fatalf("first alert: %q", first)
	}
	if strings.Contains(first, "Double check") {
		t.Fatal("only the first line of the error is posted")
	}

	now = now.Add(time.Minute)
	a.Failed("cNGN-PERP", "executor_error", "perp-61fd", "mm:cNGN-PERP:buy:792", cause)
	c.none(t) // inside the repeat window: counted, not posted

	now = now.Add(15 * time.Minute)
	a.Failed("cNGN-PERP", "executor_error", "perp-750b", "mm:cNGN-PERP:sell:795", cause)
	if again := c.next(t); !strings.HasPrefix(again, "NUMO SETTLEMENT STILL FAILING\n3 failures since 18:44:43Z") {
		t.Fatalf("repeat alert: %q", again)
	}

	a.Settled()
	if rec := c.next(t); !strings.HasPrefix(rec, "NUMO SETTLEMENT RECOVERED") || !strings.Contains(rec, "3 failures") {
		t.Fatalf("recovery alert: %q", rec)
	}
	a.Settled()
	c.none(t) // a clean run says nothing
}

func TestSettlementAlerterPostsEveryOutcomeThatNeedsAPerson(t *testing.T) {
	c, srv := newCapture()
	defer srv.Close()
	now := time.Now()
	a := alerterAt(srv.URL, &now)
	for i := 0; i < 2; i++ {
		a.NeedsResolution("Outcome unknown", "cNGN-PERP", "t", "m", errors.New("receipt timeout"))
		if got := c.next(t); !strings.HasPrefix(got, "NUMO SETTLEMENT NEEDS RESOLUTION") {
			t.Fatalf("alert %d: %q", i, got)
		}
	}
}

func TestSettlementAlerterWithoutAWebhookIsSilentAndSafe(t *testing.T) {
	a := newSettlementAlerter("")
	a.Failed("m", "r", "t", "mk", errors.New("x"))
	a.Settled()
	var nilAlerter *settlementAlerter
	nilAlerter.Failed("m", "r", "t", "mk", nil)
}

// The wiring: a real engine tick against the test database, a crossed spot pair, an executor that refuses the
// settlement the way Alchemy refused the duplicate nonce, and the webhook the engine was configured with.
func TestEngineTickAlertsWhenASettlementFailsAndWhenItRecovers(t *testing.T) {
	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	// Registered first, so it runs after the row cleanup below (a deferred Close runs before t.Cleanup).
	t.Cleanup(pool.Close)
	ctx := context.Background()

	var executorFails = true
	executor := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if executorFails {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"Missing or invalid parameters.\nDouble check you have provided the correct parameters."}`))
			return
		}
		_, _ = w.Write([]byte(`{"accepted":true,"tx_hash":"0x` + strings.Repeat("ab", 32) + `","receipt_status":"success","block_number":"52391069"}`))
	}))
	defer executor.Close()
	alerts, webhook := newCapture()
	defer webhook.Close()

	// A market of its own per run: nothing another test (or an earlier run) left on a book can cross with this pair.
	asset := fmt.Sprintf("0x%040x", time.Now().UnixNano())
	cfg := config.Config{
		ExecutorURL:          executor.URL,
		ExecutorTimeout:      5 * time.Second,
		CNGNSpotAssetAddress: asset,
		AlertWebhookURL:      webhook.URL,
	}
	e := NewEngine(cfg, pool)
	instrument, ok := instruments.DefaultRegistry(cfg).BySymbol(instruments.CNGNSpotSymbol)
	if !ok {
		t.Fatal("no spot instrument")
	}

	suffix := fmt.Sprintf("alert-%d", time.Now().UnixNano())
	bid, ask := suffix+"-bid", suffix+"-ask"
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id in ($1,$2) or maker_order_id in ($1,$2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bid, ask)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bid, ask)
	})
	seed := func(id string, side orders.Side, ticks, subaccount, nonce, owner string, isBid bool, age string) {
		action, _ := json.Marshal(map[string]any{
			"subaccount_id": subaccount,
			"nonce":         nonce,
			"module":        "0x0AAE65AaA66Fe7f54486cDbD007956d3De611990",
			"data":          tradeDataHex(asset, "0", ticks+"000000000000000000", "1000000000000000", isBid),
			"expiry":        fmt.Sprint(time.Now().Add(time.Hour).Unix()),
			"owner":         owner,
			"signer":        owner,
		})
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, $2, $3, $3, $4, $5, $6, '0', '1', '0', $7, $7, '1000000000000000000000', $8, $9, '0x01', 'active', now() - $10::interval)`,
			id, strings.ToLower(owner), subaccount, nonce, side, strings.ToLower(asset), ticks, time.Now().Add(time.Hour).Unix(), action, age); err != nil {
			t.Fatalf("seed %s: %v", id, err)
		}
	}
	// The resting ask is older, so the bid is the taker.
	seed(ask, orders.SideSell, "1390", "602", fmt.Sprint(time.Now().UnixNano()), "0x2222222222222222222222222222222222222222", false, "2 seconds")
	seed(bid, orders.SideBuy, "1391", "601", fmt.Sprint(time.Now().UnixNano()+1), "0x1111111111111111111111111111111111111111", true, "1 second")

	e.tickInstrument(ctx, instrument)
	if got := alerts.next(t); !strings.HasPrefix(got, "NUMO SETTLEMENT FAILING") || !strings.Contains(got, "executor returned status 500") || !strings.Contains(got, "Missing or invalid parameters") {
		t.Fatalf("alert after a refused settlement: %q", got)
	}

	executorFails = false
	e.backoff.clear(orders.Order{OrderID: bid}, orders.Order{OrderID: ask})
	e.backoff = newMatchBackoff()
	e.tickInstrument(ctx, instrument)
	if got := alerts.next(t); !strings.HasPrefix(got, "NUMO SETTLEMENT RECOVERED") {
		t.Fatalf("alert after the next settlement: %q", got)
	}
}
