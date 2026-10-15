package matching

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

func pairOf(takerID, takerAccount, makerID, makerAccount string) orders.MatchCandidate {
	return orders.MatchCandidate{
		Taker: orders.Order{OrderID: takerID, SubaccountID: takerAccount},
		Maker: orders.Order{OrderID: makerID, SubaccountID: makerAccount},
	}
}

// One bad taker walking the book parks against each quote in turn: it is the order every failure
// shares, so it reaches the limit first and the quotes are untouched.
func TestParkTrackerCancelsTheOrderEveryFailureShares(t *testing.T) {
	p := newParkTracker()
	if due := p.record(pairOf("bad", "66", "q1", "34")); due != nil {
		t.Fatalf("first park: %v", due)
	}
	if due := p.record(pairOf("bad", "66", "q2", "35")); due != nil {
		t.Fatalf("second park: %v", due)
	}
	if due := p.record(pairOf("bad", "66", "q3", "36")); !equalStrings(due, []string{"taker"}) {
		t.Fatalf("third park: %v, want the taker", due)
	}
}

// A resting quote is cancelled only once orders from three distinct accounts have parked against it;
// many orders from one account count once.
func TestParkTrackerCountsAccountsNotOrders(t *testing.T) {
	p := newParkTracker()
	for i, order := range []string{"a1", "a2", "a3", "a4"} {
		if due := p.record(pairOf(order, "66", "quote", "34")); len(due) > 0 {
			t.Fatalf("park %d from one account: %v", i, due)
		}
	}
	p.record(pairOf("b1", "67", "quote", "34"))
	if due := p.record(pairOf("c1", "68", "quote", "34")); !equalStrings(due, []string{"maker"}) {
		t.Fatalf("third account: %v, want the maker", due)
	}
	p.forget("quote")
	if due := p.record(pairOf("d1", "69", "quote", "34")); len(due) > 0 {
		t.Fatalf("after forget: %v", due)
	}
}

func TestParkTrackerForgetsAfterTheTTL(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	p := newParkTracker()
	p.now = func() time.Time { return now }
	p.record(pairOf("bad", "66", "q1", "34"))
	p.record(pairOf("bad", "66", "q2", "35"))
	now = now.Add(parkTrackTTL + time.Minute)
	if due := p.record(pairOf("bad", "66", "q3", "36")); len(due) > 0 {
		t.Fatalf("after the TTL: %v", due)
	}
}

// The switch to a fixed unit cancels a handful; ten in an hour posts once, with the counts, and not
// again within the hour.
func TestVenueCancelAlertPostsOnAStream(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	var mu sync.Mutex
	var posts []string
	a := newVenueCancelAlerter("https://hooks.example/alert")
	a.now = func() time.Time { return now }
	a.post = func(_ context.Context, _, text string) error {
		mu.Lock()
		defer mu.Unlock()
		posts = append(posts, text)
		return nil
	}
	sent := func() []string {
		time.Sleep(20 * time.Millisecond)
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), posts...)
	}

	for range cancelAlertThreshold - 1 {
		a.Cancelled("USDC-cNGN-30NOV26", CancelReasonUnmatchable)
		now = now.Add(time.Minute)
	}
	if got := sent(); len(got) != 0 {
		t.Fatalf("below the threshold: %v", got)
	}
	a.Cancelled("cNGN-USDC", CancelReasonRepeatedPermanentRevert)
	got := sent()
	if len(got) != 1 || !strings.Contains(got[0], "10 orders") ||
		!strings.Contains(got[0], "USDC-cNGN-30NOV26 unmatchable_signed_order: 9") ||
		!strings.Contains(got[0], "cNGN-USDC repeated_permanent_revert: 1") {
		t.Fatalf("posts %q", got)
	}
	a.Cancelled("cNGN-USDC", CancelReasonUnmatchable)
	if got := sent(); len(got) != 1 {
		t.Fatalf("posted again within the hour: %d", len(got))
	}

	// An hour on, the old cancels have aged out: a quiet hour posts nothing.
	now = now.Add(2 * cancelAlertWindow)
	a.Cancelled("cNGN-USDC", CancelReasonUnmatchable)
	if got := sent(); len(got) != 1 {
		t.Fatalf("posted after a quiet hour: %d", len(got))
	}
}
