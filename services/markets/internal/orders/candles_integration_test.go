package orders

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestParseCandleInterval(t *testing.T) {
	if got, err := ParseCandleInterval("1h"); err != nil || got.Seconds != 3600 {
		t.Fatalf("1h -> %+v, %v", got, err)
	}
	if got, err := ParseCandleInterval("  1d "); err != nil || got.Seconds != 86400 {
		t.Fatalf("padded 1d -> %+v, %v", got, err)
	}
	if _, err := ParseCandleInterval("3s"); err == nil {
		t.Fatal("expected unsupported interval to error")
	}
}

func TestListCandlesAggregatesOHLCVPerBucket(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()

	suffix := fmt.Sprintf("it-candles-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000000c1"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1", suffix+"%")
	})

	// Two 1h buckets, deliberately separated by an empty hour to prove empty
	// buckets are omitted rather than zero-filled.
	base := time.Date(2026, 3, 2, 10, 0, 0, 0, time.UTC)
	fills := []struct {
		at    time.Time
		price string
		size  string
	}{
		{base.Add(1 * time.Minute), "1380", "1"},  // bucket A open
		{base.Add(10 * time.Minute), "1390", "2"}, // bucket A high
		{base.Add(20 * time.Minute), "1370", "3"}, // bucket A low
		{base.Add(30 * time.Minute), "1385", "4"}, // bucket A close
		{base.Add(2 * time.Hour), "1400", "5"},    // bucket C (skips one hour)
	}
	for i, fill := range fills {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at)
values ($1, $2, $3, $4, 'buy', $5, $6, $7)`,
			asset, subID, fill.price, fill.size,
			fmt.Sprintf("%s-taker-%d", suffix, i), fmt.Sprintf("%s-maker-%d", suffix, i), fill.at,
		); err != nil {
			t.Fatalf("insert fill %d: %v", i, err)
		}
	}

	hourly, err := ParseCandleInterval("1h")
	if err != nil {
		t.Fatalf("interval: %v", err)
	}
	candles, err := repo.ListCandles(ctx, asset, subID, hourly, base.Add(-time.Hour), base.Add(4*time.Hour), 100)
	if err != nil {
		t.Fatalf("list candles: %v", err)
	}

	if len(candles) != 2 {
		t.Fatalf("got %d candles, want 2 (empty bucket must be omitted): %+v", len(candles), candles)
	}

	first := candles[0]
	if !first.BucketStart.Equal(base) {
		t.Errorf("first bucket_start = %s, want %s", first.BucketStart, base)
	}
	if first.Open != "1380" || first.High != "1390" || first.Low != "1370" || first.Close != "1385" {
		t.Errorf("bucket A OHLC = %s/%s/%s/%s, want 1380/1390/1370/1385",
			first.Open, first.High, first.Low, first.Close)
	}
	if first.Volume != "10" {
		t.Errorf("bucket A volume = %s, want 10", first.Volume)
	}
	if first.TradeCount != 4 {
		t.Errorf("bucket A trade_count = %d, want 4", first.TradeCount)
	}

	second := candles[1]
	if !second.BucketStart.Equal(base.Add(2 * time.Hour)) {
		t.Errorf("second bucket_start = %s, want %s", second.BucketStart, base.Add(2*time.Hour))
	}
	if second.Open != "1400" || second.Close != "1400" || second.High != "1400" || second.Low != "1400" {
		t.Errorf("single-trade bucket should have all four equal, got %s/%s/%s/%s",
			second.Open, second.High, second.Low, second.Close)
	}
}

func TestListCandlesComparesPricesNumericallyNotLexically(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()

	suffix := fmt.Sprintf("it-candles-num-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000000c2"
	subID := "0"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1", suffix+"%")
	})

	// "9" > "10" lexically but not numerically; spot prices are sub-1 decimals
	// where string ordering is especially wrong.
	base := time.Date(2026, 3, 3, 8, 0, 0, 0, time.UTC)
	for i, price := range []string{"9", "10", "0.0007", "0.00071"} {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at)
values ($1, $2, $3, '1', 'buy', $4, $5, $6)`,
			asset, subID, price,
			fmt.Sprintf("%s-taker-%d", suffix, i), fmt.Sprintf("%s-maker-%d", suffix, i),
			base.Add(time.Duration(i)*time.Minute),
		); err != nil {
			t.Fatalf("insert %s: %v", price, err)
		}
	}

	hourly, _ := ParseCandleInterval("1h")
	candles, err := repo.ListCandles(ctx, asset, subID, hourly, base.Add(-time.Hour), base.Add(time.Hour), 10)
	if err != nil {
		t.Fatalf("list candles: %v", err)
	}
	if len(candles) != 1 {
		t.Fatalf("got %d candles, want 1", len(candles))
	}
	if candles[0].High != "10" {
		t.Errorf("high = %s, want 10 (numeric max)", candles[0].High)
	}
	if candles[0].Low != "0.0007" {
		t.Errorf("low = %s, want 0.0007 (numeric min)", candles[0].Low)
	}
	if candles[0].Open != "9" || candles[0].Close != "0.00071" {
		t.Errorf("open/close = %s/%s, want 9/0.00071 (time-ordered)", candles[0].Open, candles[0].Close)
	}
}

func TestListCandlesRespectsLimitKeepingMostRecent(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()

	suffix := fmt.Sprintf("it-candles-limit-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000000c3"
	subID := "0"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1", suffix+"%")
	})

	base := time.Date(2026, 3, 4, 0, 0, 0, 0, time.UTC)
	for i := 0; i < 5; i++ {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at)
values ($1, $2, $3, '1', 'buy', $4, $5, $6)`,
			asset, subID, fmt.Sprintf("%d", 1000+i),
			fmt.Sprintf("%s-taker-%d", suffix, i), fmt.Sprintf("%s-maker-%d", suffix, i),
			base.Add(time.Duration(i)*time.Hour),
		); err != nil {
			t.Fatalf("insert %d: %v", i, err)
		}
	}

	hourly, _ := ParseCandleInterval("1h")
	candles, err := repo.ListCandles(ctx, asset, subID, hourly, time.Time{}, time.Time{}, 2)
	if err != nil {
		t.Fatalf("list candles: %v", err)
	}
	if len(candles) != 2 {
		t.Fatalf("got %d candles, want 2", len(candles))
	}
	// Most recent two, still oldest-first.
	if candles[0].Close != "1003" || candles[1].Close != "1004" {
		t.Fatalf("got closes %s,%s want 1003,1004 (newest buckets, ascending)",
			candles[0].Close, candles[1].Close)
	}
}
