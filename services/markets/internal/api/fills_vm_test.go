package api

import (
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// Account #35's fills on 2026-10-15, against the mark 1381.417182 they settled at: the 116 USDC sell at
// 1379.127560 was charged 265.5961 cNGN on chain (the chain's mark has more places than this one), and the 14 USDC buy at 1383.271303 25.9577 cNGN.
func TestFillVMIsTheGapToTheMarkTimesTheNotional(t *testing.T) {
	meta := instruments.Metadata{AmountScale: instruments.FutureAmountScale, ContractMultiplier: instruments.FutureContractSizeUSDC}
	cases := []struct {
		side              orders.Side
		price, size, mark string
		want              string
	}{
		{orders.SideSell, "1379.127560355392006386", "116", "1381.417182", "-265.596110774527259224"},
		{orders.SideBuy, "1383.271303026005853098", "14", "1381.417182", "-25.957694364081943372"},
		// The maker on the other side of the sell gains what the taker paid.
		{orders.SideBuy, "1379.127560355392006386", "116", "1381.417182", "265.596110774527259224"},
		{orders.SideBuy, "1381.417182", "500", "1381.417182", "0"},
	}
	for _, c := range cases {
		if got := fillVM(meta, c.side, c.price, c.size, c.mark); got != c.want {
			t.Fatalf("%s %s at %s against %s: vm %q, want %q", c.side, c.size, c.price, c.mark, got, c.want)
		}
	}
	if got := fillVM(meta, orders.SideBuy, "1381", "1", "not a number"); got != "" {
		t.Fatalf("an unparsable mark gives %q, want empty", got)
	}
}
