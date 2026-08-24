package matching

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
)

const oneE18 = "1000000000000000000"

func bigStr(t *testing.T, s string) *big.Int {
	t.Helper()
	v, ok := new(big.Int).SetString(s, 10)
	if !ok {
		t.Fatalf("bad big int %q", s)
	}
	return v
}

// ---------------------------------------------------------------------------------------------
// requiredQuote: the arithmetic the on-chain batch will perform
// ---------------------------------------------------------------------------------------------

func TestRequiredQuoteMatchesOnChainNotionalPlusFee(t *testing.T) {
	tests := []struct {
		name   string
		price  string
		amount string
		fee    string
		want   string
	}{
		{
			// 1500 cNGN/USDC style: price 0.000666e18 * 1.5e24 amount / 1e18
			name:   "notional only when fee is zero",
			price:  oneE18,
			amount: "1000000000000000000000", // 1000e18
			fee:    "0",
			want:   "1000000000000000000000",
		},
		{
			name:   "fee is added on top of notional, not folded into it",
			price:  oneE18,
			amount: "1000000000000000000000",
			fee:    oneE18,
			want:   "1001000000000000000000",
		},
		{
			name:   "price below one scales the notional down",
			price:  "500000000000000000", // 0.5e18
			amount: "1000000000000000000000",
			fee:    "0",
			want:   "500000000000000000000",
		},
		{
			// the on-chain multiplyDecimal truncates; this must match, not round up
			name:   "sub-wei products truncate the same way the chain does",
			price:  "1",
			amount: "1",
			fee:    "0",
			want:   "0",
		},
		{
			name:   "truncated notional still carries the fee",
			price:  "1",
			amount: "1",
			fee:    "7",
			want:   "7",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := requiredQuote(tc.price, tc.amount, tc.fee)
			if err != nil {
				t.Fatalf("requiredQuote: %v", err)
			}
			if got.Cmp(bigStr(t, tc.want)) != 0 {
				t.Fatalf("required = %s, want %s", got, tc.want)
			}
		})
	}
}

func TestRequiredQuoteRejectsBadInput(t *testing.T) {
	if _, err := requiredQuote("0", oneE18, "0"); err == nil {
		t.Fatal("expected zero price to be rejected")
	}
	if _, err := requiredQuote(oneE18, "0", "0"); err == nil {
		t.Fatal("expected zero amount to be rejected")
	}
	if _, err := requiredQuote(oneE18, oneE18, "-1"); err == nil {
		t.Fatal("expected negative fee to be rejected")
	}
}

// ---------------------------------------------------------------------------------------------
// buyerCanFund
// ---------------------------------------------------------------------------------------------

type stubChecker struct {
	balance string
	err     error
	calls   int
	lastID  string
}

func (s *stubChecker) CashBalance(_ context.Context, subaccountID string) (*big.Int, error) {
	s.calls++
	s.lastID = subaccountID
	if s.err != nil {
		return nil, s.err
	}
	v, _ := new(big.Int).SetString(s.balance, 10)
	return v, nil
}

func candidateWithBuyer(takerSide orders.Side, takerAcc string, makerAcc string) orders.MatchCandidate {
	taker := orders.Order{OrderID: "taker", SubaccountID: takerAcc, Side: takerSide}
	makerSide := orders.SideSell
	if takerSide == orders.SideSell {
		makerSide = orders.SideBuy
	}
	maker := orders.Order{OrderID: "maker", SubaccountID: makerAcc, Side: makerSide}
	return orders.MatchCandidate{Taker: taker, Maker: maker}
}

func TestBuyerCanFundRequiresNotionalPlusFee(t *testing.T) {
	candidate := candidateWithBuyer(orders.SideBuy, "11", "22")

	// notional is exactly 1000e18; the taker also owes a 1e18 fee
	exactlyNotional := &stubChecker{balance: "1000000000000000000000"}
	ok, required, available, err := buyerCanFund(
		context.Background(), exactlyNotional, candidate, oneE18, "1000000000000000000000", oneE18,
	)
	if err != nil {
		t.Fatalf("buyerCanFund: %v", err)
	}
	if ok {
		t.Fatal("a buyer funded to exactly the notional must not be allowed to cross")
	}
	if required.Cmp(bigStr(t, "1001000000000000000000")) != 0 {
		t.Fatalf("required = %s, want notional + fee", required)
	}
	if available.Cmp(bigStr(t, "1000000000000000000000")) != 0 {
		t.Fatalf("available = %s", available)
	}
	if exactlyNotional.lastID != "11" {
		t.Fatalf("checked account %q, want the buyer's", exactlyNotional.lastID)
	}

	// one wei short is still short
	short := &stubChecker{balance: "1000999999999999999999"}
	ok, _, _, _ = buyerCanFund(context.Background(), short, candidate, oneE18, "1000000000000000000000", oneE18)
	if ok {
		t.Fatal("one wei short must not cross")
	}

	// exactly notional + fee settles
	exact := &stubChecker{balance: "1001000000000000000000"}
	ok, _, _, err = buyerCanFund(context.Background(), exact, candidate, oneE18, "1000000000000000000000", oneE18)
	if err != nil {
		t.Fatalf("buyerCanFund: %v", err)
	}
	if !ok {
		t.Fatal("a buyer funded to notional + fee must be allowed to cross")
	}
}

// The seller's proceeds arrive in the same adjustment the fee is taken from, so a cash-free
// seller settles on the net delta. Only the buy side is gated.
func TestBuyerCanFundChecksTheBuyerNotTheTaker(t *testing.T) {
	// taker sells, maker buys: the maker is the one who needs cash
	candidate := candidateWithBuyer(orders.SideSell, "11", "22")

	checker := &stubChecker{balance: "1000000000000000000000"}
	ok, required, _, err := buyerCanFund(
		context.Background(), checker, candidate, oneE18, "1000000000000000000000", oneE18,
	)
	if err != nil {
		t.Fatalf("buyerCanFund: %v", err)
	}
	if checker.lastID != "22" {
		t.Fatalf("checked account %q, want the maker (the buyer)", checker.lastID)
	}
	// a maker-side buyer pays no fee on this venue, so notional alone is enough
	if required.Cmp(bigStr(t, "1000000000000000000000")) != 0 {
		t.Fatalf("required = %s, want notional with no taker fee", required)
	}
	if !ok {
		t.Fatal("a maker-side buyer funded to notional must cross: maker fills are fee-free")
	}
}

func TestBuyerCanFundIsDisabledByANilChecker(t *testing.T) {
	candidate := candidateWithBuyer(orders.SideBuy, "11", "22")
	ok, _, _, err := buyerCanFund(context.Background(), nil, candidate, oneE18, oneE18, oneE18)
	if err != nil {
		t.Fatalf("nil checker must not error: %v", err)
	}
	if !ok {
		t.Fatal("a nil checker means the check is off, so everything is allowed")
	}
}

func TestBuyerCanFundSurfacesRPCErrorsRatherThanBlocking(t *testing.T) {
	candidate := candidateWithBuyer(orders.SideBuy, "11", "22")
	ok, _, _, err := buyerCanFund(
		context.Background(), &stubChecker{err: errors.New("rpc down")}, candidate, oneE18, oneE18, "0",
	)
	if err == nil {
		t.Fatal("an RPC failure must be reported, not swallowed into a false")
	}
	if ok {
		t.Fatal("an errored check must not report funded")
	}
	// the engine turns this into fail-open; the important thing is that the error is
	// distinguishable from a genuine shortfall, which a bare bool would not be
}

func TestBuyerCanFundRejectsACandidateWithNoBuySide(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{OrderID: "t", Side: orders.SideSell, SubaccountID: "1"},
		Maker: orders.Order{OrderID: "m", Side: orders.SideSell, SubaccountID: "2"},
	}
	if _, _, _, err := buyerCanFund(context.Background(), &stubChecker{balance: "0"}, candidate, oneE18, oneE18, "0"); err == nil {
		t.Fatal("two sells is not a match and must not be reported as funded")
	}
}

// ---------------------------------------------------------------------------------------------
// chain checker
// ---------------------------------------------------------------------------------------------

func word(hexNoPrefix string) string {
	return fmt.Sprintf("%064s", hexNoPrefix)
}

func newStubRPC(t *testing.T, subAccounts string, balanceWord string, onCall func(data string)) *httptest.Server {
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
		if onCall != nil {
			onCall(call.Data)
		}

		result := "0x" + balanceWord
		if len(call.Data) >= 10 && call.Data[:10] == subAccountsSelector {
			result = "0x" + word(subAccounts[2:])
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"` + result + `"}`))
	}))
}

func testCfg(rpcURL string) config.Config {
	return config.Config{
		EnforceFundingCheck: true,
		ChainRPCURL:         rpcURL,
		MatchingAddress:     "0x1111111111111111111111111111111111111111",
		CashAssetAddress:    "0x2222222222222222222222222222222222222222",
	}
}

func TestChainFundingCheckerReadsCashBalance(t *testing.T) {
	var seen []string
	srv := newStubRPC(t, "0x3333333333333333333333333333333333333333", word("de0b6b3a7640000"), func(data string) {
		seen = append(seen, data)
	})
	defer srv.Close()

	checker := newFundingChecker(testCfg(srv.URL))
	if checker == nil {
		t.Fatal("checker must be constructed when configured")
	}

	balance, err := checker.CashBalance(context.Background(), "42")
	if err != nil {
		t.Fatalf("CashBalance: %v", err)
	}
	if balance.Cmp(bigStr(t, oneE18)) != 0 {
		t.Fatalf("balance = %s, want 1e18", balance)
	}

	// the balance call must be getBalance(accountId, cashAsset, 0) -- a wrong selector or a
	// wrong asset would read some other account's position and silently pass everything
	last := seen[len(seen)-1]
	if last[:10] != getBalanceSelector {
		t.Fatalf("selector = %s, want %s", last[:10], getBalanceSelector)
	}
	wantArgs := word("2a") + word("2222222222222222222222222222222222222222") + word("0")
	if last[10:] != wantArgs {
		t.Fatalf("args = %s\nwant   %s", last[10:], wantArgs)
	}
}

// Cash goes negative when borrowing is enabled, so a uint decode would read a small debt as an
// astronomically large balance and wave every order through.
func TestChainFundingCheckerDecodesNegativeCash(t *testing.T) {
	negativeOne := "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
	srv := newStubRPC(t, "0x3333333333333333333333333333333333333333", negativeOne, nil)
	defer srv.Close()

	balance, err := newFundingChecker(testCfg(srv.URL)).CashBalance(context.Background(), "1")
	if err != nil {
		t.Fatalf("CashBalance: %v", err)
	}
	if balance.Sign() >= 0 {
		t.Fatalf("balance = %s, want negative", balance)
	}
	if balance.Cmp(big.NewInt(-1)) != 0 {
		t.Fatalf("balance = %s, want -1", balance)
	}
}

func TestChainFundingCheckerCachesWithinTTL(t *testing.T) {
	calls := 0
	srv := newStubRPC(t, "0x3333333333333333333333333333333333333333", word("de0b6b3a7640000"), func(string) {
		calls++
	})
	defer srv.Close()

	checker := newFundingChecker(testCfg(srv.URL)).(*chainFundingChecker)
	now := time.Unix(1000, 0)
	checker.now = func() time.Time { return now }

	for i := 0; i < 5; i++ {
		if _, err := checker.CashBalance(context.Background(), "42"); err != nil {
			t.Fatalf("CashBalance: %v", err)
		}
	}
	// one subAccounts() resolve plus one getBalance; the rest come from cache
	if calls != 2 {
		t.Fatalf("made %d rpc calls, want 2 (subAccounts + one balance)", calls)
	}

	// past the TTL the balance is re-read: a stale balance is how an underfunded account
	// slips through after withdrawing
	now = now.Add(3 * time.Second)
	if _, err := checker.CashBalance(context.Background(), "42"); err != nil {
		t.Fatalf("CashBalance: %v", err)
	}
	if calls != 3 {
		t.Fatalf("made %d rpc calls, want a re-read after the TTL", calls)
	}
}

func TestNewFundingCheckerIsNilWhenNotUsable(t *testing.T) {
	cases := map[string]func(*config.Config){
		"disabled":      func(c *config.Config) { c.EnforceFundingCheck = false },
		"no rpc":        func(c *config.Config) { c.ChainRPCURL = "" },
		"no cash asset": func(c *config.Config) { c.CashAssetAddress = "" },
		"zero cash asset": func(c *config.Config) {
			c.CashAssetAddress = "0x0000000000000000000000000000000000000000"
		},
		"no matching address": func(c *config.Config) { c.MatchingAddress = "" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := testCfg("http://127.0.0.1:1")
			mutate(&cfg)
			if newFundingChecker(cfg) != nil {
				t.Fatal("an unusable configuration must disable the check, not half-enable it")
			}
		})
	}
}

// The fee the matcher reserves and the fee it submits must be the same value, or the check is
// reserving against a number the chain will not charge.
func TestReservedFeeMatchesSubmittedFee(t *testing.T) {
	if takerFillFee != "0" {
		t.Fatalf("taker fee is now %q -- confirm buyerCanFund still reads the same constant", takerFillFee)
	}
	required, err := requiredQuote(oneE18, oneE18, takerFillFee)
	if err != nil {
		t.Fatalf("requiredQuote: %v", err)
	}
	if required.Cmp(bigStr(t, oneE18)) != 0 {
		t.Fatalf("required = %s, want the bare notional while the taker fee is zero", required)
	}
}
