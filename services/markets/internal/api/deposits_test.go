package api

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/sha3"

	"github.com/numofx/matching-backend/internal/ordersig"
)

const (
	testDepositModule = "0x6540f8d9eb599b045c05e45cb6a5b1730a806658"
	testPerpCash      = "0xa74e49b4ed7cb176bc02ef4d8a1a3240c9ad4272"
	testDepositSRM    = "0xde0423d0a1e15536265c9513d2e0c10dab5835d4"
	testOldSRM        = "0x3195bd7e02d93982bcf8b34df5b941ffcae1e49b"
	testCNGNEscrow    = "0x37c976bb5d4887a714ef19af6b83e34fe2f37c98"
	testUSDCToken     = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
)

func depositDataHex(amount *big.Int, asset, manager string) string {
	return "0x" + fmt.Sprintf("%064x", amount) +
		strings.Repeat("0", 24) + strings.TrimPrefix(asset, "0x") +
		strings.Repeat("0", 24) + strings.TrimPrefix(manager, "0x")
}

func usdc(units int64) *big.Int { return big.NewInt(units * 1_000_000) }

// validDeposit opens a perp account with 1,000 USDC, as a trader would sign it.
func validDeposit() depositRequest {
	return depositRequest{
		Action: withdrawalAction{
			SubaccountID: "0",
			Nonce:        "7",
			Module:       testDepositModule,
			Data:         depositDataHex(usdc(1_000), testPerpCash, testDepositSRM),
			Expiry:       strconv.FormatInt(testWithdrawalNow.Unix()+600, 10),
			Owner:        testWithdrawalOwner,
			Signer:       testWithdrawalOwner,
		},
		Signature: "0x" + strings.Repeat("ab", 65),
	}
}

// fakeDepositChain answers as the chain would for a funded, approved owner with no account yet.
type fakeDepositChain struct {
	nonceUsed bool
	owner     string
	ownerErr  error
	manager   string
	balance   *big.Int
	allowance *big.Int
	readErr   error
}

func (f *fakeDepositChain) NonceUsed(context.Context, string, string, *big.Int) (bool, error) {
	return f.nonceUsed, f.readErr
}
func (f *fakeDepositChain) DepositedOwner(context.Context, string) (string, error) {
	return f.owner, f.ownerErr
}
func (f *fakeDepositChain) AccountManager(context.Context, string) (string, error) {
	return f.manager, nil
}
func (f *fakeDepositChain) WrappedToken(context.Context, string) (string, error) {
	return testUSDCToken, nil
}
func (f *fakeDepositChain) TokenBalance(context.Context, string, string) (*big.Int, error) {
	return f.balance, nil
}
func (f *fakeDepositChain) TokenAllowance(context.Context, string, string, string) (*big.Int, error) {
	return f.allowance, nil
}

type fakeDepositSubmitter struct {
	receipt  depositReceipt
	err      error
	received *depositRequest
}

func (f *fakeDepositSubmitter) SubmitDeposit(_ context.Context, request depositRequest) (depositReceipt, error) {
	f.received = &request
	return f.receipt, f.err
}

type depositHarness struct {
	server     *Server
	chain      *fakeDepositChain
	submitter  *fakeDepositSubmitter
	signatures *stubSignatureChecker
}

func newDepositHarness() *depositHarness {
	chain := &fakeDepositChain{
		owner:     strings.ToLower(testWithdrawalOwner),
		manager:   testDepositSRM,
		balance:   usdc(5_000),
		allowance: usdc(5_000),
	}
	submitter := &fakeDepositSubmitter{receipt: depositReceipt{
		Accepted: true, TxHash: "0xd5", ReceiptStatus: "success", BlockNumber: "42", SubaccountID: "27",
		AmountUSDC: "1000.000000", AmountUnits: "1000000000", CreditedCashE18: "1000000000000000000000",
	}}
	signatures := &stubSignatureChecker{path: ordersig.PathEOA}
	return &depositHarness{
		server: &Server{
			signatures: signatures,
			deposits: &depositService{
				moduleAddress: testDepositModule,
				assets:        []string{testPerpCash},
				manager:       testDepositSRM,
				minAmount:     usdc(10),
				chain:         chain,
				submitter:     submitter,
				limiter:       newWithdrawalLimiter(3),
				now:           func() time.Time { return testWithdrawalNow },
			},
		},
		chain:      chain,
		submitter:  submitter,
		signatures: signatures,
	}
}

func postDeposit(t *testing.T, server *Server, body any) *httptest.ResponseRecorder {
	t.Helper()
	encoded, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("encode body: %v", err)
	}
	rec := httptest.NewRecorder()
	server.handleCreateDeposit(rec, httptest.NewRequest(http.MethodPost, "/v1/deposits", bytes.NewReader(encoded)))
	return rec
}

func expectDeposit(t *testing.T, rec *httptest.ResponseRecorder, status int, contains string) {
	t.Helper()
	if rec.Code != status {
		t.Fatalf("status = %d, want %d; body=%s", rec.Code, status, rec.Body.String())
	}
	if contains != "" && !strings.Contains(rec.Body.String(), contains) {
		t.Fatalf("body %s does not mention %q", rec.Body.String(), contains)
	}
}

func TestDepositIsCheckedSubmittedAndAnsweredWithTheAccountAndBothUnits(t *testing.T) {
	h := newDepositHarness()
	rec := postDeposit(t, h.server, validDeposit())
	expectDeposit(t, rec, http.StatusOK, "")
	var got depositReceipt
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.SubaccountID != "27" || got.AmountUSDC != "1000.000000" || got.AmountUnits != "1000000000" || got.CreditedCashE18 != "1000000000000000000000" {
		t.Fatalf("receipt = %+v", got)
	}
	if h.submitter.received == nil || !h.signatures.called {
		t.Fatal("a valid deposit must be signature-checked and submitted")
	}
}

// One rule each, by breaking exactly one field. None of these may reach the executor.
func TestDepositRequestRules(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(*depositRequest)
		want   string
	}{
		{"another module", func(r *depositRequest) { r.Action.Module = testWithdrawalModule }, "deposit module"},
		{"a signer that is not the owner (session key)", func(r *depositRequest) {
			r.Action.Signer = "0x1661aa54fa390cd916722f971e4a9fe4c01889fb"
		}, "session-key deposits are not supported"},
		{"an expired action", func(r *depositRequest) { r.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix()-1, 10) }, "expired"},
		{"an expiry more than an hour ahead", func(r *depositRequest) {
			r.Action.Expiry = strconv.FormatInt(testWithdrawalNow.Unix()+3601, 10)
		}, "at most one hour"},
		// Accepted on chain (DepositModuleFork.testContractAcceptsADifferentWrappedAsset): only this stops it.
		{"the cNGN escrow", func(r *depositRequest) {
			r.Action.Data = depositDataHex(usdc(1_000), testCNGNEscrow, testDepositSRM)
		}, "not depositable"},
		// On chain the max sentinel deposits the owner's whole balance (testContractTreatsMaxAmountAsTheWholeBalance).
		{"the max sentinel", func(r *depositRequest) { r.Action.Data = depositDataHex(maxUint256, testPerpCash, testDepositSRM) }, "must be explicit"},
		{"below the minimum", func(r *depositRequest) {
			r.Action.Data = depositDataHex(big.NewInt(9_999_999), testPerpCash, testDepositSRM)
		}, "9.999999 USDC is below the minimum 10.000000 USDC"},
		// The perp CashAsset reverts MW_UnknownManager on chain (testCashAssetRejectsADifferentManager).
		{"a new account under another manager", func(r *depositRequest) {
			r.Action.Data = depositDataHex(usdc(1_000), testPerpCash, testOldSRM)
		}, "perp risk manager"},
		{"a top-up naming another manager", func(r *depositRequest) {
			r.Action.SubaccountID = "24"
			r.Action.Data = depositDataHex(usdc(1_000), testPerpCash, testOldSRM)
		}, "or zero for an existing account"},
		{"data that is not three words", func(r *depositRequest) { r.Action.Data = "0x1234" }, "exactly 96 bytes"},
		{"a dirty address word", func(r *depositRequest) { r.Action.Data = r.Action.Data[:66] + "ff" + r.Action.Data[68:] }, "left-padded"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newDepositHarness()
			req := validDeposit()
			tc.mutate(&req)
			expectDeposit(t, postDeposit(t, h.server, req), http.StatusBadRequest, tc.want)
			if h.submitter.received != nil {
				t.Fatal("a refused deposit reached the executor")
			}
		})
	}
}

func TestDepositRefusesUnknownFields(t *testing.T) {
	h := newDepositHarness()
	body := map[string]any{"action": validDeposit().Action, "signature": validDeposit().Signature, "permit": "0x"}
	expectDeposit(t, postDeposit(t, h.server, body), http.StatusBadRequest, "invalid JSON body")
}

func TestDepositRejectsABadSignatureWith401(t *testing.T) {
	h := newDepositHarness()
	h.signatures.err = ordersig.ErrInvalidSignature
	expectDeposit(t, postDeposit(t, h.server, validDeposit()), http.StatusUnauthorized, "")
}

// What the simulation would find, read first so each is a 400 that says what to do.
func TestDepositPreflight(t *testing.T) {
	cases := []struct {
		name   string
		setup  func(*depositHarness, *depositRequest)
		status int
		want   string
	}{
		{"a spent nonce", func(h *depositHarness, _ *depositRequest) { h.chain.nonceUsed = true }, 400, "already used"},
		{"a balance below the amount", func(h *depositHarness, _ *depositRequest) { h.chain.balance = usdc(999) }, 400, "holds 999.000000 USDC"},
		{"an allowance below the amount", func(h *depositHarness, _ *depositRequest) { h.chain.allowance = usdc(999) }, 400, "approve " + testDepositModule},
		{"a top-up of someone else's account", func(h *depositHarness, r *depositRequest) {
			r.Action.SubaccountID = "24"
			h.chain.owner = "0x1661aa54fa390cd916722f971e4a9fe4c01889fb"
		}, 400, "not owned by action.owner"},
		{"a top-up of an account Matching does not hold", func(h *depositHarness, r *depositRequest) {
			r.Action.SubaccountID = "24"
			h.chain.ownerErr = fmt.Errorf("subaccount_id 24 is %w", errNotDepositedInMatching)
		}, 400, "not deposited in matching"},
		// Would revert MW_UnknownManager in the CashAsset.
		{"a top-up of an account under another manager", func(h *depositHarness, r *depositRequest) {
			r.Action.SubaccountID = "15"
			h.chain.manager = testOldSRM
		}, 400, "can only be deposited into a perp account"},
		{"a chain read that fails", func(h *depositHarness, _ *depositRequest) { h.chain.readErr = errors.New("rpc down") }, 503, "retry shortly"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newDepositHarness()
			req := validDeposit()
			tc.setup(h, &req)
			expectDeposit(t, postDeposit(t, h.server, req), tc.status, tc.want)
			if h.submitter.received != nil {
				t.Fatal("a preflight refusal reached the executor")
			}
		})
	}
}

// The reverts seen on the Base fork, if they still happen after preflight (a race), each come back as a 400.
func TestDepositExecutorRevertsMapToClear400s(t *testing.T) {
	for revert, want := range map[string]string{
		"MW_UnknownManager":                        "perp risk manager",
		"BM_NonceAlreadyUsed":                      "new nonce",
		"OV_ActionExpired":                         "sign a fresh one",
		"OV_SignerNotOwnerOrSessionKeyExpired":     "signer is not action.owner",
		"OV_InvalidActionOwner":                    "not owned by action.owner",
		"ERC20: transfer amount exceeds allowance": "approve " + testDepositModule,
		"ERC20: transfer amount exceeds balance":   "balance is below",
	} {
		t.Run(revert, func(t *testing.T) {
			h := newDepositHarness()
			h.submitter.err = &executorWithdrawError{Status: http.StatusUnprocessableEntity, Message: "deposit would revert", Revert: revert}
			rec := postDeposit(t, h.server, validDeposit())
			expectDeposit(t, rec, http.StatusBadRequest, want)
			if decodeErrorBody(t, rec)["revert"] != revert {
				t.Fatalf("the revert name must be kept: %s", rec.Body.String())
			}
		})
	}
}

func TestDepositUnknownRevertStays422(t *testing.T) {
	h := newDepositHarness()
	h.submitter.err = &executorWithdrawError{Status: http.StatusUnprocessableEntity, Message: "deposit would revert: BM_AssetCapExceeded", Revert: "BM_AssetCapExceeded"}
	expectDeposit(t, postDeposit(t, h.server, validDeposit()), http.StatusUnprocessableEntity, "BM_AssetCapExceeded")
}

func TestDepositsAre503WhenOff(t *testing.T) {
	expectDeposit(t, postDeposit(t, &Server{signatures: &stubSignatureChecker{}}, validDeposit()), http.StatusServiceUnavailable, "not enabled")
}

func TestDepositUnitsChangeInOnePlace(t *testing.T) {
	if got := depositUnitsToLedger(usdc(1_000)); got.String() != "1000000000000000000000" {
		t.Fatalf("1000 USDC = %s at 18dp", got)
	}
	if got := formatDepositUnits(big.NewInt(10_000_001)); got != "10.000001" {
		t.Fatalf("format = %s", got)
	}
}

func TestDepositSelectorsMatchTheirSignatures(t *testing.T) {
	for sig, want := range map[string]string{
		"usedNonces(address,uint256)": sigUsedNonces,
		"manager(uint256)":            sigManagerOf,
		"wrappedAsset()":              sigWrapped,
		"balanceOf(address)":          sigBalanceOf,
		"allowance(address,address)":  sigAllowanceOf,
	} {
		h := sha3.NewLegacyKeccak256()
		h.Write([]byte(sig))
		if got := "0x" + hex.EncodeToString(h.Sum(nil)[:4]); got != want {
			t.Fatalf("%s: selector %s, constant %s", sig, got, want)
		}
	}
}

// The preflight readers against Base itself, so their selectors and decoding are proven on the real contracts, not
// only against fakes. Read-only. Skipped without BASE_RPC_URL, like the contract fork suites.
func TestDepositChainReaderAgainstBase(t *testing.T) {
	rpc := strings.TrimSpace(os.Getenv("BASE_RPC_URL"))
	if rpc == "" {
		t.Skip("BASE_RPC_URL not set")
	}
	ctx := context.Background()
	chain := &chainDepositReader{chainCustodyChecker: &chainCustodyChecker{
		rpcURL: rpc, matchingAddress: testMatchingContract, httpClient: &http.Client{Timeout: 15 * time.Second},
	}}
	mm := "0x3448ac0a3283951a2afd5b3a582329eca43cb47b"

	if got, err := chain.AccountManager(ctx, "24"); err != nil || got != testDepositSRM {
		t.Fatalf("manager(24) = %s, %v; want the perp SRM", got, err)
	}
	// The retired spot account: a top-up of it must be refused before it reverts MW_UnknownManager.
	if got, err := chain.AccountManager(ctx, "15"); err != nil || got != testOldSRM {
		t.Fatalf("manager(15) = %s, %v; want the retired spot SRM", got, err)
	}
	if got, err := chain.DepositedOwner(ctx, "24"); err != nil || got != mm {
		t.Fatalf("owner(24) = %s, %v; want the market maker", got, err)
	}
	if got, err := chain.WrappedToken(ctx, testPerpCash); err != nil || got != testUSDCToken {
		t.Fatalf("perp cash wraps %s, %v; want USDC", got, err)
	}
	if used, err := chain.NonceUsed(ctx, testDepositModule, mm, big.NewInt(1)); err != nil || used {
		t.Fatalf("usedNonces(mm, 1) = %v, %v; want false", used, err)
	}
	if bal, err := chain.TokenBalance(ctx, testUSDCToken, testPerpCash); err != nil || bal.Sign() <= 0 {
		t.Fatalf("USDC held by the perp cash = %v, %v; want > 0", bal, err)
	}
	if allowance, err := chain.TokenAllowance(ctx, testUSDCToken, mm, testDepositModule); err != nil || allowance == nil {
		t.Fatalf("allowance read failed: %v", err)
	}
}
