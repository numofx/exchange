package matching

import (
	"context"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// EURC-USDC is checked exactly like cNGN-USDC: the buyer must hold notional + taker fee in the process-wide quote
// asset, the fee from EURC-USDC's own schedule. 100 EURC at 1.12 USDC is 112 USDC; 25 bps of it is 0.28 USDC.
func TestEURCSpotBuyerIsCheckedForUSDCNotionalPlusItsFee(t *testing.T) {
	eurc, ok := instruments.DefaultRegistry(config.Config{EURCSpotAssetAddress: "0x00000000000000000000000000000000000e0dc0"}).Resolve(instruments.EURCSpotSymbol)
	if !ok {
		t.Fatal("EURC-USDC not listed")
	}
	// The engine's switch: neither perp nor future, so the spot funding check is the one that runs.
	if eurc.IsPerpetual() || eurc.IsFuture() {
		t.Fatalf("EURC-USDC contract type %q would skip the spot funding check", eurc.ContractType)
	}

	const price, amount = "1120000000000000000", "100000000000000000000"
	fee, err := takerFillFee(eurc.TakerFeeBps, price, amount)
	if err != nil {
		t.Fatal(err)
	}
	if fee != "280000000000000000" {
		t.Fatalf("fee = %s, want 0.28 USDC (2.8e17)", fee)
	}

	candidate := candidateWithBuyer(orders.SideBuy, "11", "22")
	short := &stubChecker{balance: "112279999999999999999"}
	if ok, required, _, err := buyerCanFund(context.Background(), short, candidate, price, amount, fee); err != nil || ok || required.String() != "112280000000000000000" {
		t.Fatalf("one wei short of 112.28 USDC: ok=%v required=%v err=%v", ok, required, err)
	}
	exact := &stubChecker{balance: "112280000000000000000"}
	if ok, _, _, err := buyerCanFund(context.Background(), exact, candidate, price, amount, fee); err != nil || !ok {
		t.Fatalf("exactly 112.28 USDC: ok=%v err=%v", ok, err)
	}
}
