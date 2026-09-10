package matching

import (
	"math/big"
	"testing"
)

// 25 bps of a 100 USDC notional is 0.25 USDC. Everything here is 18dp wei.
const (
	e18       = "1000000000000000000"
	price1280 = "781250000000000" // 1/1280 USDC per cNGN
)

func TestTakerFillFeeIsBpsOfNotional(t *testing.T) {
	// 1280 cNGN at 1/1280 USDC each = 1 USDC notional. 25 bps of that is 0.0025 USDC.
	fee, err := takerFillFee(25, price1280, "1280000000000000000000")
	if err != nil {
		t.Fatal(err)
	}
	if fee != "2500000000000000" {
		t.Fatalf("25 bps of 1 USDC must be 0.0025 USDC (2.5e15 wei), got %s", fee)
	}
}

func TestZeroBpsChargesNothing(t *testing.T) {
	fee, err := takerFillFee(0, price1280, "1280000000000000000000")
	if err != nil {
		t.Fatal(err)
	}
	if fee != "0" {
		t.Fatalf("a zero schedule must charge nothing, got %s", fee)
	}
}

func TestNegativeBpsIsRejected(t *testing.T) {
	if _, err := takerFillFee(-1, price1280, e18); err == nil {
		t.Fatal("a negative fee tier must be rejected, not silently paid to the taker")
	}
}

// The bound TradeModule enforces is PER UNIT FILLED, not on the total. Comparing the total
// against worstFee directly would reject almost every legitimate fill.
func TestWorstFeeCoversComparesPerUnitNotTotal(t *testing.T) {
	amount := "1280000000000000000000" // 1280 cNGN
	fee, err := takerFillFee(25, price1280, amount)
	if err != nil {
		t.Fatal(err)
	}

	// A 30 bps ceiling, expressed per cNGN as the UI signs it: rate / uiPrice = 0.003/1280.
	perUnit := new(big.Int)
	perUnit.SetString("2343750000000", 10) // 0.003 / 1280, 18dp
	covers, err := worstFeeCovers(perUnit.String(), amount, fee)
	if err != nil {
		t.Fatal(err)
	}
	if !covers {
		t.Fatalf("a 30 bps ceiling must admit a 25 bps fee (fee=%s budget=%s)", fee, perUnit)
	}

	// The same total compared naively against the per-unit bound would look enormous.
	feeInt, _ := new(big.Int).SetString(fee, 10)
	if feeInt.Cmp(perUnit) <= 0 {
		t.Fatal("guard: this test is meaningless unless the total exceeds the per-unit bound")
	}
}

// The case the cutover creates: orders signed under the old 5 bps ceiling cannot pay 25 bps.
func TestWorstFeeBelowScheduleIsNotCovered(t *testing.T) {
	amount := "1280000000000000000000"
	fee, err := takerFillFee(25, price1280, amount)
	if err != nil {
		t.Fatal(err)
	}
	// 5 bps per cNGN: 0.0005 / 1280.
	covers, err := worstFeeCovers("390625000000", amount, fee)
	if err != nil {
		t.Fatal(err)
	}
	if covers {
		t.Fatal("a 5 bps ceiling must NOT admit a 25 bps fee — this is the TM_FeeTooHigh case")
	}
}

// A ceiling of exactly the schedule is admissible: TradeModule reverts on >, not >=.
func TestWorstFeeExactlyAtScheduleIsCovered(t *testing.T) {
	amount := "1280000000000000000000"
	fee, err := takerFillFee(25, price1280, amount)
	if err != nil {
		t.Fatal(err)
	}
	covers, err := worstFeeCovers("1953125000000", amount, fee) // 0.0025 / 1280
	if err != nil {
		t.Fatal(err)
	}
	if !covers {
		t.Fatalf("a ceiling equal to the schedule must be admissible (fee=%s)", fee)
	}
}

func TestFeeAndReservationAreTheSameNumber(t *testing.T) {
	// The property the old constant existed to guarantee: what the buyer is checked against is
	// what reaches the chain.
	price, amount := price1280, "1280000000000000000000"
	fee, err := takerFillFee(25, price, amount)
	if err != nil {
		t.Fatal(err)
	}
	required, err := requiredQuote(price, amount, fee)
	if err != nil {
		t.Fatal(err)
	}
	notional, err := requiredQuote(price, amount, "0")
	if err != nil {
		t.Fatal(err)
	}
	feeInt, _ := new(big.Int).SetString(fee, 10)
	if new(big.Int).Sub(required, notional).Cmp(feeInt) != 0 {
		t.Fatalf("the reservation must exceed notional by exactly the fee: %s vs %s", required, notional)
	}
}
