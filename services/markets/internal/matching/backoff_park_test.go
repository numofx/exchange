package matching

import (
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

// The 2026-09-13 pair: once its revert is known to be permanent, retrying every five minutes only
// repeats it (#50). A parked pair stays skipped however much time passes.
func TestParkedPairStaysSkippedWhileNeitherOrderChanges(t *testing.T) {
	now := time.Date(2026, 9, 13, 19, 26, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }

	taker := orders.Order{OrderID: "spot-795437f5", FilledAmount: "0"}
	maker := orders.Order{OrderID: "spot-7e72d86e", FilledAmount: "1325"}

	b.park(taker, maker)

	for _, elapsed := range []time.Duration{time.Second, matchBackoffCap, 12 * time.Hour} {
		now = now.Add(elapsed)
		if !b.shouldSkip(taker, maker) {
			t.Fatalf("parked pair retried after %s with neither order changed", elapsed)
		}
	}
	if !b.shouldSkip(maker, taker) {
		t.Fatal("parking must not depend on which side is the taker")
	}
}

// Parking is about the pair as it was; a fill on either side is a different situation.
func TestParkedPairIsRetriedOnceEitherOrderChanges(t *testing.T) {
	now := time.Date(2026, 9, 13, 19, 26, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }

	taker := orders.Order{OrderID: "taker", FilledAmount: "0"}
	maker := orders.Order{OrderID: "maker", FilledAmount: "1325"}
	b.park(taker, maker)

	maker.FilledAmount = "1346"
	if b.shouldSkip(taker, maker) {
		t.Fatal("a pair whose maker filled since it was parked must be retried")
	}
	if b.shouldSkip(taker, maker) {
		t.Fatal("once retried, the stale park must be gone")
	}
}

// A failure that might clear keeps being retried, but not every five minutes for a day.
func TestRepeatedFailuresSlowToTheLongInterval(t *testing.T) {
	now := time.Date(2026, 9, 13, 19, 26, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }
	taker, maker := testPair()

	var retryIn time.Duration
	for i := 1; i <= matchSlowRetryAfter; i++ {
		_, retryIn = b.recordFailure(taker, maker)
		if i < matchSlowRetryAfter && retryIn > matchBackoffCap {
			t.Fatalf("failure %d: retry in %s, above the %s cap before the slow threshold", i, retryIn, matchBackoffCap)
		}
	}
	if retryIn != matchSlowRetryInterval {
		t.Fatalf("failure %d: retry in %s, want %s", matchSlowRetryAfter, retryIn, matchSlowRetryInterval)
	}
}

func TestParkedPairsAreForgottenAfterTheirOrdersHaveExpired(t *testing.T) {
	now := time.Date(2026, 9, 13, 19, 26, 0, 0, time.UTC)
	b := newMatchBackoff()
	b.now = func() time.Time { return now }

	stale := orders.Order{OrderID: "stale-a"}
	b.park(stale, orders.Order{OrderID: "stale-b"})

	now = now.Add(matchParkTTL + time.Minute)
	b.park(orders.Order{OrderID: "fresh-a"}, orders.Order{OrderID: "fresh-b"})

	b.mu.Lock()
	defer b.mu.Unlock()
	if _, ok := b.state[pairKey(stale, orders.Order{OrderID: "stale-b"})]; ok {
		t.Fatal("a park older than matchParkTTL must be pruned")
	}
}
