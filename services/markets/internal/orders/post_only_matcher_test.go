package orders

import (
	"testing"
	"time"
)

func postOnlyOrder(id string, side Side, priceTicks string, createdAt time.Time) Order {
	o := mkOrder(id, side, priceTicks, createdAt)
	o.PostOnly = true
	return o
}

var (
	earlier = time.Date(2026, 9, 12, 3, 0, 0, 0, time.UTC)
	later   = earlier.Add(time.Minute)
)

// The guarantee the flag's name makes. Submit-time rejection evaluates against the book as it was,
// so a crossing order committing concurrently can still leave a post-only order resting where it
// takes. The matcher is what makes "post only" true rather than "usually post only".
func TestAPostOnlyTakerIsRefused(t *testing.T) {
	// The bid was created later, so chooseTakerMaker makes it the taker.
	bids := []Order{postOnlyOrder("bid", SideBuy, "1382", later)}
	asks := []Order{mkOrder("ask", SideSell, "1378", earlier)}

	taker, maker, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker != nil || maker != nil {
		t.Fatalf("matched %s/%s; the taker was post-only and must not aggress",
			taker.OrderID, maker.OrderID)
	}
}

// The other half of the promise: post-only restricts aggressing, not resting. An order that rests
// must still be takeable, or the flag would remove liquidity instead of protecting it.
func TestAPostOnlyMakerIsStillTakeable(t *testing.T) {
	// The ask was created later, so the ASK is the taker and it is not post-only.
	bids := []Order{postOnlyOrder("bid", SideBuy, "1382", earlier)}
	asks := []Order{mkOrder("ask", SideSell, "1378", later)}

	taker, maker, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker == nil || maker == nil {
		t.Fatal("a post-only order must still be takeable when it is the resting side")
	}
	if taker.OrderID != "ask" || maker.OrderID != "bid" {
		t.Fatalf("taker=%s maker=%s, want the later ask taking from the resting post-only bid",
			taker.OrderID, maker.OrderID)
	}
}

// Refusing a pair must not abandon the bid. The price ordering argument that justifies `break`
// is about price, and this rejection is not -- a later ask can pair with the same bid.
func TestARefusedPostOnlyPairDoesNotSkipLaterAsks(t *testing.T) {
	// Both asks cross the bid. The first would make the post-only bid the taker; the second was
	// created later, so it becomes the taker itself and is fine.
	bids := []Order{postOnlyOrder("bid", SideBuy, "1382", later)}
	asks := []Order{
		mkOrder("ask-early", SideSell, "1378", earlier),
		mkOrder("ask-late", SideSell, "1379", later.Add(time.Second)),
	}

	taker, maker, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker == nil {
		t.Fatal("the second ask crosses and can legitimately take; the bid was abandoned")
	}
	if taker.OrderID != "ask-late" || maker.OrderID != "bid" {
		t.Fatalf("taker=%s maker=%s, want ask-late taking from the post-only bid", taker.OrderID, maker.OrderID)
	}
}

// Two post-only orders that cross cannot trade with each other at all -- whichever is the taker is
// refused. They rest until one is cancelled or repriced.
func TestTwoPostOnlyOrdersDoNotTrade(t *testing.T) {
	bids := []Order{postOnlyOrder("bid", SideBuy, "1382", earlier)}
	asks := []Order{postOnlyOrder("ask", SideSell, "1378", later)}

	taker, maker, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker != nil {
		t.Fatalf("matched %s/%s; both sides were post-only", taker.OrderID, maker.OrderID)
	}
}

// Ordinary orders are untouched.
func TestOrdinaryOrdersStillMatch(t *testing.T) {
	bids := []Order{mkOrder("bid", SideBuy, "1382", later)}
	asks := []Order{mkOrder("ask", SideSell, "1378", earlier)}

	taker, maker, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker == nil || taker.OrderID != "bid" || maker.OrderID != "ask" {
		t.Fatal("an ordinary crossing pair must still match")
	}
}
