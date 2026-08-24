package orders

import (
	"testing"
	"time"
)

func mkOrder(id string, side Side, priceTicks string, createdAt time.Time) Order {
	return Order{
		OrderID:         id,
		Side:            side,
		LimitPriceTicks: priceTicks,
		CreatedAt:       createdAt,
	}
}

func gateOn(pairs ...string) MatchGate {
	blocked := map[string]bool{}
	for _, p := range pairs {
		blocked[p] = true
	}
	return func(taker Order, maker Order) bool {
		return blocked[pairKeyFor(taker, maker)]
	}
}

func pairKeyFor(taker Order, maker Order) string {
	if taker.OrderID <= maker.OrderID {
		return taker.OrderID + "|" + maker.OrderID
	}
	return maker.OrderID + "|" + taker.OrderID
}

var t0 = time.Unix(1_700_000_000, 0)

// The reason selectMatchPair exists. Before it, AcquireMatchCandidate locked exactly one order
// per side; a best bid that could not settle -- an underfunded buyer, most likely -- was gated
// every tick and the tick ended there, so nothing behind it traded for the whole backoff window.
func TestUnfundableBestBidDoesNotBlockTheNextBestBid(t *testing.T) {
	bids := []Order{
		mkOrder("bid-best", SideBuy, "110", t0), // gated: cannot fund
		mkOrder("bid-next", SideBuy, "105", t0.Add(time.Second)),
	}
	asks := []Order{
		mkOrder("ask", SideSell, "100", t0.Add(2*time.Second)),
	}

	taker, maker, err := selectMatchPair(bids, asks, gateOn("ask|bid-best"))
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker == nil {
		t.Fatal("the next-best bid crosses and is not gated, so a pair must be returned")
	}

	got := pairKeyFor(*taker, *maker)
	if got != "ask|bid-next" {
		t.Fatalf("selected %q, want the next-best bid to trade", got)
	}
}

// Priority is only given up when it has to be: a fundable best bid still trades first.
func TestBestBidKeepsPriorityWhenItCanTrade(t *testing.T) {
	bids := []Order{
		mkOrder("bid-best", SideBuy, "110", t0),
		mkOrder("bid-next", SideBuy, "105", t0.Add(time.Second)),
	}
	asks := []Order{mkOrder("ask", SideSell, "100", t0.Add(2*time.Second))}

	taker, maker, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if pairKeyFor(*taker, *maker) != "ask|bid-best" {
		t.Fatalf("selected %q, want the best bid", pairKeyFor(*taker, *maker))
	}
}

// A gated best bid must not cost the *ask* side its turn either: the bid is tried against every
// ask before the walk moves on.
func TestGatedPairFallsThroughToTheNextAsk(t *testing.T) {
	bids := []Order{mkOrder("bid", SideBuy, "110", t0)}
	asks := []Order{
		mkOrder("ask-best", SideSell, "100", t0.Add(time.Second)),
		mkOrder("ask-next", SideSell, "105", t0.Add(2*time.Second)),
	}

	taker, maker, err := selectMatchPair(bids, asks, gateOn("ask-best|bid"))
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker == nil {
		t.Fatal("the second ask still crosses this bid")
	}
	if pairKeyFor(*taker, *maker) != "ask-next|bid" {
		t.Fatalf("selected %q, want the next ask", pairKeyFor(*taker, *maker))
	}
}

// Everything gated is not the same as nothing crossing, but both mean "no trade this tick".
func TestNoPairWhenEveryCrossingPairIsGated(t *testing.T) {
	bids := []Order{
		mkOrder("bid-a", SideBuy, "110", t0),
		mkOrder("bid-b", SideBuy, "108", t0.Add(time.Second)),
	}
	asks := []Order{mkOrder("ask", SideSell, "100", t0.Add(2*time.Second))}

	taker, _, err := selectMatchPair(bids, asks, gateOn("ask|bid-a", "ask|bid-b"))
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker != nil {
		t.Fatal("every crossing pair is gated, so nothing may be reserved")
	}
}

func TestNoPairWhenBookIsUncrossed(t *testing.T) {
	bids := []Order{mkOrder("bid", SideBuy, "90", t0)}
	asks := []Order{mkOrder("ask", SideSell, "100", t0.Add(time.Second))}

	taker, _, err := selectMatchPair(bids, asks, nil)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker != nil {
		t.Fatal("an uncrossed book must not produce a pair")
	}
}

// Asks are ordered best-first, so once a bid fails to reach one ask it cannot reach any later
// one. The walk must stop scanning that bid rather than testing the whole ask side.
func TestWalkStopsScanningAsksOnceTheBidCannotReach(t *testing.T) {
	bids := []Order{mkOrder("bid", SideBuy, "95", t0)}
	asks := []Order{
		mkOrder("ask-1", SideSell, "100", t0.Add(time.Second)),
		mkOrder("ask-2", SideSell, "200", t0.Add(2*time.Second)),
		mkOrder("ask-3", SideSell, "300", t0.Add(3*time.Second)),
	}

	calls := 0
	counting := func(taker Order, maker Order) bool {
		calls++
		return false
	}

	taker, _, err := selectMatchPair(bids, asks, counting)
	if err != nil {
		t.Fatalf("selectMatchPair: %v", err)
	}
	if taker != nil {
		t.Fatal("nothing crosses")
	}
	if calls != 0 {
		t.Fatalf("gate consulted %d times; an uncrossed pair must not reach the gate", calls)
	}
}

func TestSelectMatchPairSurfacesBadPrices(t *testing.T) {
	bids := []Order{mkOrder("bid", SideBuy, "not-a-number", t0)}
	asks := []Order{mkOrder("ask", SideSell, "100", t0.Add(time.Second))}

	if _, _, err := selectMatchPair(bids, asks, nil); err == nil {
		t.Fatal("an unparseable price must be an error, not silently treated as uncrossed")
	}
}

func TestSelectMatchPairHandlesEmptySides(t *testing.T) {
	only := []Order{mkOrder("bid", SideBuy, "110", t0)}

	if taker, _, err := selectMatchPair(only, nil, nil); err != nil || taker != nil {
		t.Fatalf("empty ask side: taker=%v err=%v", taker, err)
	}
	if taker, _, err := selectMatchPair(nil, only, nil); err != nil || taker != nil {
		t.Fatalf("empty bid side: taker=%v err=%v", taker, err)
	}
}
