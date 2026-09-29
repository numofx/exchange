package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

var (
	perpE18   = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	perpMark  = big.NewInt(720_000_000_000_000) // 0.00072 USD per NGN
	perpIMReq = big.NewInt(333_330_000_000_000_000)
)

func usd(n int64) *big.Int       { return new(big.Int).Mul(big.NewInt(n), perpE18) }
func ngn(n int64) *big.Int       { return new(big.Int).Mul(big.NewInt(n), perpE18) }
func negate(v *big.Int) *big.Int { return new(big.Int).Neg(v) }

// 10M NGN at 0.00072 is $7,200 of notional and $2,400 of initial margin at 33.333%.
func TestPerpFillNeedsOnlyInitialMarginNotNotional(t *testing.T) {
	side := perpSide{ImSurplus: usd(2_500), Position: big.NewInt(0), Delta: ngn(10_000_000), Fee: big.NewInt(0)}
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); !ok {
		t.Fatal("$2,500 of surplus covers $2,400 of IM: a 3x position must be allowed")
	}
	side.ImSurplus = usd(2_300)
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); ok {
		t.Fatal("$2,300 does not cover $2,400 of IM")
	}
}

// The spot check only looked at the buyer. A perp short takes the same risk.
func TestPerpShortIsCheckedLikeALong(t *testing.T) {
	side := perpSide{ImSurplus: usd(2_300), Position: big.NewInt(0), Delta: negate(ngn(10_000_000)), Fee: big.NewInt(0)}
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); ok {
		t.Fatal("an underfunded short must be refused like an underfunded long")
	}
}

// Reducing is how an account under margin gets out; refusing it would trap it until liquidation.
func TestReducingAPositionIsAlwaysAllowed(t *testing.T) {
	side := perpSide{ImSurplus: negate(usd(500)), Position: ngn(10_000_000), Delta: negate(ngn(4_000_000)), Fee: usd(10)}
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); !ok {
		t.Fatal("a partial close of a long must be allowed even below initial margin")
	}
	side.Delta = negate(ngn(10_000_000))
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); !ok {
		t.Fatal("a full close must be allowed")
	}
}

// Flipping through zero is not a reduction: the new short needs margin of its own.
func TestFlippingThroughZeroNeedsMarginForTheNewSide(t *testing.T) {
	side := perpSide{ImSurplus: negate(usd(100)), Position: ngn(10_000_000), Delta: negate(ngn(20_000_000)), Fee: big.NewInt(0)}
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); ok {
		t.Fatal("a flip into a new short must not ride through as a reduction")
	}
}

// Buying above the mark costs the price-vs-mark leg in cash, and the taker fee on top.
func TestPriceLegAndFeeCountAgainstTheBuyer(t *testing.T) {
	above := new(big.Int).Div(new(big.Int).Mul(perpMark, big.NewInt(101)), big.NewInt(100)) // +1%: $72 on 10M
	side := perpSide{ImSurplus: usd(2_450), Position: big.NewInt(0), Delta: ngn(10_000_000), Fee: big.NewInt(0)}
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); !ok {
		t.Fatal("at the mark, $2,450 covers $2,400")
	}
	if ok, _ := perpFillCheck(side, above, perpMark, perpIMReq); ok {
		t.Fatal("$72 of price leg on top of $2,400 must not fit in $2,450")
	}
	side.Fee = usd(60)
	if ok, _ := perpFillCheck(side, perpMark, perpMark, perpIMReq); ok {
		t.Fatal("a $60 taker fee on top of $2,400 must not fit in $2,450")
	}
}

// ---------------------------------------------------------------------------------------------
// the checker against a stubbed chain
// ---------------------------------------------------------------------------------------------

const (
	stubSubAccounts = "0x7019244e25fa416e6ca2ed2f3ca25277aef72843"
	stubSRM         = "0x5555555555555555555555555555555555555555"
	stubPerp        = "0x3333333333333333333333333333333333333333"
)

func hexWord(v *big.Int) string {
	if v.Sign() >= 0 {
		return fmt.Sprintf("%064x", v)
	}
	return fmt.Sprintf("%064x", new(big.Int).Add(new(big.Int).Lsh(big.NewInt(1), 256), v))
}

// stubPerpChain answers the reads the margin checker makes, with a per-account IM surplus and
// position.
func stubPerpChain(t *testing.T, surplus, position map[string]*big.Int) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct {
			To   string `json:"to"`
			Data string `json:"data"`
		}
		_ = json.Unmarshal(req.Params[0], &call)
		data := strings.ToLower(call.Data)
		account := func() string {
			id, _ := new(big.Int).SetString(data[10:74], 16)
			return id.String()
		}

		var result string
		switch data[:10] {
		case subAccountsSelector:
			result = "000000000000000000000000" + stubSubAccounts[2:]
		case getPerpPriceSelector:
			result = hexWord(perpMark) + hexWord(perpE18)
		case assetDetailsSelector:
			result = hexWord(big.NewInt(1)) + hexWord(big.NewInt(2)) + hexWord(big.NewInt(1))
		case perpMarginRequirementsSelector:
			result = hexWord(big.NewInt(200_000_000_000_000_000)) + hexWord(perpIMReq)
		case getMarginSelector:
			result = hexWord(surplus[account()])
		case getBalanceSelector:
			result = hexWord(position[account()])
		default:
			t.Errorf("unexpected call %s to %s", data[:10], call.To)
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"0x` + result + `"}`))
	}))
}

func perpInstrument() instruments.Metadata {
	return instruments.Metadata{
		Symbol:               instruments.CNGNPerpSymbol,
		AssetAddress:         stubPerp,
		SubID:                "0",
		ContractType:         instruments.ContractTypePerpetual,
		MarginManagerAddress: stubSRM,
	}
}

func perpCheckerFor(t *testing.T, url string) marginChecker {
	t.Helper()
	checker := newMarginChecker(config.Config{
		ChainRPCURL:                url,
		MatchingAddress:            "0x1111111111111111111111111111111111111111",
		CNGNPerpAssetAddress:       stubPerp,
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x4444444444444444444444444444444444444444",
		CNGNPerpSRMAddress:         stubSRM,
	})
	if checker == nil {
		t.Fatal("a configured perp must get a margin checker")
	}
	return checker
}

func TestCheckPerpFillNamesTheSideThatCannotMarginIt(t *testing.T) {
	srv := stubPerpChain(t,
		map[string]*big.Int{"7": usd(5_000), "8": usd(1_000)},
		map[string]*big.Int{"7": big.NewInt(0), "8": big.NewInt(0)},
	)
	defer srv.Close()

	candidate := orders.MatchCandidate{
		Taker: orders.Order{OrderID: "t", SubaccountID: "7", Side: orders.SideBuy},
		Maker: orders.Order{OrderID: "m", SubaccountID: "8", Side: orders.SideSell},
	}
	verdict, err := perpCheckerFor(t, srv.URL).CheckPerpFill(context.Background(), perpInstrument(), candidate,
		perpMark.String(), ngn(10_000_000).String(), "0")
	if err != nil {
		t.Fatalf("check: %v", err)
	}
	if verdict.OK || verdict.Account != "8" {
		t.Fatalf("the maker's short needs $2,400 of IM and has $1,000: want it named, got %+v", verdict)
	}
}

func TestCheckPerpFillPassesWhenBothSidesAreMargined(t *testing.T) {
	srv := stubPerpChain(t,
		map[string]*big.Int{"7": usd(5_000), "8": usd(5_000)},
		map[string]*big.Int{"7": big.NewInt(0), "8": big.NewInt(0)},
	)
	defer srv.Close()

	candidate := orders.MatchCandidate{
		Taker: orders.Order{OrderID: "t", SubaccountID: "7", Side: orders.SideSell},
		Maker: orders.Order{OrderID: "m", SubaccountID: "8", Side: orders.SideBuy},
	}
	verdict, err := perpCheckerFor(t, srv.URL).CheckPerpFill(context.Background(), perpInstrument(), candidate,
		perpMark.String(), ngn(10_000_000).String(), usd(18).String())
	if err != nil || !verdict.OK {
		t.Fatalf("both sides hold $5,000 against $2,400: want OK, got %+v, %v", verdict, err)
	}
}

func TestNoPerpNoMarginChecker(t *testing.T) {
	if newMarginChecker(config.Config{ChainRPCURL: "http://x", MatchingAddress: "0x1111111111111111111111111111111111111111"}) != nil {
		t.Fatal("without a perp configured there is nothing to check")
	}
}
