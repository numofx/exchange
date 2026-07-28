package matching

import (
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

func testPair() (orders.Order, orders.Order) {
	return orders.Order{OrderID: "taker-1"}, orders.Order{OrderID: "maker-1"}
}

func TestMatchBackoffSkipsUntilWindowElapses(t *testing.T) {
	now := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }

	taker, maker := testPair()

	if b.shouldSkip(taker, maker) {
		t.Fatal("a pair with no failures must not be skipped")
	}

	attempts, retryIn := b.recordFailure(taker, maker)
	if attempts != 1 || retryIn != matchBackoffBase {
		t.Fatalf("first failure = (%d, %s), want (1, %s)", attempts, retryIn, matchBackoffBase)
	}
	if !b.shouldSkip(taker, maker) {
		t.Fatal("pair must be skipped inside its backoff window")
	}

	now = now.Add(matchBackoffBase - time.Millisecond)
	if !b.shouldSkip(taker, maker) {
		t.Fatal("pair must still be skipped just before the window elapses")
	}

	now = now.Add(2 * time.Millisecond)
	if b.shouldSkip(taker, maker) {
		t.Fatal("pair must be retried once the window elapses")
	}
}

func TestMatchBackoffDoublesAndCaps(t *testing.T) {
	now := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }
	taker, maker := testPair()

	var last time.Duration
	for i := 1; i <= 20; i++ {
		_, retryIn := b.recordFailure(taker, maker)
		if retryIn > matchBackoffCap {
			t.Fatalf("failure %d: retryIn %s exceeds cap %s", i, retryIn, matchBackoffCap)
		}
		if retryIn <= 0 {
			t.Fatalf("failure %d: non-positive retryIn %s (shift overflow?)", i, retryIn)
		}
		if i > 1 && retryIn < last {
			t.Fatalf("failure %d: retryIn shrank from %s to %s", i, last, retryIn)
		}
		last = retryIn
	}
	if last != matchBackoffCap {
		t.Fatalf("sustained failures settled at %s, want the cap %s", last, matchBackoffCap)
	}
}

func TestMatchBackoffClearResetsTheWindow(t *testing.T) {
	now := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }
	taker, maker := testPair()

	for i := 0; i < 5; i++ {
		b.recordFailure(taker, maker)
	}
	b.clear(taker, maker)

	if b.shouldSkip(taker, maker) {
		t.Fatal("a cleared pair must not be skipped")
	}
	if _, retryIn := b.recordFailure(taker, maker); retryIn != matchBackoffBase {
		t.Fatalf("after clear, first failure retryIn = %s, want %s", retryIn, matchBackoffBase)
	}
}

func TestMatchBackoffKeyIgnoresTakerMakerOrder(t *testing.T) {
	now := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }
	taker, maker := testPair()

	b.recordFailure(taker, maker)
	// Roles swap between ticks as orders are re-timestamped; the same two orders
	// must still be recognised as the same pair.
	if !b.shouldSkip(maker, taker) {
		t.Fatal("pair must be recognised with taker and maker swapped")
	}
}

// The point of the whole mechanism: bound how many times an unsettleable cross
// is retried over the lifetime of a resting order.
func TestMatchBackoffBoundsRetriesOverAnHour(t *testing.T) {
	now := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }
	taker, maker := testPair()

	const pollInterval = 250 * time.Millisecond
	deadline := now.Add(time.Hour)

	attempts := 0
	for now.Before(deadline) {
		if !b.shouldSkip(taker, maker) {
			attempts++
			b.recordFailure(taker, maker)
		}
		now = now.Add(pollInterval)
	}

	// Without backoff this is 3600s / 0.25s = 14,400 attempts.
	if attempts > 40 {
		t.Fatalf("unsettleable pair retried %d times in an hour, want well under 40", attempts)
	}
	t.Logf("retries in one hour: %d (unbounded would be %d)", attempts, int(time.Hour/pollInterval))
}

func TestMatchBackoffPrunesStaleEntries(t *testing.T) {
	now := time.Date(2026, 7, 28, 12, 0, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }

	b.recordFailure(orders.Order{OrderID: "old-taker"}, orders.Order{OrderID: "old-maker"})

	now = now.Add(matchBackoffTTL + time.Hour)
	b.recordFailure(orders.Order{OrderID: "new-taker"}, orders.Order{OrderID: "new-maker"})

	b.mu.Lock()
	size := len(b.state)
	b.mu.Unlock()
	if size != 1 {
		t.Fatalf("state holds %d entries, want 1 (stale entry must be pruned)", size)
	}
}
