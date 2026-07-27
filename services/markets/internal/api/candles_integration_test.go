package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

func TestHandleCandlesReturnsRealBucketsAndValidatesParams(t *testing.T) {
	pool := openTestPool(t)
	// Not t.Context(): it is cancelled before t.Cleanup runs, so cleanup would
	// silently no-op and leak rows into the next run.
	ctx := context.Background()

	stamp := time.Now().UnixNano()
	suffix := fmt.Sprintf("api-candles-%d", stamp)
	// Unique asset per run so leftover rows from any earlier run cannot be
	// aggregated into this run's buckets. Lowercase: asset addresses are stored
	// and queried lowercased.
	asset := fmt.Sprintf("0x%040x", stamp)
	subID := "1789567201"

	t.Cleanup(func() {
		if _, err := pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1", suffix+"%"); err != nil {
			t.Errorf("cleanup trade_fills: %v", err)
		}
	})

	cfg := config.Config{
		CNGNSep2026FutureAssetAddress: asset,
		CNGNSep2026FutureSubID:        subID,
	}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))

	base := time.Date(2026, 2, 10, 12, 0, 0, 0, time.UTC)
	for i, price := range []string{"1379", "1381", "1377"} {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at)
values ($1, $2, $3, '2', 'buy', $4, $5, $6)`,
			asset, subID, price,
			fmt.Sprintf("%s-taker-%d", suffix, i), fmt.Sprintf("%s-maker-%d", suffix, i),
			base.Add(time.Duration(i)*time.Minute),
		); err != nil {
			t.Fatalf("insert %s: %v", price, err)
		}
	}

	get := func(query string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/v1/candles?asset_address="+asset+"&sub_id="+subID+query, nil)
		rec := httptest.NewRecorder()
		server.handleCandles(rec, req)
		return rec
	}

	t.Run("aggregates into one hourly bucket", func(t *testing.T) {
		rec := get("&interval=1h&start=2026-02-10T00:00:00Z&end=2026-02-11T00:00:00Z")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got candlesResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if got.Interval != "1h" {
			t.Errorf("interval = %q, want 1h", got.Interval)
		}
		if len(got.Candles) != 1 {
			t.Fatalf("got %d candles, want 1: %s", len(got.Candles), rec.Body.String())
		}
		candle := got.Candles[0]
		if candle.Open != "1379" || candle.High != "1381" || candle.Low != "1377" || candle.Close != "1377" {
			t.Errorf("OHLC = %s/%s/%s/%s, want 1379/1381/1377/1377",
				candle.Open, candle.High, candle.Low, candle.Close)
		}
		if candle.Volume != "6" || candle.TradeCount != 3 {
			t.Errorf("volume/count = %s/%d, want 6/3", candle.Volume, candle.TradeCount)
		}
		// (1379 + 1381 + 1377) * 2 = 8274
		if candle.QuoteVolume != "8274" {
			t.Errorf("quote_volume = %s, want 8274", candle.QuoteVolume)
		}
	})

	t.Run("empty range yields an empty array not null", func(t *testing.T) {
		rec := get("&start=2020-01-01T00:00:00Z&end=2020-01-02T00:00:00Z")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d", rec.Code)
		}
		var raw map[string]json.RawMessage
		_ = json.Unmarshal(rec.Body.Bytes(), &raw)
		if string(raw["candles"]) != "[]" {
			t.Errorf("candles = %s, want []", raw["candles"])
		}
	})

	t.Run("rejects bad params", func(t *testing.T) {
		for _, q := range []string{
			"&interval=7s",
			"&limit=0",
			"&limit=1001",
			"&start=not-a-time",
			"&start=2026-02-11T00:00:00Z&end=2026-02-10T00:00:00Z",
		} {
			if rec := get(q); rec.Code != http.StatusBadRequest {
				t.Errorf("%s -> status %d, want 400", q, rec.Code)
			}
		}
	})

	t.Run("defaults to 1h when interval omitted", func(t *testing.T) {
		rec := get("")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got candlesResponse
		_ = json.Unmarshal(rec.Body.Bytes(), &got)
		if got.Interval != "1h" {
			t.Errorf("default interval = %q, want 1h", got.Interval)
		}
	})
}
