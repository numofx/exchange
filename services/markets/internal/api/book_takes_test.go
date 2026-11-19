package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/ordersig"
)

const (
	testBookTakeModule = "0x1d1fcaa8c1677df51dda4f26bc391b91b98debe3"
	testCngnBook       = "0x5a35f149005ce74b874f7cf07cc2618bfa4f8bd4"
	testEurcBook       = "0x83c5741a24d57189379e1215f7a22d9f048e89d5"
)

func takeWord(v *big.Int) string { return fmt.Sprintf("%064x", v) }

// bookTakeDataHex is abi.encode(BookTakeData) for a buy of `amount` (1e18 a contract) on `book`.
func bookTakeDataHex(book string, amount *big.Int, deadline int64) string {
	addr := strings.TrimPrefix(strings.ToLower(book), "0x")
	return "0x" + strings.Repeat("0", 24) + addr +
		takeWord(big.NewInt(1)) + // marketId
		takeWord(big.NewInt(1)) + // isBuy
		takeWord(amount) +
		takeWord(big.NewInt(700_000_000_000_000)) + // limitPrice 0.0007
		takeWord(amount) + // minFill
		takeWord(new(big.Int).Mul(big.NewInt(2), big.NewInt(1e18))) + // maxFee 2 USDC
		takeWord(big.NewInt(deadline)) +
		takeWord(big.NewInt(255)) + // maxLevels
		takeWord(big.NewInt(0)) // reduceOnly
}

func validBookTake() withdrawalRequest {
	return withdrawalRequest{
		Action: withdrawalAction{
			SubaccountID: "61",
			Nonce:        "7",
			Module:       testBookTakeModule,
			Data:         bookTakeDataHex(testCngnBook, big.NewInt(1e18), testWithdrawalNow.Unix()+60),
			Expiry:       strconv.FormatInt(testWithdrawalNow.Unix()+600, 10),
			Owner:        testWithdrawalOwner,
			Signer:       testWithdrawalOwner,
		},
		Signature: "0x" + strings.Repeat("ab", 65),
	}
}

func newBookTakeHarness() (*Server, *fakeWithdrawalCustody, *fakeWithdrawalSubmitter) {
	custody := &fakeWithdrawalCustody{owner: strings.ToLower(testWithdrawalOwner)}
	submitter := &fakeWithdrawalSubmitter{
		receipt: withdrawalReceipt{Accepted: true, TxHash: "0xb00c", ReceiptStatus: "success", BlockNumber: "59343999"},
	}
	server := &Server{
		signatures: &stubSignatureChecker{path: ordersig.PathEOA},
		bookTakes: &bookTakeService{
			moduleAddress: testBookTakeModule,
			books:         []string{testCngnBook, testEurcBook},
			custody:       custody,
			submitter:     submitter,
			limiter:       newWithdrawalLimiter(bookTakesPerOwnerPerMinute),
			now:           func() time.Time { return testWithdrawalNow },
		},
	}
	return server, custody, submitter
}

func postBookTake(t *testing.T, server *Server, body any) *httptest.ResponseRecorder {
	t.Helper()
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("encode body: %v", err)
	}
	rec := httptest.NewRecorder()
	server.handleCreateBookTake(rec, httptest.NewRequest(http.MethodPost, "/book-takes", bytes.NewReader(raw)))
	return rec
}

func TestABookTakeIsVerifiedThenSubmittedAndItsReceiptReturned(t *testing.T) {
	server, custody, submitter := newBookTakeHarness()
	rec := postBookTake(t, server, validBookTake())
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	if custody.calls != 1 || submitter.received == nil || submitter.received.Action.Module != testBookTakeModule {
		t.Fatalf("custody calls %d, submitted %+v", custody.calls, submitter.received)
	}
	var receipt withdrawalReceipt
	_ = json.Unmarshal(rec.Body.Bytes(), &receipt)
	if receipt.TxHash != "0xb00c" {
		t.Fatalf("receipt %+v", receipt)
	}
}

func TestBookTakesAreRefusedWhenNotConfigured(t *testing.T) {
	rec := postBookTake(t, &Server{signatures: &stubSignatureChecker{}}, validBookTake())
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status %d", rec.Code)
	}
}

func TestMalformedBookTakesAreRefusedBeforeAnyChainRead(t *testing.T) {
	cases := map[string]func(*withdrawalRequest){
		"wrong module":  func(r *withdrawalRequest) { r.Action.Module = testWithdrawalModule },
		"account 0":     func(r *withdrawalRequest) { r.Action.SubaccountID = "0" },
		"session key":   func(r *withdrawalRequest) { r.Action.Signer = "0x1111111111111111111111111111111111111111" },
		"expired":       func(r *withdrawalRequest) { r.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix()-1, 10) },
		"too far ahead": func(r *withdrawalRequest) { r.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix()+7200, 10) },
		"unknown book": func(r *withdrawalRequest) {
			r.Action.Data = bookTakeDataHex(testWrappedUSDC, big.NewInt(1e18), testWithdrawalNow.Unix()+60)
		},
		"zero amount": func(r *withdrawalRequest) {
			r.Action.Data = bookTakeDataHex(testCngnBook, big.NewInt(0), testWithdrawalNow.Unix()+60)
		},
		"deadline passed": func(r *withdrawalRequest) {
			r.Action.Data = bookTakeDataHex(testCngnBook, big.NewInt(1e18), testWithdrawalNow.Unix()-1)
		},
		"short data":      func(r *withdrawalRequest) { r.Action.Data = r.Action.Data[:len(r.Action.Data)-64] },
		"dirty book word": func(r *withdrawalRequest) { r.Action.Data = "0x01" + r.Action.Data[4:] },
		"isBuy not a bool": func(r *withdrawalRequest) {
			d := r.Action.Data
			r.Action.Data = d[:2+128] + strings.Repeat("0", 63) + "2" + d[2+192:]
		},
		"short signature": func(r *withdrawalRequest) { r.Signature = "0xabcd" },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			server, custody, submitter := newBookTakeHarness()
			req := validBookTake()
			mutate(&req)
			rec := postBookTake(t, server, req)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
			}
			if custody.calls != 0 || submitter.received != nil {
				t.Fatal("a malformed take reached the chain or the executor")
			}
		})
	}
}

func TestABookTakeRequiresTheOwnerMatchingRecords(t *testing.T) {
	server, custody, submitter := newBookTakeHarness()
	custody.owner = "0x2222222222222222222222222222222222222222"
	rec := postBookTake(t, server, validBookTake())
	if rec.Code != http.StatusForbidden || submitter.received != nil {
		t.Fatalf("status %d, submitted %v", rec.Code, submitter.received != nil)
	}
}

func TestBookTakeExecutorVerdictsAreReportedFaithfully(t *testing.T) {
	for _, tc := range []struct {
		err    error
		status int
		revert string
	}{
		{&executorWithdrawError{Status: 422, Message: "take would revert: OB_BelowMinFill", Revert: "OB_BelowMinFill"}, 422, "OB_BelowMinFill"},
		{&executorWithdrawError{Status: 503, Message: "book takes are paused"}, 503, ""},
		{fmt.Errorf("connection reset"), 502, ""},
	} {
		server, _, submitter := newBookTakeHarness()
		submitter.err = tc.err
		rec := postBookTake(t, server, validBookTake())
		if rec.Code != tc.status {
			t.Fatalf("%v: status %d", tc.err, rec.Code)
		}
		if tc.revert != "" && decodeErrorBody(t, rec)["revert"] != tc.revert {
			t.Fatalf("revert not passed through: %s", rec.Body.String())
		}
	}
}

func TestBookTakeDataDecodesFieldForField(t *testing.T) {
	d, err := decodeBookTakeData(bookTakeDataHex(testEurcBook, big.NewInt(3e18), 1_800_000_000))
	if err != nil {
		t.Fatal(err)
	}
	if d.book != testEurcBook || !d.isBuy || d.amount.Cmp(big.NewInt(3e18)) != 0 || d.deadline != 1_800_000_000 || d.maxLevels != 255 || d.reduceOnly {
		t.Fatalf("%+v", d)
	}
}
