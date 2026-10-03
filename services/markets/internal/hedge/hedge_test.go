package hedge

import (
	"math/big"
	"strings"
	"testing"
)

func cngn(whole int64) *big.Int { return new(big.Int).Mul(big.NewInt(whole), e18) }

func TestNoCngnMeansNoRule(t *testing.T) {
	if err := Check(big.NewInt(0), cngn(0), cngn(5_000_000), nil); err != nil {
		t.Fatalf("a USDC-margined account trades long naira freely: %v", err)
	}
	if err := Check(nil, cngn(0), cngn(5_000_000), nil); err != nil {
		t.Fatal(err)
	}
}

func TestLongUsdUpToOneForOne(t *testing.T) {
	if err := Check(cngn(10_000_000), cngn(0), cngn(-10_000_000), nil); err != nil {
		t.Fatalf("exactly 1:1 is allowed: %v", err)
	}
	err := Check(cngn(10_000_000), cngn(-4_000_000), cngn(-7_000_000), nil)
	if err == nil || !strings.Contains(err.Error(), "cngn_margin_hedge") {
		t.Fatalf("11M short on 10M cNGN must be refused as over the hedge: %v", err)
	}
	if !strings.Contains(err.Error(), "11000000 cNGN") {
		t.Fatalf("the message names the resulting notional: %v", err)
	}
}

func TestRestingOrdersOnlyTightenTheRule(t *testing.T) {
	// 9M of long USD resting: 1M more fits, 2M does not.
	if err := Check(cngn(10_000_000), cngn(0), cngn(-1_000_000), cngn(-9_000_000)); err != nil {
		t.Fatalf("resting 9M + 1M fits: %v", err)
	}
	if err := Check(cngn(10_000_000), cngn(0), cngn(-2_000_000), cngn(-9_000_000)); err == nil {
		t.Fatal("resting 9M + 2M is over the hedge")
	}
	// A resting long-USD order does not license long naira: it is not a position and may be cancelled.
	err := Check(cngn(10_000_000), cngn(0), cngn(1_000_000), cngn(-9_000_000))
	if err == nil || !strings.Contains(err.Error(), "cngn_margin_direction") {
		t.Fatalf("long naira against a resting short must still be refused: %v", err)
	}
	// Resting long-naira orders (reductions of a real short) do not loosen the bound either.
	if err := Check(cngn(10_000_000), cngn(-10_000_000), cngn(-1), cngn(5_000_000)); err == nil {
		t.Fatal("a resting reduction does not make room for more long USD")
	}
}

func TestLongNairaIsRefusedAndOnlyReductionsPass(t *testing.T) {
	err := Check(cngn(10_000_000), cngn(0), cngn(1), nil)
	if err == nil || !strings.Contains(err.Error(), "cngn_margin_direction") {
		t.Fatalf("opening long naira on cNGN must be refused: %v", err)
	}
	if err := Check(cngn(10_000_000), cngn(-5_000_000), cngn(5_000_000), nil); err != nil {
		t.Fatalf("closing the long-USD position to zero is a reduction: %v", err)
	}
	if err := Check(cngn(10_000_000), cngn(-5_000_000), cngn(2_000_000), nil); err != nil {
		t.Fatalf("a partial reduction is allowed: %v", err)
	}
	err = Check(cngn(10_000_000), cngn(-5_000_000), cngn(6_000_000), nil)
	if err == nil || !strings.Contains(err.Error(), "cngn_margin_direction") {
		t.Fatalf("flipping through zero to long naira must be refused: %v", err)
	}
	// A long-naira position that predates the cNGN (deposited after) may be reduced, not grown.
	if err := Check(cngn(1_000_000), cngn(3_000_000), cngn(-1_000_000), nil); err != nil {
		t.Fatalf("reducing an existing long-naira position is allowed: %v", err)
	}
	if err := Check(cngn(1_000_000), cngn(3_000_000), cngn(1), nil); err == nil {
		t.Fatal("growing an existing long-naira position must be refused")
	}
}
