package orders

import (
	"context"
	"fmt"
	"os"
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
