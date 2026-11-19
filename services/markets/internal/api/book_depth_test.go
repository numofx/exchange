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
	if got := encodeBookQuote(1, true, big.NewInt(bookDepthLot), 1_800_000_000); got != castQuoteBuyLot {
		t.Fatalf("buy encoding\n got %s\nwant %s", got, castQuoteBuyLot)
	}
	if got := encodeBookQuote(1, false, big.NewInt(1e18), 1_800_000_000); got != castQuoteSellContract {
		t.Fatalf("sell encoding\n got %s\nwant %s", got, castQuoteSellContract)
	}
}

// fakeBookChain answers nextMarketId and markets(id) per book from `series` (book -> its markets' {future, subId}, in
// id order), and quote() with a flat fill, recording the market id each quote asked for.
type fakeBookChain struct {
	series       map[string][][2]string
	calls        int
	quoteMarkets []uint64
}

func (f *fakeBookChain) ethCall(_ context.Context, book string, data string) (string, error) {
	f.calls++
	markets := f.series[book]
	switch {
	case strings.HasPrefix(data, "0x"+selectorBookNextMarketID):
		return "0x" + fmt.Sprintf("%064x", len(markets)+1), nil
	case strings.HasPrefix(data, "0x"+selectorBookMarkets):
		id, _ := new(big.Int).SetString(data[2+8:], 16)
		s := markets[id.Int64()-1]
		subID, _ := new(big.Int).SetString(s[1], 10)
		return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(s[0], "0x") + strings.Repeat("0", 64) +
			fmt.Sprintf("%064x", subID) + strings.Repeat("0", 64*10), nil
	}
	// quote: fill the asked amount at 0.000688 with a 1.03 fee
	market, _ := new(big.Int).SetString(data[2+8+64:2+8+64*2], 16)
	f.quoteMarkets = append(f.quoteMarkets, market.Uint64())
	amount, _ := new(big.Int).SetString(data[2+8+64*4:2+8+64*5], 16)
	return "0x" + fmt.Sprintf("%064x", amount) + fmt.Sprintf("%064x", big.NewInt(688_000_000_000_000)) +
		fmt.Sprintf("%064x", big.NewInt(1_030_000_000_000_000_000)) + fmt.Sprintf("%064x", 1), nil
}

const (
	eurcFuture  = "0xc350243c1d07ff598770ece12323799d2efbb227"
	cngnFuture  = "0xcacee66ad41fd1472a47d7d5fe372ffbfac9aa75"
	eurc30Nov26 = "1796050800"
	eurc31Dec26 = "1798729200"
)

func TestDepthFindsTheSeriesBookAndQuotesTheLadder(t *testing.T) {
	chain := &fakeBookChain{series: map[string][][2]string{
		testEurcBook: {{eurcFuture, eurc30Nov26}},
		testCngnBook: {{cngnFuture, "1796047200"}},
	}}
	svc := newBookDepthService(chain, []string{testEurcBook, testCngnBook})
	svc.now = func() time.Time { return time.Unix(1_795_100_000, 0) }
	market := instruments.Metadata{Symbol: "cNGN-30NOV26", AssetAddress: "0xcacee66ad41fd1472a47d7d5fe372ffbfac9aa75", SubID: "1796047200"}
	depth, err := svc.depth(context.Background(), market)
	if err != nil {
		t.Fatal(err)
	}
	if depth.Book != testCngnBook || depth.MarketID != 1 || len(depth.Bids) != len(bookDepthLadder) || len(depth.Asks) != len(bookDepthLadder) {
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

// The next series is market 2 on the same book, added after the service started: a miss re-reads nextMarketId, finds
// it, and quotes it as market 2.
func TestDepthFindsAMarketAddedLater(t *testing.T) {
	chain := &fakeBookChain{series: map[string][][2]string{testEurcBook: {{eurcFuture, eurc30Nov26}}}}
	svc := newBookDepthService(chain, []string{testEurcBook})
	svc.now = func() time.Time { return time.Unix(1_795_100_000, 0) }
	next := instruments.Metadata{Symbol: "EURC-31DEC26", AssetAddress: eurcFuture, SubID: eurc31Dec26}
	if _, err := svc.depth(context.Background(), next); err != errNoBookForSeries {
		t.Fatalf("before market 2 exists: %v", err)
	}
	chain.series[testEurcBook] = append(chain.series[testEurcBook], [2]string{eurcFuture, eurc31Dec26})
	chain.quoteMarkets = nil
	depth, err := svc.depth(context.Background(), next)
	if err != nil {
		t.Fatal(err)
	}
	if depth.MarketID != 2 || depth.Book != testEurcBook {
		t.Fatalf("found %s market %d", depth.Book, depth.MarketID)
	}
	for _, m := range chain.quoteMarkets {
		if m != 2 {
			t.Fatalf("quoted market %d for the market-2 series", m)
		}
	}
}
