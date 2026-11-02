package options

import (
	"math/big"
	"testing"
)

func usd(x int64) *big.Int { return new(big.Int).Mul(big.NewInt(x), oneE18) }

// A writer of 1M cNGN of an ATM put at the candidate params needs ~$250 (CngnOptionsV2Fork: 0.30 x ~$722 + MtM ~$32):
// the isolated requirement goes from 0 to -250, the premium comes in.
func TestShortfallWriter(t *testing.T) {
	writer := Leg{Surplus: usd(240), Cash: usd(240), Delta: usd(-1_000_000), CashDelta: usd(32), Fee: big.NewInt(0),
		IsoBefore: big.NewInt(0), IsoAfter: usd(-250)}
	short, reason, post := Shortfall(writer)
	if short || post.Cmp(usd(22)) != 0 {
		t.Fatalf("240 + 32 - 250 = 22 carries: short %v %s post %v", short, reason, post)
	}
	writer.Surplus = usd(200)
	if short, reason, _ := Shortfall(writer); !short || reason != "insufficient_margin" {
		t.Fatalf("200 + 32 - 250 < 0 must be short: %v %s", short, reason)
	}
}

// A buyer needs the premium and the fee in cash (borrowing off), and IM after paying them.
func TestShortfallBuyer(t *testing.T) {
	buyer := Leg{Surplus: usd(40), Cash: usd(40), Delta: usd(1_000_000), CashDelta: usd(-32), Fee: usd(1),
		IsoBefore: big.NewInt(0), IsoAfter: big.NewInt(0)}
	if short, _, post := Shortfall(buyer); short || post.Cmp(usd(7)) != 0 {
		t.Fatalf("40 - 32 - 1 = 7: short %v post %v", short, post)
	}
	buyer.Cash = usd(30)
	if short, reason, _ := Shortfall(buyer); !short || reason != "negative_cash" {
		t.Fatalf("30 of cash cannot pay 33: %v %s", short, reason)
	}
	buyer.Borrowing = true
	if short, _, _ := Shortfall(buyer); short {
		t.Fatal("with borrowing on, IM alone decides")
	}
}

// Buying back a short releases its requirement: a writer under water can always close.
func TestShortfallBuyBackReleases(t *testing.T) {
	closer := Leg{Surplus: usd(-10), Cash: usd(100), Delta: usd(1_000_000), CashDelta: usd(-40), Fee: big.NewInt(0),
		IsoBefore: usd(-250), IsoAfter: big.NewInt(0)}
	if short, _, post := Shortfall(closer); short || post.Cmp(usd(200)) != 0 {
		t.Fatalf("-10 - 40 + 250 = 200: short %v post %v", short, post)
	}
}

func TestPremium(t *testing.T) {
	price := big.NewInt(32_255_081_897_406) // the fork's ATM put, USDC per cNGN
	if got := Premium(price, usd(1_000_000)); got.String() != "32255081897406000000" {
		t.Fatalf("premium %s", got)
	}
}

func TestIntWordTwosComplement(t *testing.T) {
	if got := intWord(big.NewInt(-1)); got != "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" {
		t.Fatalf("-1 is %s", got)
	}
	if signed(new(big.Int).Sub(two256, big.NewInt(5))).Int64() != -5 {
		t.Fatal("signed(2^256-5) is -5")
	}
}
