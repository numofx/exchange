package api

import (
	"context"
	"fmt"
	"math/big"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
)

// From `cast calldata "quote((uint256,uint256,bool,uint256,uint256,uint256,uint256,uint64,uint16,uint8,bytes))"`
// with the values encodeBookQuote sends: market 1, no account, deadline 1800000000, 255 levels, fee bound 2^255-1;
// a buy of one lot with limit 2^255-1, and a sell of one contract with limit 0.
const (
	castQuoteBuyLot       = "0x24bea503000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000038d7ea4c680007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000000000000000000000000000000000000000000000000000007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000000006b49d20000000000000000000000000000000000000000000000000000000000000000ff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000"
	castQuoteSellContract = "0x24bea50300000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000000000000000000000000000000000000000000000000000006b49d20000000000000000000000000000000000000000000000000000000000000000ff000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000"
)

func TestTheQuoteEncodingIsCasts(t *testing.T) {
	if got := encodeBookQuote(true, big.NewInt(bookDepthLot), 1_800_000_000); got != castQuoteBuyLot {
		t.Fatalf("buy encoding\n got %s\nwant %s", got, castQuoteBuyLot)
	}
	if got := encodeBookQuote(false, big.NewInt(1e18), 1_800_000_000); got != castQuoteSellContract {
		t.Fatalf("sell encoding\n got %s\nwant %s", got, castQuoteSellContract)
	}
}

// fakeBookChain answers markets(1) per book with that book's series, and quote() with a flat fill.
type fakeBookChain struct {
	series map[string][2]string // book -> {future, subId}
	calls  int
}

func (f *fakeBookChain) ethCall(_ context.Context, book string, data string) (string, error) {
	f.calls++
	if strings.HasPrefix(data, "0x"+selectorBookMarkets) {
		s := f.series[book]
		subID, _ := new(big.Int).SetString(s[1], 10)
		return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(s[0], "0x") + strings.Repeat("0", 64) +
			fmt.Sprintf("%064x", subID) + strings.Repeat("0", 64*10), nil
	}
	// quote: fill the asked amount at 0.000688 with a 1.03 fee
	amount, _ := new(big.Int).SetString(data[2+8+64*4:2+8+64*5], 16)
	return "0x" + fmt.Sprintf("%064x", amount) + fmt.Sprintf("%064x", big.NewInt(688_000_000_000_000)) +
		fmt.Sprintf("%064x", big.NewInt(1_030_000_000_000_000_000)) + fmt.Sprintf("%064x", 1), nil
}

func TestDepthFindsTheSeriesBookAndQuotesTheLadder(t *testing.T) {
	chain := &fakeBookChain{series: map[string][2]string{
		testEurcBook: {"0xc350243c1d07ff598770ece12323799d2efbb227", "1796050800"},
		testCngnBook: {"0xcacee66ad41fd1472a47d7d5fe372ffbfac9aa75", "1796047200"},
	}}
	svc := newBookDepthService(chain, []string{testEurcBook, testCngnBook})
	svc.now = func() time.Time { return time.Unix(1_795_100_000, 0) }
	market := instruments.Metadata{Symbol: "cNGN-30NOV26", AssetAddress: "0xcacee66ad41fd1472a47d7d5fe372ffbfac9aa75", SubID: "1796047200"}
	depth, err := svc.depth(context.Background(), market)
	if err != nil {
		t.Fatal(err)
	}
	if depth.Book != testCngnBook || len(depth.Bids) != len(bookDepthLadder) || len(depth.Asks) != len(bookDepthLadder) {
		t.Fatalf("%+v", depth)
	}
	if depth.Asks[4].Contracts != "1" || depth.Asks[4].Filled != "1" || depth.Asks[4].AvgPrice != "0.000688" || depth.Asks[4].Fee != "1.03" {
		t.Fatalf("one contract: %+v", depth.Asks[4])
	}
	calls := chain.calls
	if _, err := svc.depth(context.Background(), market); err != nil || chain.calls != calls {
		t.Fatalf("a second read inside the cache window made %d calls", chain.calls-calls)
	}
	if _, err := svc.depth(context.Background(), instruments.Metadata{Symbol: "X", AssetAddress: "0x01", SubID: "1"}); err != errNoBookForSeries {
		t.Fatalf("a series no book trades: %v", err)
	}
}
