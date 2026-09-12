package orders

import (
	"math/big"
	"testing"
)

func ticks(v string) *big.Int {
	n, ok := new(big.Int).SetString(v, 10)
	if !ok {
		panic("bad ticks " + v)
	}
	return n
}

// crossCases is the table the SQL, the Go helper and the matcher must all agree on. The
// integration test replays it against a real database; this one pins the Go side so a change to
// the rule shows up in CI even where no database is available.
var crossCases = []struct {
	name    string
	side    Side
	ticks   string
	opp     string
	crosses bool
}{
	// The equal-price case is the one worth being explicit about: an order at exactly the
	// opposing top of book DOES trade -- Crosses() compares >= and <=, not > and <. A post-only
	// order priced there must be refused, not rested.
	{"buy at the ask crosses", SideBuy, "1380", "1380", true},
	{"sell at the bid crosses", SideSell, "1380", "1380", true},

	{"buy above the ask crosses", SideBuy, "1382", "1378", true},
	{"buy below the ask rests", SideBuy, "1377", "1378", false},
	{"sell below the bid crosses", SideSell, "1378", "1382", true},
	{"sell above the bid rests", SideSell, "1383", "1382", false},

	// Ticks are 1e18-scaled integers well beyond int64, so the comparison must stay big.Int.
	{"huge ticks compare exactly", SideBuy,
		"1000000000000000000000000000000000001", "1000000000000000000000000000000000000", true},
	{"huge ticks one below rests", SideBuy,
		"999999999999999999999999999999999999", "1000000000000000000000000000000000000", false},
}

func TestWouldCrossMatchesTheMatchersRule(t *testing.T) {
	for _, tc := range crossCases {
		t.Run(tc.name, func(t *testing.T) {
			if got := WouldCross(tc.side, ticks(tc.ticks), ticks(tc.opp)); got != tc.crosses {
				t.Fatalf("WouldCross(%s, %s, %s) = %v, want %v", tc.side, tc.ticks, tc.opp, got, tc.crosses)
			}

			// And the same case through Crosses(), which is what the matcher actually calls. If
			// these two ever disagree, post_only promises something the venue does not honour:
			// an order accepted as "will rest" that the matcher then makes the taker.
			incoming := Order{Side: tc.side, LimitPriceTicks: tc.ticks}
			opposite := Order{Side: otherSide(tc.side), LimitPriceTicks: tc.opp}
			matcherSays, err := Crosses(incoming, opposite)
			if err != nil {
				t.Fatalf("Crosses: %v", err)
			}
			if matcherSays != tc.crosses {
				t.Fatalf("Crosses says %v but the post-only rule says %v -- the two have drifted",
					matcherSays, tc.crosses)
			}
		})
	}
}

func otherSide(s Side) Side {
	if s == SideBuy {
		return SideSell
	}
	return SideBuy
}

// An empty book cannot be crossed, so a post-only order must always be accepted against one.
func TestNothingCrossesAnEmptyBook(t *testing.T) {
	if WouldCross(SideBuy, ticks("1380"), nil) {
		t.Fatal("a buy crossed a book with no asks")
	}
	if WouldCross(SideSell, ticks("1380"), nil) {
		t.Fatal("a sell crossed a book with no bids")
	}
}
