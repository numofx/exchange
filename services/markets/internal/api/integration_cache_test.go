package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

func TestIntegrationCacheBoundsComputations(t *testing.T) {
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	var calls atomic.Int64
	status := http.StatusOK
	handler := func(w http.ResponseWriter, r *http.Request) {
		n := calls.Add(1)
		writeJSON(w, status, map[string]any{"call": n, "ticker_id": r.URL.Query().Get("ticker_id")})
	}
	serve := func(cache *integrationCache, target string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		cache.wrap(handler, "ticker_id", "depth")(rec, httptest.NewRequest(http.MethodGet, target, nil))
		return rec
	}

	t.Run("repeat requests within the TTL compute once, then refresh after it", func(t *testing.T) {
		calls.Store(0)
		cache := newIntegrationCache(5*time.Second, clock.Now)
		first := serve(cache, "/x?ticker_id=A")
		clock.Advance(4999 * time.Millisecond)
		second := serve(cache, "/x?ticker_id=A")
		if calls.Load() != 1 || first.Body.String() != second.Body.String() {
			t.Fatalf("calls=%d; bodies %q vs %q", calls.Load(), first.Body.String(), second.Body.String())
		}
		if got := second.Header().Get("Cache-Control"); got != "public, max-age=5" {
			t.Errorf("Cache-Control = %q", got)
		}
		clock.Advance(time.Millisecond)
		serve(cache, "/x?ticker_id=A")
		if calls.Load() != 2 {
			t.Fatalf("calls after TTL = %d, want 2", calls.Load())
		}
	})

	t.Run("parameters the endpoint reads split the key; any others cannot bust it", func(t *testing.T) {
		calls.Store(0)
		cache := newIntegrationCache(5*time.Second, clock.Now)
		serve(cache, "/x?ticker_id=A&depth=10")
		serve(cache, "/x?depth=10&ticker_id=A&nonce=1")
		serve(cache, "/x?ticker_id=A&depth=10&nonce=2&_=3")
		if calls.Load() != 1 {
			t.Fatalf("unread parameters produced %d computations, want 1", calls.Load())
		}
		serve(cache, "/x?ticker_id=A&depth=20")
		serve(cache, "/x?ticker_id=B&depth=10")
		if calls.Load() != 3 {
			t.Fatalf("distinct read parameters produced %d computations, want 3", calls.Load())
		}
	})

	t.Run("errors are not cached", func(t *testing.T) {
		calls.Store(0)
		status = http.StatusInternalServerError
		defer func() { status = http.StatusOK }()
		cache := newIntegrationCache(5*time.Second, clock.Now)
		if rec := serve(cache, "/x?ticker_id=A"); rec.Code != http.StatusInternalServerError || rec.Header().Get("Cache-Control") != "" {
			t.Fatalf("status=%d cache-control=%q", rec.Code, rec.Header().Get("Cache-Control"))
		}
		serve(cache, "/x?ticker_id=A")
		if calls.Load() != 2 {
			t.Fatalf("calls = %d, want 2", calls.Load())
		}
	})

	t.Run("a burst of concurrent misses shares one computation", func(t *testing.T) {
		var burstCalls atomic.Int64
		release := make(chan struct{})
		slow := func(w http.ResponseWriter, _ *http.Request) {
			burstCalls.Add(1)
			<-release
			writeJSON(w, http.StatusOK, map[string]string{"ok": "1"})
		}
		cache := newIntegrationCache(5*time.Second, clock.Now)
		wrapped := cache.wrap(slow, "ticker_id")

		var wg sync.WaitGroup
		for range 50 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				rec := httptest.NewRecorder()
				wrapped(rec, httptest.NewRequest(http.MethodGet, "/x?ticker_id=A", nil))
				if rec.Code != http.StatusOK {
					t.Errorf("status = %d", rec.Code)
				}
			}()
		}
		time.Sleep(50 * time.Millisecond) // let the goroutines reach the flight before releasing it
		close(release)
		wg.Wait()
		if burstCalls.Load() != 1 {
			t.Fatalf("50 concurrent requests ran the handler %d times, want 1", burstCalls.Load())
		}
	})

	t.Run("a full cache still serves, without evicting fresh entries", func(t *testing.T) {
		calls.Store(0)
		cache := newIntegrationCache(5*time.Second, clock.Now)
		cache.maxEntries = 2
		serve(cache, "/x?ticker_id=A")
		serve(cache, "/x?ticker_id=B")
		if rec := serve(cache, "/x?ticker_id=C"); rec.Code != http.StatusOK {
			t.Fatalf("status = %d", rec.Code)
		}
		serve(cache, "/x?ticker_id=A")
		if calls.Load() != 3 {
			t.Fatalf("calls = %d, want 3 (A still cached, C served uncached)", calls.Load())
		}
		clock.Advance(5 * time.Second)
		serve(cache, "/x?ticker_id=C")
		cache.mu.Lock()
		size := len(cache.entries)
		cache.mu.Unlock()
		if size != 1 {
			t.Fatalf("expired entries were not swept: %d entries", size)
		}
	})
}

// Drives the real router, so this fails if the cache is built but not in front of the route.
func TestIntegrationRoutesServeThroughTheCache(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	stamp := time.Now().UnixNano()
	asset := fmt.Sprintf("0x%040x", stamp)
	t.Cleanup(func() {
		if _, err := pool.Exec(ctx, "delete from active_orders where asset_address = $1", asset); err != nil {
			t.Errorf("cleanup active_orders: %v", err)
		}
	})

	insert := func(i int, price, ticks string) {
		t.Helper()
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, '0xowner', '0xowner', 6, 6, $2, 'sell', $3, '0', '2000', '0', $4, $5, '0', $6, '{}'::jsonb, '0xsig', 'active')`,
			fmt.Sprintf("cache-route-%d-%d", stamp, i), fmt.Sprintf("%d%02d", stamp, i), asset, price, ticks,
			time.Now().Add(time.Hour).Unix(),
		); err != nil {
			t.Fatalf("insert order: %v", err)
		}
	}

	cfg := config.Config{CNGNSpotAssetAddress: asset}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	clock := &fakeClock{now: time.Unix(1_800_000_000, 0)}
	router := server.routes(newIntegrationCache(5*time.Second, clock.Now))
	bids := func() []integrationLevel {
		t.Helper()
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/v1/integrations/orderbook?ticker_id=USDCcNGN-SPOT", nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got integrationOrderbookResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		return got.Bids
	}

	insert(0, "0.0005", "500000000000000")
	before := []integrationLevel{{"2000", "1"}}
	if got := bids(); !reflect.DeepEqual(got, before) {
		t.Fatalf("first read = %v, want %v", got, before)
	}

	// A new best bid lands in the database; within the TTL the route must not see it.
	insert(1, "0.0004", "400000000000000")
	clock.Advance(4 * time.Second)
	if got := bids(); !reflect.DeepEqual(got, before) {
		t.Fatalf("read within TTL = %v, want the cached %v", got, before)
	}

	clock.Advance(time.Second)
	after := []integrationLevel{{"2500", "0.8"}, {"2000", "1"}}
	if got := bids(); !reflect.DeepEqual(got, after) {
		t.Fatalf("read after TTL = %v, want %v", got, after)
	}
}
