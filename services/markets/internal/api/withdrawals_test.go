package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/ordersig"
)

const (
	testWithdrawalModule   = "0x0a10ae2f5d2482ce1e43bc309d430b8861c2b5ab"
	testWrappedUSDC        = "0x364058aff6f36e01505fb2cc870f8b6bd4835e84"
	testWrappedCNGN        = "0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493"
	testLegacyCashAsset    = "0x6b232a2155bd0c9bf741db4cf8e7e8a0176a6fc6"
	testWithdrawalOwner    = "0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA"
	testMatchingContract   = "0x9e90a9cd13d859bd6a08168082fb1f6f7405f191"
	testSubAccountsAddress = "0x7019244e25fa416e6ca2ed2f3ca25277aef72843"
)

var testWithdrawalNow = time.Unix(1_789_400_000, 0)

func withdrawalDataHex(asset string, amount int64) string {
	return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(strings.ToLower(asset), "0x") + fmt.Sprintf("%064x", amount)
}

// validWithdrawal is subaccount #19's USDC as a trader would sign it: 1.999575 USDC in native 6 decimals.
func validWithdrawal() withdrawalRequest {
	return withdrawalRequest{
		Action: withdrawalAction{
			SubaccountID: "19",
			Nonce:        "7328734720000000",
			Module:       testWithdrawalModule,
			Data:         withdrawalDataHex(testWrappedUSDC, 1_999_575),
			Expiry:       strconv.FormatInt(testWithdrawalNow.Unix()+600, 10),
			Owner:        testWithdrawalOwner,
			Signer:       testWithdrawalOwner,
		},
		Signature: "0x" + strings.Repeat("ab", 65),
	}
}

type fakeWithdrawalCustody struct {
	owner string
	err   error
	calls int
}

func (f *fakeWithdrawalCustody) DepositedOwner(context.Context, string) (string, error) {
	f.calls++
	return f.owner, f.err
}

type fakeWithdrawalSubmitter struct {
	receipt  withdrawalReceipt
	err      error
	received *withdrawalRequest
}

func (f *fakeWithdrawalSubmitter) SubmitWithdrawal(_ context.Context, request withdrawalRequest) (withdrawalReceipt, error) {
	f.received = &request
	return f.receipt, f.err
}

type withdrawalHarness struct {
	server     *Server
	custody    *fakeWithdrawalCustody
	submitter  *fakeWithdrawalSubmitter
	signatures *stubSignatureChecker
}

func newWithdrawalHarness() *withdrawalHarness {
	custody := &fakeWithdrawalCustody{owner: strings.ToLower(testWithdrawalOwner)}
	submitter := &fakeWithdrawalSubmitter{
		receipt: withdrawalReceipt{Accepted: true, TxHash: "0xd32f8816", ReceiptStatus: "success", BlockNumber: "42"},
	}
	signatures := &stubSignatureChecker{path: ordersig.PathEOA}
	return &withdrawalHarness{
		server: &Server{
			signatures: signatures,
			withdrawals: &withdrawalService{
				moduleAddress: testWithdrawalModule,
				assets:        []string{testWrappedUSDC, testWrappedCNGN},
				custody:       custody,
				submitter:     submitter,
				limiter:       newWithdrawalLimiter(withdrawalsPerOwnerPerMinute),
				now:           func() time.Time { return testWithdrawalNow },
			},
		},
		custody:    custody,
		submitter:  submitter,
		signatures: signatures,
	}
}

func postWithdrawal(t *testing.T, server *Server, body any) *httptest.ResponseRecorder {
	t.Helper()
	var raw []byte
	if text, ok := body.(string); ok {
		raw = []byte(text)
	} else {
		encoded, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("encode body: %v", err)
		}
		raw = encoded
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/withdrawals", bytes.NewReader(raw))
	rec := httptest.NewRecorder()
	server.handleCreateWithdrawal(rec, req)
	return rec
}

func decodeErrorBody(t *testing.T, rec *httptest.ResponseRecorder) map[string]string {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode %q: %v", rec.Body.String(), err)
	}
	return body
}

func TestWithdrawalIsVerifiedThenSubmittedAndItsReceiptReturned(t *testing.T) {
	h := newWithdrawalHarness()
	rec := postWithdrawal(t, h.server, validWithdrawal())

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control = %q, want no-store", got)
	}
	var receipt withdrawalReceipt
	if err := json.Unmarshal(rec.Body.Bytes(), &receipt); err != nil {
		t.Fatalf("decode receipt: %v", err)
	}
	if receipt != h.submitter.receipt {
		t.Fatalf("receipt = %+v, want %+v", receipt, h.submitter.receipt)
	}
	if !h.signatures.called || h.custody.calls != 1 {
		t.Fatalf("signature checked = %v, custody reads = %d; both must run before submitting", h.signatures.called, h.custody.calls)
	}
	if h.submitter.received == nil || !reflect.DeepEqual(*h.submitter.received, validWithdrawal()) {
		t.Fatalf("submitted %+v, want the request as signed", h.submitter.received)
	}
}

func TestWithdrawalsAreRefusedWhenNotConfigured(t *testing.T) {
	rec := postWithdrawal(t, &Server{}, validWithdrawal())
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", rec.Code)
	}
}

func TestMalformedWithdrawalsAreRefusedBeforeAnyChainRead(t *testing.T) {
	mutate := func(change func(*withdrawalRequest)) withdrawalRequest {
		req := validWithdrawal()
		change(&req)
		return req
	}
	dirtyAsset := validWithdrawal().Action.Data
	dirtyAsset = "0xff" + dirtyAsset[4:]

	cases := []struct {
		name string
		body any
	}{
		{"not JSON", "{"},
		{"an unknown field", `{"action":{},"signature":"0x","recipient":"0x00"}`},
		{"another module", mutate(func(r *withdrawalRequest) { r.Action.Module = "0x12423b366f6f07130961900be00d05ea63acd071" })},
		{"subaccount 0", mutate(func(r *withdrawalRequest) { r.Action.SubaccountID = "0" })},
		{"a non-decimal subaccount", mutate(func(r *withdrawalRequest) { r.Action.SubaccountID = "0x13" })},
		{"a non-decimal nonce", mutate(func(r *withdrawalRequest) { r.Action.Nonce = "-1" })},
		{"a signer other than the owner", mutate(func(r *withdrawalRequest) { r.Action.Signer = "0x00000000000000000000000000000000000000cc" })},
		{"an owner that is not an address", mutate(func(r *withdrawalRequest) { r.Action.Owner = "0xnot-an-address" })},
		{"an expired action", mutate(func(r *withdrawalRequest) { r.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix()-1, 10) })},
		{"an expiry more than an hour ahead", mutate(func(r *withdrawalRequest) { r.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix()+3601, 10) })},
		{"data that is not two words", mutate(func(r *withdrawalRequest) { r.Action.Data += "00" })},
		{"an asset word with dirty high bits", mutate(func(r *withdrawalRequest) { r.Action.Data = dirtyAsset })},
		{"an asset off the allowlist", mutate(func(r *withdrawalRequest) { r.Action.Data = withdrawalDataHex(testLegacyCashAsset, 1_000_000) })},
		{"a zero amount", mutate(func(r *withdrawalRequest) { r.Action.Data = withdrawalDataHex(testWrappedUSDC, 0) })},
		{"a short signature", mutate(func(r *withdrawalRequest) { r.Signature = "0xdeadbeef" })},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newWithdrawalHarness()
			rec := postWithdrawal(t, h.server, tc.body)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d body=%s, want 400", rec.Code, rec.Body.String())
			}
			if h.signatures.called || h.custody.calls != 0 || h.submitter.received != nil {
				t.Fatalf("a malformed withdrawal reached signature=%v custody=%d submit=%v", h.signatures.called, h.custody.calls, h.submitter.received != nil)
			}
		})
	}
}

func TestAWithdrawalExpiringThisSecondIsStillValid(t *testing.T) {
	h := newWithdrawalHarness()
	req := validWithdrawal()
	req.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix(), 10)
	if rec := postWithdrawal(t, h.server, req); rec.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s, want 200", rec.Code, rec.Body.String())
	}
}

// Unlike order submission, a signature that cannot be checked is refused: a withdrawal moves funds.
func TestWithdrawalSignatureFailsClosed(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
	}{
		{"an invalid signature", ordersig.ErrInvalidSignature, http.StatusUnauthorized},
		{"an unverifiable signature", errors.New("eth_getCode: connection refused"), http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newWithdrawalHarness()
			h.signatures.err = tc.err
			rec := postWithdrawal(t, h.server, validWithdrawal())
			if rec.Code != tc.want {
				t.Fatalf("status = %d, want %d", rec.Code, tc.want)
			}
			if h.custody.calls != 0 || h.submitter.received != nil {
				t.Fatal("a withdrawal without a verified signature went on to custody or submission")
			}
		})
	}
}

func TestWithdrawalRequiresTheOwnerMatchingRecords(t *testing.T) {
	for _, tc := range []struct {
		name    string
		owner   string
		err     error
		want    int
		message string
	}{
		{"another owner recorded", "0x3448ac0a3283951a2afd5b3a582329eca43cb47b", nil, http.StatusForbidden, "not owned by action.owner"},
		{"not deposited in Matching", "", fmt.Errorf("subaccount_id 19 is %w", errNotDepositedInMatching), http.StatusBadRequest, "not deposited"},
		{"an unreadable chain", "", errors.New("rpc status 502"), http.StatusServiceUnavailable, "retry shortly"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newWithdrawalHarness()
			h.custody.owner, h.custody.err = tc.owner, tc.err
			rec := postWithdrawal(t, h.server, validWithdrawal())
			if rec.Code != tc.want {
				t.Fatalf("status = %d body=%s, want %d", rec.Code, rec.Body.String(), tc.want)
			}
			if !strings.Contains(decodeErrorBody(t, rec)["error"], tc.message) {
				t.Fatalf("error = %q, want it to mention %q", rec.Body.String(), tc.message)
			}
			if h.submitter.received != nil {
				t.Fatal("a withdrawal for an account the signer does not own was submitted")
			}
		})
	}
}

func TestExecutorVerdictsAreReportedFaithfully(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
		body map[string]string
	}{
		{
			"a reverting withdrawal names its revert",
			&executorWithdrawError{Status: 422, Message: "withdrawal would revert: WERC_CannotBeNegative", Revert: "WERC_CannotBeNegative"},
			http.StatusUnprocessableEntity,
			map[string]string{"error": "withdrawal would revert: WERC_CannotBeNegative", "revert": "WERC_CannotBeNegative"},
		},
		{
			"withdrawals off at the executor",
			&executorWithdrawError{Status: 503, Message: "withdrawals are not enabled on this executor"},
			http.StatusServiceUnavailable,
			nil,
		},
		{
			// The executor may have broadcast before the connection failed, so this is unknown, not failed.
			"an unknown outcome",
			errors.New("post withdrawal to execution-service: context deadline exceeded"),
			http.StatusBadGateway,
			map[string]string{"error": "could not confirm whether the withdrawal was submitted; check the account balance before trying again"},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newWithdrawalHarness()
			h.submitter.err = tc.err
			rec := postWithdrawal(t, h.server, validWithdrawal())
			if rec.Code != tc.want {
				t.Fatalf("status = %d body=%s, want %d", rec.Code, rec.Body.String(), tc.want)
			}
			if tc.body != nil && !reflect.DeepEqual(decodeErrorBody(t, rec), tc.body) {
				t.Fatalf("body = %s, want %v", rec.Body.String(), tc.body)
			}
		})
	}
}

func TestOneWithdrawalInFlightPerOwner(t *testing.T) {
	h := newWithdrawalHarness()
	owner := strings.ToLower(testWithdrawalOwner)
	if !h.server.withdrawals.limiter.acquire(owner, testWithdrawalNow) {
		t.Fatal("setup: first acquire refused")
	}

	rec := postWithdrawal(t, h.server, validWithdrawal())
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want 429 while another withdrawal for the owner is in flight", rec.Code)
	}
	if h.signatures.called || h.submitter.received != nil {
		t.Fatal("a concurrent withdrawal was processed")
	}
}

func TestWithdrawalLimiterReleasesAndCapsPerMinute(t *testing.T) {
	limiter := newWithdrawalLimiter(2)
	owner, other := "0xowner", "0xother"
	start := testWithdrawalNow

	if !limiter.acquire(owner, start) {
		t.Fatal("first withdrawal refused")
	}
	if limiter.acquire(owner, start) {
		t.Fatal("a second withdrawal was admitted while the first is in flight")
	}
	if !limiter.acquire(other, start) {
		t.Fatal("another owner was held back by this owner's withdrawal")
	}
	limiter.release(owner)

	if !limiter.acquire(owner, start.Add(time.Second)) {
		t.Fatal("refused after release, within the per-minute allowance")
	}
	limiter.release(owner)
	if limiter.acquire(owner, start.Add(2*time.Second)) {
		t.Fatal("a third withdrawal inside one minute was admitted with a cap of 2")
	}
	if !limiter.acquire(owner, start.Add(61*time.Second)) {
		t.Fatal("refused once the minute had passed")
	}
}

func TestExecutorWithdrawClientReadsEachVerdict(t *testing.T) {
	for _, tc := range []struct {
		name       string
		status     int
		body       string
		wantErr    string
		wantRevert string
		wantTxHash string
	}{
		{"a receipt", 200, `{"accepted":true,"tx_hash":"0xabc","receipt_status":"success","block_number":"42"}`, "", "", "0xabc"},
		{"a receipt without a hash", 200, `{"accepted":true}`, "no tx_hash", "", ""},
		{"a rejection", 422, `{"error":"withdrawal would revert: BM_NonceAlreadyUsed","revert":"BM_NonceAlreadyUsed"}`, "422", "BM_NonceAlreadyUsed", ""},
		{"a server error", 500, `{"error":"rpc down"}`, "returned 500", "", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var received withdrawalRequest
			executor := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/withdraw" || r.Method != http.MethodPost {
					t.Errorf("request = %s %s, want POST /withdraw", r.Method, r.URL.Path)
				}
				_ = json.NewDecoder(r.Body).Decode(&received)
				w.WriteHeader(tc.status)
				_, _ = w.Write([]byte(tc.body))
			}))
			defer executor.Close()

			client := &executorWithdrawClient{url: executor.URL + "/withdraw", httpClient: executor.Client()}
			receipt, err := client.SubmitWithdrawal(context.Background(), validWithdrawal())

			if !reflect.DeepEqual(received, validWithdrawal()) {
				t.Fatalf("executor received %+v, want the request as signed", received)
			}
			if tc.wantErr == "" {
				if err != nil || receipt.TxHash != tc.wantTxHash {
					t.Fatalf("receipt = %+v err = %v", receipt, err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("err = %v, want it to mention %q", err, tc.wantErr)
			}
			var rejected *executorWithdrawError
			if tc.wantRevert != "" && (!errors.As(err, &rejected) || rejected.Revert != tc.wantRevert) {
				t.Fatalf("err = %#v, want an executorWithdrawError naming %s", err, tc.wantRevert)
			}
		})
	}
}

func withdrawalAddressWord(address string) string {
	return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(strings.ToLower(address), "0x")
}

func TestDepositedOwnerReadsWhoMatchingRecords(t *testing.T) {
	const recorded = "0xeabca823b4d35d8f2eac09edb55c42d8077fbfca"

	for _, tc := range []struct {
		name        string
		holder      string
		holderError string
		rpcStatus   int
		wantOwner   string
		notDeposit  bool
		otherError  bool
	}{
		{name: "held by Matching", holder: testMatchingContract, wantOwner: recorded},
		{name: "held by the wallet itself", holder: recorded, notDeposit: true},
		{name: "a subaccount that does not exist", holderError: "execution reverted", notDeposit: true},
		{name: "an RPC outage", rpcStatus: http.StatusBadGateway, otherError: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rpc := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if tc.rpcStatus != 0 {
					w.WriteHeader(tc.rpcStatus)
					return
				}
				var call struct {
					Params []struct {
						Data string `json:"data"`
					} `json:"params"`
				}
				_ = json.NewDecoder(r.Body).Decode(&call)
				data := strings.ToLower(call.Params[0].Data)
				switch {
				case strings.HasPrefix(data, "0x779e5012"):
					fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":%q}`, withdrawalAddressWord(testSubAccountsAddress))
				case strings.HasPrefix(data, "0x6352211e") && tc.holderError != "":
					fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"error":{"code":3,"message":%q}}`, tc.holderError)
				case strings.HasPrefix(data, "0x6352211e"):
					fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":%q}`, withdrawalAddressWord(tc.holder))
				case strings.HasPrefix(data, "0x63f1ddaa"):
					fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":%q}`, withdrawalAddressWord(recorded))
				default:
					t.Errorf("unexpected eth_call data %s", data)
				}
			}))
			defer rpc.Close()

			checker := &chainCustodyChecker{rpcURL: rpc.URL, matchingAddress: testMatchingContract, httpClient: rpc.Client()}
			owner, err := checker.DepositedOwner(context.Background(), "19")

			switch {
			case tc.wantOwner != "":
				if err != nil || owner != tc.wantOwner {
					t.Fatalf("owner = %q err = %v, want %q", owner, err, tc.wantOwner)
				}
			case tc.notDeposit:
				if !errors.Is(err, errNotDepositedInMatching) {
					t.Fatalf("err = %v, want errNotDepositedInMatching", err)
				}
			case tc.otherError:
				if err == nil || errors.Is(err, errNotDepositedInMatching) {
					t.Fatalf("err = %v, want a chain-read failure that is not reported as not-deposited", err)
				}
			}
		})
	}
}
