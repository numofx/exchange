package matching

import (
	"math/big"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

func whole(n int64) *big.Int { return new(big.Int).Mul(big.NewInt(n), wad) }

// One contract of 1,000 USDC at a 25% IM adds 250 USD of requirement.
func TestFutureFillShortfallIsTheEngineIMTestOnTheFillAlone(t *testing.T) {
	size, rate := whole(1000), new(big.Int).Div(wad, big.NewInt(4))
	mark, index := whole(1400), whole(1400)
	open := func(surplus int64, position, delta int64, fee int64) futureSide {
		return futureSide{Surplus: whole(surplus), Position: whole(position), Delta: whole(delta), Fee: whole(fee)}
	}
	for name, tc := range map[string]struct {
		side  futureSide
		price *big.Int
		short bool
	}{
		"249 USD cannot open one contract":            {open(249, 0, 1, 0), mark, true},
		"250 USD can":                                 {open(250, 0, 1, 0), mark, false},
		"the taker's fee counts":                      {open(251, 0, 1, 2), mark, true},
		"a reduction is never refused":                {open(-100, 2, -1, 0), mark, false},
		"closing out is never refused":                {open(-100, -1, 1, 0), mark, false},
		"a flip to the same size adds no IM":          {open(0, 1, -2, 0), mark, false},
		"but is held to IM: its fee counts":           {open(1, 1, -2, 2), mark, true},
		"a flip adds only the contracts beyond":       {open(250, 1, -3, 0), mark, false},
		"a sell into a flip short of margin":          {open(249, 1, -3, 0), mark, true},
		"a buy below the mark counts its gain at par": {open(200, 0, 1, 0), whole(1330), false}, // 1000 x 70 cNGN = 50 USD at 1,400
		"a buy above the mark ignores its loss":       {open(250, 0, 1, 0), whole(1470), false},
	} {
		if short, _ := futureFillShortfall(tc.side, size, rate, tc.price, mark, index); short != tc.short {
			t.Errorf("%s: short=%v", name, short)
		}
	}
}

// Held back from every counterparty for the retry window; cancelled at the third consecutive refusal,
// and only once a minute has passed since the first; a fill or a pass starts the count again.
func TestAMarginRefusedOrderIsHeldBackThenCancelled(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	r := newFutureMarginRefusals()
	r.now = func() time.Time { return now }
	order := orders.Order{OrderID: "ask", FilledAmount: "0"}

	if _, cancel := r.refuse(order); cancel || !r.blocked(order) {
		t.Fatal("the first refusal holds the order back and does not cancel it")
	}
	now = now.Add(futureMarginRetry)
	if r.blocked(order) {
		t.Fatal("held back only for the retry window")
	}
	if _, cancel := r.refuse(order); cancel {
		t.Fatal("two refusals do not cancel")
	}
	now = now.Add(time.Second)
	if count, cancel := r.refuse(order); count != 3 || cancel {
		t.Fatalf("three refusals inside a minute do not cancel: %d %v", count, cancel)
	}
	now = now.Add(futureMarginCancelMinSpan)
	if _, cancel := r.refuse(order); !cancel {
		t.Fatal("refused again a minute after the first: cancel")
	}

	r.clear(order)
	r.refuse(order)
	if filled := (orders.Order{OrderID: "ask", FilledAmount: "1"}); r.blocked(filled) {
		t.Fatal("a fill on the order since its refusal releases it")
	}
	if count, _ := r.refuse(orders.Order{OrderID: "ask", FilledAmount: "1"}); count != 1 {
		t.Fatalf("and starts the count again: %d", count)
	}
}
