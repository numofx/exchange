package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

const (
	testCustodian  = "0xd8ebf2216fd4eca79272e76ad22131592ea0dfd6"
	testCash       = "0xa74e49b4ed7cb176bc02ef4d8a1a3240c9ad4272"
	testEURCAsset  = "0xfd2afbf4ef6e7a7f34a04d16ff6da249ca086cd9"
	testCNGNBook   = "0x5a35f149005ce74b874f7cf07cc2618bfa4f8bd4"
	testWallet     = "0x1111111111111111111111111111111111111111"
	testOtherWalet = "0x2222222222222222222222222222222222222222"
)

var testNow = time.Unix(1_795_100_000, 0)

// fakeCustodianChain answers accountOwner(id) from a map.
type fakeCustodianChain struct {
	owners map[string]string
	reads  int
	fail   bool
}

func (f *fakeCustodianChain) ethCall(_ context.Context, to string, data string) (string, error) {
	f.reads++
	if f.fail {
		return "", fmt.Errorf("rpc down")
	}
	if to != testCustodian || !strings.HasPrefix(data, sigCustodianAccountOwner) {
		return "", fmt.Errorf("unexpected call %s %s", to, data)
	}
	id, _ := new(big.Int).SetString(data[len(sigCustodianAccountOwner):], 16)
	owner := f.owners[id.String()]
	if owner == "" {
		owner = zeroAddress
	}
	return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(owner, "0x"), nil
}

type fakeCustodianLedger struct{ cash *big.Int }

func (f *fakeCustodianLedger) CashBalance(context.Context, string) (*big.Int, error) {
	return f.cash, nil
}

type fakeCustodianSubmitter struct {
	got  []custodianRequest
	err  error
	body string
}

func (f *fakeCustodianSubmitter) Submit(_ context.Context, r custodianRequest) (json.RawMessage, error) {
	f.got = append(f.got, r)
	if f.err != nil {
		return nil, f.err
	}
	return json.RawMessage(nonEmpty(f.body, `{"accepted":true,"tx_hash":"0xabc","receipt_status":"success"}`)), nil
}

func custodianServer(chain *fakeCustodianChain, sub *fakeCustodianSubmitter, ledger withdrawalLedger) *Server {
	return &Server{custodian: &custodianService{
		address:   testCustodian,
		books:     []string{testCNGNBook},
		assets:    []string{testCash, testEURCAsset},
		perpCash:  testCash,
		chain:     chain,
		ledger:    ledger,
		submitter: sub,
		limiter:   newWithdrawalLimiter(custodianCallsPerWalletPerMinute),
		index:     &custodianAccountIndex{custodian: testCustodian, wallets: map[string]map[string]bool{}},
		now:       func() time.Time { return testNow },
	}}
}

func postCustodian(t *testing.T, server *Server, body any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	rec := httptest.NewRecorder()
	server.handleCustodian(rec, httptest.NewRequest(http.MethodPost, "/custodian", bytes.NewReader(raw)))
	return rec
}

var testSig = "0x" + strings.Repeat("ab", 65)

func custodianTakeBody(over map[string]any) map[string]any {
	take := map[string]any{
		"account_id": "70", "book": testCNGNBook, "market_id": "1", "is_buy": true, "amount": "1000000000000000000",
		"limit_price": "700000000000000", "min_fill": "1000000000000000000", "max_fee": "2000000000000000000",
		"deadline": fmt.Sprint(testNow.Unix() + 60), "max_levels": 255, "reduce_only": false, "nonce": "7",
	}
	for k, v := range over {
		take[k] = v
	}
	return map[string]any{"call": "take", "take": take, "signature": testSig}
}

func TestACustodianTakeOnAHeldAccountIsForwardedUnchanged(t *testing.T) {
	chain := &fakeCustodianChain{owners: map[string]string{"70": testWallet}}
	sub := &fakeCustodianSubmitter{}
	rec := postCustodian(t, custodianServer(chain, sub, nil), custodianTakeBody(nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(sub.got) != 1 || sub.got[0].Take == nil || sub.got[0].Take.Book != testCNGNBook || sub.got[0].Signature != testSig {
		t.Fatalf("forwarded %+v", sub.got)
	}
	raw, _ := json.Marshal(sub.got[0])
	if !strings.Contains(string(raw), `"reduce_only":false`) || !strings.Contains(string(raw), `"max_levels":255`) {
		t.Fatalf("the forwarded take lost fields: %s", raw)
	}
}

func TestCustodianCallsBreakingPolicyAreRefusedBeforeAnyChainRead(t *testing.T) {
	for name, body := range map[string]map[string]any{
		"unlisted book":         custodianTakeBody(map[string]any{"book": "0x0000000000000000000000000000000000000bad"}),
		"zero amount":           custodianTakeBody(map[string]any{"amount": "0"}),
		"deadline too far":      custodianTakeBody(map[string]any{"deadline": fmt.Sprint(testNow.Unix() + 601)}),
		"deadline passed":       custodianTakeBody(map[string]any{"deadline": fmt.Sprint(testNow.Unix() - 1)}),
		"zero account":          custodianTakeBody(map[string]any{"account_id": "0"}),
		"unknown call":          {"call": "sweep"},
		"open for zero wallet":  {"call": "open_account", "wallet": zeroAddress},
		"unlisted asset":        {"call": "withdraw_for", "account_id": "70", "asset": "0x0000000000000000000000000000000000000bad", "amount": "1", "nonce": "1", "deadline": fmt.Sprint(testNow.Unix() + 60), "signature": testSig},
		"short signature":       {"call": "exit_for", "account_id": "70", "nonce": "1", "deadline": fmt.Sprint(testNow.Unix() + 60), "signature": "0x12"},
		"permit without v,r,s":  {"call": "deposit_with_permit", "account_id": "70", "asset": testCash, "amount": "1", "permit_deadline": fmt.Sprint(testNow.Unix() + 60)},
		"key without signature": {"call": "set_trading_key_for", "wallet": testWallet, "key": testOtherWalet, "valid_until": "1", "nonce": "1", "deadline": fmt.Sprint(testNow.Unix() + 60)},
	} {
		chain := &fakeCustodianChain{owners: map[string]string{"70": testWallet}}
		sub := &fakeCustodianSubmitter{}
		rec := postCustodian(t, custodianServer(chain, sub, nil), body)
		if rec.Code != http.StatusBadRequest || chain.reads != 0 || len(sub.got) != 0 {
			t.Errorf("%s: status %d, reads %d, forwarded %d: %s", name, rec.Code, chain.reads, len(sub.got), rec.Body.String())
		}
	}
}

func TestAnAccountTheCustodianDoesNotHoldIsRefused(t *testing.T) {
	sub := &fakeCustodianSubmitter{}
	rec := postCustodian(t, custodianServer(&fakeCustodianChain{owners: map[string]string{}}, sub, nil), custodianTakeBody(nil))
	if rec.Code != http.StatusBadRequest || len(sub.got) != 0 || !strings.Contains(rec.Body.String(), "not held") {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	// an owner that cannot be read is not a no: 503, nothing forwarded
	rec = postCustodian(t, custodianServer(&fakeCustodianChain{fail: true}, sub, nil), custodianTakeBody(nil))
	if rec.Code != http.StatusServiceUnavailable || len(sub.got) != 0 {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestARelayedWithdrawalNeverPaysOutBorrowedCash(t *testing.T) {
	body := map[string]any{"call": "withdraw_for", "account_id": "70", "asset": testCash, "amount": "5000000", "nonce": "1",
		"deadline": fmt.Sprint(testNow.Unix() + 60), "signature": testSig}
	chain := &fakeCustodianChain{owners: map[string]string{"70": testWallet}}
	sub := &fakeCustodianSubmitter{}
	// 4.99 USDC of cash, 5 asked
	rec := postCustodian(t, custodianServer(chain, sub, &fakeCustodianLedger{cash: big.NewInt(4_990_000_000_000_000_000)}), body)
	if rec.Code != http.StatusConflict || len(sub.got) != 0 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	rec = postCustodian(t, custodianServer(chain, sub, &fakeCustodianLedger{cash: big.NewInt(5_000_000_000_000_000_000)}), body)
	if rec.Code != http.StatusOK || len(sub.got) != 1 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	// the EURC asset is not cash: no cash rule
	body["asset"] = testEURCAsset
	rec = postCustodian(t, custodianServer(chain, sub, &fakeCustodianLedger{cash: big.NewInt(0)}), body)
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCustodianExecutorVerdictsAreReportedFaithfully(t *testing.T) {
	chain := &fakeCustodianChain{owners: map[string]string{"70": testWallet}}
	sub := &fakeCustodianSubmitter{err: &executorWithdrawError{Status: 422, Message: "take would revert: BC_BadSignature", Revert: "BC_BadSignature"}}
	rec := postCustodian(t, custodianServer(chain, sub, nil), custodianTakeBody(nil))
	if rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), `"revert":"BC_BadSignature"`) {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	sub = &fakeCustodianSubmitter{err: fmt.Errorf("connection reset")}
	rec = postCustodian(t, custodianServer(chain, sub, nil), custodianTakeBody(nil))
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "could not confirm") {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	// an opened account's id passes straight through
	sub = &fakeCustodianSubmitter{body: `{"accepted":true,"tx_hash":"0xabc","receipt_status":"success","account_id":"77"}`}
	rec = postCustodian(t, custodianServer(chain, sub, nil), map[string]any{"call": "open_account", "wallet": testWallet})
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"account_id":"77"`) {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
}

func TestCustodianCallsAreLimitedPerRecordedWallet(t *testing.T) {
	chain := &fakeCustodianChain{owners: map[string]string{"70": testWallet, "71": testWallet, "72": testOtherWalet}}
	server := custodianServer(chain, &fakeCustodianSubmitter{}, nil)
	for i := 0; i < custodianCallsPerWalletPerMinute; i++ {
		id := "70"
		if i%2 == 1 {
			id = "71"
		}
		if rec := postCustodian(t, server, custodianTakeBody(map[string]any{"account_id": id})); rec.Code != http.StatusOK {
			t.Fatalf("call %d: %d", i, rec.Code)
		}
	}
	// a second account of the same wallet shares the wallet's budget
	if rec := postCustodian(t, server, custodianTakeBody(map[string]any{"account_id": "71"})); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status %d", rec.Code)
	}
	// another wallet's account has its own
	if rec := postCustodian(t, server, custodianTakeBody(map[string]any{"account_id": "72"})); rec.Code != http.StatusOK {
		t.Fatalf("another wallet: status %d", rec.Code)
	}
}

// fakeIndexRPC serves eth_blockNumber and eth_getLogs over a fixed log set.
type fakeIndexRPC struct {
	head  uint64
	logs  []map[string]any
	calls []string
}

func (f *fakeIndexRPC) call(_ context.Context, method string, params []any) (json.RawMessage, error) {
	f.calls = append(f.calls, method)
	switch method {
	case "eth_blockNumber":
		return json.RawMessage(fmt.Sprintf(`"0x%x"`, f.head)), nil
	case "eth_getLogs":
		q := params[0].(map[string]any)
		var from, to uint64
		fmt.Sscanf(q["fromBlock"].(string), "0x%x", &from)
		fmt.Sscanf(q["toBlock"].(string), "0x%x", &to)
		if to-from+1 > custodianLogChunk {
			return nil, fmt.Errorf("range too wide")
		}
		out := []map[string]any{}
		for _, l := range f.logs {
			if b := l["block"].(uint64); b >= from && b <= to {
				out = append(out, l)
			}
		}
		raw, _ := json.Marshal(out)
		return raw, nil
	}
	return nil, fmt.Errorf("unexpected %s", method)
}

func custodianLogFor(block uint64, topic string, id int64, wallet string) map[string]any {
	return map[string]any{
		"block":  block,
		"topics": []string{topic, fmt.Sprintf("0x%064x", id), "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(wallet, "0x")},
	}
}

func TestCustodianAccountsAreFoundFromEventsAndConfirmedOnChain(t *testing.T) {
	rpc := &fakeIndexRPC{head: 100_000 + 2*custodianLogChunk, logs: []map[string]any{
		custodianLogFor(100_010, topicCustodianAccountOpened, 63, testWallet),
		custodianLogFor(100_000+custodianLogChunk+5, topicCustodianAccountDeposited, 61, testWallet),
		custodianLogFor(100_000+2*custodianLogChunk, topicCustodianAccountOpened, 64, testOtherWalet),
	}}
	// 61 has since left (its record is now zero), 63 is still the wallet's
	chain := &fakeCustodianChain{owners: map[string]string{"63": testWallet, "64": testOtherWalet}}
	server := custodianServer(chain, &fakeCustodianSubmitter{}, nil)
	server.custodian.index.rpc = rpc
	server.custodian.index.next = 100_000

	get := func() *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		server.handleCustodianAccounts(rec, httptest.NewRequest(http.MethodGet, "/custodian/accounts?wallet="+strings.ToUpper(testWallet[2:3])+testWallet[3:], nil))
		return rec
	}
	if rec := get(); rec.Code != http.StatusBadRequest {
		// "0x" stripped above on purpose: not an address
		t.Fatalf("a non-address: %d", rec.Code)
	}
	rec := httptest.NewRecorder()
	server.handleCustodianAccounts(rec, httptest.NewRequest(http.MethodGet, "/custodian/accounts?wallet="+testWallet, nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("before the index catches up: %d", rec.Code)
	}
	if err := server.custodian.index.catchUp(context.Background()); err != nil {
		t.Fatal(err)
	}
	rec = httptest.NewRecorder()
	server.handleCustodianAccounts(rec, httptest.NewRequest(http.MethodGet, "/custodian/accounts?wallet="+testWallet, nil))
	var out struct {
		Accounts []string `json:"accounts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil || rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if len(out.Accounts) != 1 || out.Accounts[0] != "63" {
		t.Fatalf("accounts %v: want [63] (61 left, 64 is another wallet's)", out.Accounts)
	}
	if server.custodian.index.next != rpc.head+1 {
		t.Fatalf("cursor %d, want %d", server.custodian.index.next, rpc.head+1)
	}
}
