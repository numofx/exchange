package orders

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

func openTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()

	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}

	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatalf("connect test db: %v", err)
	}
	t.Cleanup(pool.Close)

	return pool
}

func TestFinalizeMatchWithPriceWritesTradeFillExactlyOnce(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-finalize-%d", time.Now().UnixNano())

	takerID := suffix + "-taker"
	makerID := suffix + "-maker"
	assetAddress := "0xfeed000000000000000000000000000000000001"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id = $1 or maker_order_id = $2", takerID, makerID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1 or order_id = $2", takerID, makerID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $3, 1, 1, $4, $5, $6, $7, '100', '0', $8, $9, '0', $10, '{}'::jsonb, '0xsig', 'matching')
`

	expiry := time.Now().Add(time.Hour).Unix()
	if _, err := pool.Exec(ctx, insertOrder, takerID, "0xowner", "0xsigner", "1", SideBuy, assetAddress, subID, "1605.25", "1605250000000000000000", expiry); err != nil {
		t.Fatalf("insert taker: %v", err)
	}
	if _, err := pool.Exec(ctx, insertOrder, makerID, "0xowner", "0xsigner", "2", SideSell, assetAddress, subID, "1605.25", "1605250000000000000000", expiry); err != nil {
		t.Fatalf("insert maker: %v", err)
	}

	if err := repo.FinalizeMatchWithPrice(ctx, takerID, makerID, "1605.25", "100"); err != nil {
		t.Fatalf("finalize match: %v", err)
	}

	if err := repo.FinalizeMatchWithPrice(ctx, takerID, makerID, "1605.25", "100"); err == nil {
		t.Fatal("expected second finalize to fail")
	}

	var count int
	if err := pool.QueryRow(ctx, "select count(*) from trade_fills where taker_order_id = $1 and maker_order_id = $2", takerID, makerID).Scan(&count); err != nil {
		t.Fatalf("count fills: %v", err)
	}
	if count != 1 {
		t.Fatalf("fill count = %d", count)
	}
}

func TestListTradesOrdersAndIsolatesMarkets(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-trades-%d", time.Now().UnixNano())

	assetA := "0xfeed0000000000000000000000000000000000aa"
	assetB := "0xfeed0000000000000000000000000000000000bb"
	subA := "1789567201"
	subB := "1782864000"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1", suffix+"%")
	})

	insertFill := `
insert into trade_fills (
  asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at
) values ($1, $2, $3, $4, $5, $6, $7, $8)
returning trade_id
`

	now := time.Now().UTC()
	var oldestID, middleID, newestID int64
	if err := pool.QueryRow(ctx, insertFill, assetA, subA, "1600.00", "1", SideBuy, suffix+"-t1", suffix+"-m1", now.Add(-2*time.Hour)).Scan(&oldestID); err != nil {
		t.Fatalf("insert oldest: %v", err)
	}
	if err := pool.QueryRow(ctx, insertFill, assetA, subA, "1602.00", "2", SideSell, suffix+"-t2", suffix+"-m2", now.Add(-time.Hour)).Scan(&middleID); err != nil {
		t.Fatalf("insert middle: %v", err)
	}
	if err := pool.QueryRow(ctx, insertFill, assetA, subA, "1604.00", "3", SideBuy, suffix+"-t3", suffix+"-m3", now).Scan(&newestID); err != nil {
		t.Fatalf("insert newest: %v", err)
	}
	if _, err := pool.Exec(ctx, insertFill, assetB, subB, "1700.00", "9", SideBuy, suffix+"-tb", suffix+"-mb", now); err != nil {
		t.Fatalf("insert other market: %v", err)
	}

	items, err := repo.ListTrades(ctx, assetA, subA, 0, 10)
	if err != nil {
		t.Fatalf("list trades: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("len = %d", len(items))
	}
	if items[0].TradeID != newestID || items[1].TradeID != middleID || items[2].TradeID != oldestID {
		t.Fatalf("unexpected ordering: %+v", items)
	}

	page, err := repo.ListTrades(ctx, assetA, subA, middleID, 10)
	if err != nil {
		t.Fatalf("list paged trades: %v", err)
	}
	if len(page) != 1 || page[0].TradeID != oldestID {
		t.Fatalf("unexpected page: %+v", page)
	}
}

func TestFinalizeMatchWithPriceWritesAtomicFillTradeRow(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-atomic-fill-%d", time.Now().UnixNano())

	takerID := suffix + "-taker"
	makerID := suffix + "-maker"
	assetAddress := "0xfeed0000000000000000000000000000000000cc"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id = $1 or maker_order_id = $2", takerID, makerID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1 or order_id = $2", takerID, makerID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $3, 1, 1, $4, $5, $6, $7, '1', '0', $8, $9, '0', $10, '{}'::jsonb, '0xsig', 'matching')
`

	expiry := time.Now().Add(time.Hour).Unix()
	if _, err := pool.Exec(ctx, insertOrder, takerID, "0xowner", "0xsigner", "1", SideBuy, assetAddress, subID, "1391", "1391", expiry); err != nil {
		t.Fatalf("insert taker: %v", err)
	}
	if _, err := pool.Exec(ctx, insertOrder, makerID, "0xowner", "0xsigner", "2", SideSell, assetAddress, subID, "1390", "1390", expiry); err != nil {
		t.Fatalf("insert maker: %v", err)
	}

	if err := repo.FinalizeMatchWithPrice(ctx, takerID, makerID, "1390", "1"); err != nil {
		t.Fatalf("finalize match: %v", err)
	}

	var size string
	if err := pool.QueryRow(ctx, "select size from trade_fills where taker_order_id = $1 and maker_order_id = $2", takerID, makerID).Scan(&size); err != nil {
		t.Fatalf("load fill row: %v", err)
	}
	if size != "1" {
		t.Fatalf("fill size = %s", size)
	}
}

func TestAcquireMatchCandidateDoesNotChurnUncrossedBook(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-uncrossed-%d", time.Now().UnixNano())

	bidID := suffix + "-bid"
	askID := suffix + "-ask"
	assetAddress := "0xfeed0000000000000000000000000000000000cc"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bidID, askID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bidID, askID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $3, 1, 1, $4, $5, $6, $7, '100', '0', $8, $9, '0', $10, '{}'::jsonb, '0xsig', 'active')
`

	expiry := time.Now().Add(time.Hour).Unix()
	// Bid 1378 below ask 1382: the book does not cross.
	if _, err := pool.Exec(ctx, insertOrder, bidID, "0xowner", "0xsigner", "1", SideBuy, assetAddress, subID, "1378", "1378", expiry); err != nil {
		t.Fatalf("insert bid: %v", err)
	}
	if _, err := pool.Exec(ctx, insertOrder, askID, "0xowner", "0xsigner", "2", SideSell, assetAddress, subID, "1382", "1382", expiry); err != nil {
		t.Fatalf("insert ask: %v", err)
	}

	eventsBefore := countOrderEvents(t, pool, bidID, askID)

	for i := 0; i < 5; i++ {
		candidate, err := repo.AcquireMatchCandidate(ctx, assetAddress, subID, time.Now(), nil)
		if err != nil {
			t.Fatalf("acquire on uncrossed book: %v", err)
		}
		if candidate != nil {
			t.Fatalf("acquire returned a candidate for an uncrossed book: %+v", candidate)
		}
	}

	// Both orders must still be 'active' — never flipped through 'matching'.
	for _, id := range []string{bidID, askID} {
		var status string
		if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", id).Scan(&status); err != nil {
			t.Fatalf("read status %s: %v", id, err)
		}
		if status != "active" {
			t.Fatalf("order %s status = %s, want active", id, status)
		}
	}

	if got := countOrderEvents(t, pool, bidID, askID); got != eventsBefore {
		t.Fatalf("uncrossed ticks wrote %d market_events rows, want 0", got-eventsBefore)
	}
}

func TestAcquireMatchCandidateStillReservesCrossedBook(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-crossed-%d", time.Now().UnixNano())

	bidID := suffix + "-bid"
	askID := suffix + "-ask"
	assetAddress := "0xfeed0000000000000000000000000000000000dd"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bidID, askID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bidID, askID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $3, 1, 1, $4, $5, $6, $7, '100', '0', $8, $9, '0', $10, '{}'::jsonb, '0xsig', 'active')
`

	expiry := time.Now().Add(time.Hour).Unix()
	// Bid 1382 at or above ask 1378: the book crosses.
	if _, err := pool.Exec(ctx, insertOrder, bidID, "0xowner", "0xsigner", "1", SideBuy, assetAddress, subID, "1382", "1382", expiry); err != nil {
		t.Fatalf("insert bid: %v", err)
	}
	if _, err := pool.Exec(ctx, insertOrder, askID, "0xowner", "0xsigner", "2", SideSell, assetAddress, subID, "1378", "1378", expiry); err != nil {
		t.Fatalf("insert ask: %v", err)
	}

	candidate, err := repo.AcquireMatchCandidate(ctx, assetAddress, subID, time.Now(), nil)
	if err != nil {
		t.Fatalf("acquire on crossed book: %v", err)
	}
	if candidate == nil {
		t.Fatal("acquire returned no candidate for a crossed book")
	}

	for _, id := range []string{bidID, askID} {
		var status string
		if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", id).Scan(&status); err != nil {
			t.Fatalf("read status %s: %v", id, err)
		}
		if status != "matching" {
			t.Fatalf("order %s status = %s, want matching", id, status)
		}
	}
}

func countOrderEvents(t *testing.T, pool *pgxpool.Pool, orderIDs ...string) int {
	t.Helper()

	var count int
	if err := pool.QueryRow(context.Background(),
		"select count(*) from market_events where payload->>'order_id' = any($1)", orderIDs,
	).Scan(&count); err != nil {
		t.Fatalf("count market_events: %v", err)
	}
	return count
}

func TestPruneTerminalOrdersRespectsHorizonAndKeepsFilled(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-prune-%d", time.Now().UnixNano())

	assetAddress := "0xfeed0000000000000000000000000000000000ee"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, '0xsigner', 1, 1, $3, 'buy', $4, $5, '100', '0', '1380', '1380', '0', $6, '{}'::jsonb, '0xsig', $7, $8)
`

	expiry := time.Now().Add(time.Hour).Unix()
	now := time.Now().UTC()
	// (id suffix, status, age) — only stale cancelled/expired rows may be pruned.
	rows := []struct {
		name   string
		status string
		age    time.Duration
	}{
		{"stale-cancelled", "cancelled", 48 * time.Hour},
		{"stale-expired", "expired", 48 * time.Hour},
		{"stale-filled", "filled", 48 * time.Hour},
		{"fresh-cancelled", "cancelled", time.Minute},
		{"active", "active", 48 * time.Hour},
	}
	for i, row := range rows {
		id := suffix + "-" + row.name
		nonce := fmt.Sprintf("%d", 900000+i)
		if _, err := pool.Exec(ctx, insertOrder, id, "0xowner"+id, nonce, assetAddress, subID, expiry, row.status, now.Add(-row.age)); err != nil {
			t.Fatalf("insert %s: %v", row.name, err)
		}
	}

	removed, err := repo.PruneTerminalOrders(ctx, 24*time.Hour, 2)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 2 {
		t.Fatalf("pruned %d rows, want 2 (stale cancelled + stale expired)", removed)
	}

	survivors := map[string]bool{}
	pgRows, err := pool.Query(ctx, "select order_id from active_orders where order_id like $1", suffix+"%")
	if err != nil {
		t.Fatalf("query survivors: %v", err)
	}
	defer pgRows.Close()
	for pgRows.Next() {
		var id string
		if err := pgRows.Scan(&id); err != nil {
			t.Fatalf("scan survivor: %v", err)
		}
		survivors[strings.TrimPrefix(id, suffix+"-")] = true
	}
	if err := pgRows.Err(); err != nil {
		t.Fatalf("iterate survivors: %v", err)
	}

	for _, want := range []string{"stale-filled", "fresh-cancelled", "active"} {
		if !survivors[want] {
			t.Errorf("%s was pruned but must be kept", want)
		}
	}
	for _, gone := range []string{"stale-cancelled", "stale-expired"} {
		if survivors[gone] {
			t.Errorf("%s survived the prune", gone)
		}
	}

	// Second run is a no-op: nothing stale is left.
	again, err := repo.PruneTerminalOrders(ctx, 24*time.Hour, 2)
	if err != nil {
		t.Fatalf("second prune: %v", err)
	}
	if again != 0 {
		t.Fatalf("second prune removed %d rows, want 0", again)
	}
}

func TestAcquireMatchCandidateSkipsGatedPairWithoutReserving(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-gated-%d", time.Now().UnixNano())

	bidID := suffix + "-bid"
	askID := suffix + "-ask"
	assetAddress := "0xfeed0000000000000000000000000000000000ab"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from market_events where payload->>'order_id' in ($1, $2)", bidID, askID)
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id in ($1, $2)", bidID, askID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, '0xsigner', 1, 1, $3, $4, $5, $6, '100', '0', $7, $8, '0', $9, '{}'::jsonb, '0xsig', 'active')
`
	expiry := time.Now().Add(time.Hour).Unix()
	// A crossed book: without the gate this pair would be reserved every tick.
	if _, err := pool.Exec(ctx, insertOrder, bidID, "0xowner"+bidID, "970001", SideBuy, assetAddress, subID, "1382", "1382", expiry); err != nil {
		t.Fatalf("insert bid: %v", err)
	}
	if _, err := pool.Exec(ctx, insertOrder, askID, "0xowner"+askID, "970002", SideSell, assetAddress, subID, "1378", "1378", expiry); err != nil {
		t.Fatalf("insert ask: %v", err)
	}

	eventsBefore := countOrderEvents(t, pool, bidID, askID)

	gateCalls := 0
	gate := func(taker Order, maker Order) bool {
		gateCalls++
		return true
	}

	for i := 0; i < 5; i++ {
		candidate, err := repo.AcquireMatchCandidate(ctx, assetAddress, subID, time.Now(), gate)
		if err != nil {
			t.Fatalf("acquire with gate: %v", err)
		}
		if candidate != nil {
			t.Fatalf("gated pair was still returned: %+v", candidate)
		}
	}

	if gateCalls != 5 {
		t.Errorf("gate consulted %d times, want 5", gateCalls)
	}
	for _, id := range []string{bidID, askID} {
		var status string
		if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", id).Scan(&status); err != nil {
			t.Fatalf("read status %s: %v", id, err)
		}
		if status != "active" {
			t.Errorf("order %s status = %s, want active (gated pair must not be reserved)", id, status)
		}
	}
	if got := countOrderEvents(t, pool, bidID, askID); got != eventsBefore {
		t.Errorf("gated ticks wrote %d market_events rows, want 0", got-eventsBefore)
	}

	// With the gate open the same pair reserves normally.
	candidate, err := repo.AcquireMatchCandidate(ctx, assetAddress, subID, time.Now(), func(Order, Order) bool { return false })
	if err != nil {
		t.Fatalf("acquire with open gate: %v", err)
	}
	if candidate == nil {
		t.Fatal("open gate should have produced a candidate")
	}
}
