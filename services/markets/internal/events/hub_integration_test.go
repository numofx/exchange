package events

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/numofx/matching-backend/internal/config"
	projectmigrations "github.com/numofx/matching-backend/migrations"
)

// TestHubPipeline exercises the full trigger -> NOTIFY -> Hub -> Sub path against a real
// Postgres. Set TEST_DATABASE_URL to a throwaway database to run it; skipped otherwise.
func TestHubPipeline(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL to run the events integration test")
	}
	ctx, cancel := context.WithCancel(context.Background())
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		cancel()
		t.Fatalf("connect: %v", err)
	}
	// Teardown order matters (defers run LIFO): cancel the context first so the Hub's LISTEN
	// goroutine releases its acquired connection, THEN close the pool — otherwise pool.Close()
	// blocks forever waiting on that still-held conn.
	defer pool.Close()
	defer cancel()
	applyMigrations(ctx, t, pool)

	// Unique per run: the replay assertion below counts every book event on this
	// market, so a fixed address collides with anything else in the same database
	// (api's ws test writes to the real spot asset) and with earlier runs.
	// Mixed case is deliberate — it exercises the trigger's lower() on market_key.
	assetHex := fmt.Sprintf("%040X", time.Now().UnixNano())
	asset := "0x" + assetHex
	market := strings.ToLower(asset) + ":0"
	orderID := "ord-" + assetHex

	// Must be a defer, not t.Cleanup: defers run LIFO at function exit and this one
	// is registered after `defer pool.Close()`, so it runs while the pool is still
	// open. A t.Cleanup here would fire after pool.Close() and silently no-op.
	defer func() {
		_, _ = pool.Exec(ctx, "delete from market_events where market_key = $1", market)
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id = $1", orderID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", orderID)
	}()

	cfg := config.Config{
		EventsPruneHorizon:      time.Hour,
		EventsPruneInterval:     0, // disable prune in the test
		EventsReconcileInterval: time.Second,
		EventsSubBuffer:         64,
	}
	hub := NewHub(pool, cfg, nil)
	go func() { _ = hub.Run(ctx) }()
	// let Run establish LISTEN + initSeq before we subscribe
	time.Sleep(150 * time.Millisecond)

	bookSub, ok := hub.Subscribe(Filter{Channel: ChannelBook, Market: market})
	if !ok {
		t.Fatal("subscribe book")
	}
	defer hub.Unsubscribe(bookSub)
	ordersSub, ok := hub.Subscribe(Filter{Channel: ChannelOrders, Owner: "0xabcdef0000000000000000000000000000000001"})
	if !ok {
		t.Fatal("subscribe orders")
	}
	defer hub.Unsubscribe(ordersSub)

	// place an order -> expect a book level_delta (+5) and an owner-scoped order_update
	mustExec(ctx, t, pool, `insert into active_orders
		(order_id,owner_address,signer_address,subaccount_id,recipient_id,nonce,side,asset_address,sub_id,desired_amount,filled_amount,limit_price,limit_price_ticks,worst_fee,expiry,action_json,signature,status)
		values ($2,'0xABCDEF0000000000000000000000000000000001','0xsigner',7,7,1,'buy',$1,0,'5','0','1380','1380','0',9999999999,'{}','0xsig','active')`, asset, orderID)

	book := waitEvent(t, bookSub, "book")
	if book.Channel != ChannelBook || !strings.Contains(string(book.Payload), `"size_delta": "5"`) {
		t.Fatalf("unexpected book event: %s", book.Payload)
	}
	order := waitEvent(t, ordersSub, "orders")
	if order.OwnerAddress != "0xabcdef0000000000000000000000000000000001" {
		t.Fatalf("order event owner not lowercased/routed: %q", order.OwnerAddress)
	}

	// a trade fill on a non-subscribed channel must NOT reach the book subscriber
	mustExec(ctx, t, pool, `insert into trade_fills(asset_address,sub_id,price,size,aggressor_side,taker_order_id,maker_order_id)
		values ($1,0,'1380','2','buy',$2,'ord-2')`, asset, orderID)
	// cancel -> another book delta (-5) should arrive next on the book sub (proving trades didn't jump the queue)
	mustExec(ctx, t, pool, `update active_orders set status='cancelled' where order_id=$1`, orderID)
	book2 := waitEvent(t, bookSub, "book")
	if !strings.Contains(string(book2.Payload), `"size_delta": "-5"`) {
		t.Fatalf("expected -5 book delta after cancel, got: %s", book2.Payload)
	}
	if book2.Seq <= book.Seq {
		t.Fatalf("seq not monotonic: %d <= %d", book2.Seq, book.Seq)
	}

	// replay: a fresh subscriber resuming from seq 0 should get the book history via Since
	replayed, err := hub.Since(ctx, Filter{Channel: ChannelBook, Market: market}, 0, 100)
	if err != nil {
		t.Fatalf("since: %v", err)
	}
	if len(replayed) != 2 {
		t.Fatalf("expected 2 book events in replay, got %d", len(replayed))
	}
}

func waitEvent(t *testing.T, s *Sub, label string) Event {
	t.Helper()
	select {
	case e := <-s.Events():
		return e
	case <-s.Done():
		t.Fatalf("%s sub dropped", label)
	case <-time.After(3 * time.Second):
		t.Fatalf("timeout waiting for %s event", label)
	}
	return Event{}
}

func mustExec(ctx context.Context, t *testing.T, pool *pgxpool.Pool, sql string, args ...any) {
	t.Helper()
	if _, err := pool.Exec(ctx, sql, args...); err != nil {
		t.Fatalf("exec: %v", err)
	}
}

func applyMigrations(ctx context.Context, t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	entries, err := fs.ReadDir(projectmigrations.Files, ".")
	if err != nil {
		t.Fatalf("read migrations: %v", err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".up.sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)
	for _, name := range files {
		b, err := fs.ReadFile(projectmigrations.Files, name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if _, err := pool.Exec(ctx, string(b)); err != nil {
			t.Fatalf("apply %s: %v", name, err)
		}
	}
}
