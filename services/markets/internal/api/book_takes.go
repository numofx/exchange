package api

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/ordersig"
)

// bookTakesPerOwnerPerMinute bounds how fast one owner can spend the executor's gas on takes.
const bookTakesPerOwnerPerMinute = 20

// bookTakeService is everything POST /book-takes needs. Nil means book takes are not fully configured, and the
// endpoint answers 503 rather than accept anything it cannot completely check.
type bookTakeService struct {
	moduleAddress string
	books         []string
	custody       withdrawalCustody
	submitter     withdrawalSubmitter
	limiter       *withdrawalLimiter
	now           func() time.Time
}

func newBookTakeService(cfg config.Config, signatures signatureChecker) *bookTakeService {
	moduleAddress := strings.ToLower(strings.TrimSpace(cfg.BookTakeModuleAddress))
	if !isHexAddress(moduleAddress) || strings.TrimSpace(cfg.ExecutorBookTakeURL) == "" || len(cfg.BookTakeBooks) == 0 {
		return nil
	}
	// A take moves the trader's position and cash, so a missing verifier or chain reader disables it.
	if signatures == nil || !isHexAddress(cfg.MatchingAddress) || strings.TrimSpace(cfg.ChainRPCURL) == "" {
		slog.Warn("book_takes_disabled", "reason", "signature verifier, MATCHING_ADDRESS or CHAIN_RPC_URL is not configured")
		return nil
	}
	return &bookTakeService{
		moduleAddress: moduleAddress,
		books:         cfg.BookTakeBooks,
		custody: &chainCustodyChecker{
			rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
			matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
			httpClient:      &http.Client{Timeout: 5 * time.Second},
		},
		// execution-service's POST /book-take answers in the withdrawal shape: a receipt, or 422/503 with a reason.
		submitter: &executorWithdrawClient{
			url:        strings.TrimSpace(cfg.ExecutorBookTakeURL),
			httpClient: &http.Client{Timeout: cfg.ExecutorWithdrawTimeout},
		},
		limiter: newWithdrawalLimiter(bookTakesPerOwnerPerMinute),
		now:     time.Now,
	}
}

// handleCreateBookTake serves POST /book-takes: a trader's signed take on an OnchainBook for a subaccount Matching
// holds, submitted by execution-service through BookTakeModule. The venue pays the gas. Every check fails closed,
// as for withdrawals:
//
//  1. the request itself — module, subaccount, owner and signer, expiry, the take's book and fields, signature (400)
//  2. one take in flight per owner, and a bounded rate (429)
//  3. the signature authorizes the action (401)
//  4. Matching holds the subaccount (400) and records action.owner as its owner (403)
//  5. execution-service's verdict: 200 with the receipt, or 422 with the revert its simulation hit (OB_BelowMinFill,
//     OB_FeeTooHigh, BTM_NotReducing, ...)
func (s *Server) handleCreateBookTake(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	svc := s.bookTakes
	if svc == nil || s.signatures == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "book takes are not enabled"})
		return
	}

	var req withdrawalRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, withdrawalMaxBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	if err := svc.validate(req); err != nil {
		slog.Info("book_take_rejected", "stage", "request", "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusBadRequest, errorBody(err))
		return
	}

	owner := strings.ToLower(strings.TrimSpace(req.Action.Owner))
	if !svc.limiter.acquire(owner, svc.now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{
			"error": "a take for this owner is already in progress, or too many were requested; retry shortly",
		})
		return
	}
	defer svc.limiter.release(owner)

	if _, err := s.signatures.Verify(r.Context(), withdrawalOrdersigAction(req.Action), req.Signature, req.Action.Signer); err != nil {
		if errors.Is(err, ordersig.ErrInvalidSignature) {
			slog.Info("book_take_rejected", "stage", "signature", "owner", owner, "subaccount_id", req.Action.SubaccountID)
			writeJSON(w, http.StatusUnauthorized, errorBody(err))
			return
		}
		slog.Warn("book_take_signature_unverifiable", "owner", owner, "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the signature could not be verified; retry shortly"})
		return
	}

	recordedOwner, err := svc.custody.DepositedOwner(r.Context(), req.Action.SubaccountID)
	if err != nil {
		if errors.Is(err, errNotDepositedInMatching) {
			writeJSON(w, http.StatusBadRequest, errorBody(err))
			return
		}
		slog.Warn("book_take_custody_unreadable", "owner", owner, "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the subaccount's owner could not be read from the chain; retry shortly"})
		return
	}
	if recordedOwner != owner {
		slog.Warn("book_take_rejected", "stage", "custody", "owner", owner, "recorded_owner", recordedOwner, "subaccount_id", req.Action.SubaccountID)
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": fmt.Sprintf("subaccount_id %s is not owned by action.owner", req.Action.SubaccountID),
		})
		return
	}

	receipt, err := svc.submitter.SubmitWithdrawal(r.Context(), req)
	if err != nil {
		writeBookTakeSubmitError(w, req, err)
		return
	}
	slog.Info("book_take_submitted", "owner", owner, "subaccount_id", req.Action.SubaccountID, "nonce", req.Action.Nonce,
		"tx_hash", receipt.TxHash, "receipt_status", receipt.ReceiptStatus, "accepted", receipt.Accepted)
	writeJSON(w, http.StatusOK, receipt)
}

func writeBookTakeSubmitError(w http.ResponseWriter, req withdrawalRequest, err error) {
	var rejected *executorWithdrawError
	if errors.As(err, &rejected) {
		switch rejected.Status {
		case http.StatusUnprocessableEntity:
			body := map[string]string{"error": rejected.Message}
			if rejected.Revert != "" {
				body["revert"] = rejected.Revert
			}
			slog.Info("book_take_rejected", "stage", "executor", "subaccount_id", req.Action.SubaccountID, "revert", rejected.Revert, "error", rejected.Message)
			writeJSON(w, http.StatusUnprocessableEntity, body)
			return
		case http.StatusServiceUnavailable:
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": nonEmpty(rejected.Message, "book takes are not enabled on the executor")})
			return
		}
	}
	// The executor may have broadcast before this failed: the outcome is unknown, not failed. Resending the same
	// signed action is safe (its nonce is spent once); a freshly signed one could trade twice.
	slog.Error("book_take_submit_failed", "subaccount_id", req.Action.SubaccountID, "nonce", req.Action.Nonce, "error", err)
	writeJSON(w, http.StatusBadGateway, map[string]string{
		"error": "could not confirm whether the take was submitted; check the position before trying again",
	})
}

// validate refuses a take that is malformed or that the executor would refuse anyway, before any chain read.
func (svc *bookTakeService) validate(req withdrawalRequest) error {
	action := req.Action
	subaccountID, err := parseUint256Decimal("action.subaccount_id", action.SubaccountID)
	if err != nil {
		return err
	}
	if subaccountID.Sign() == 0 {
		return errors.New("action.subaccount_id must not be 0")
	}
	if _, err := parseUint256Decimal("action.nonce", action.Nonce); err != nil {
		return err
	}
	expiry, err := parseUint256Decimal("action.expiry", action.Expiry)
	if err != nil {
		return err
	}
	for _, field := range []struct{ name, value string }{
		{"action.module", action.Module},
		{"action.owner", action.Owner},
		{"action.signer", action.Signer},
	} {
		if !isHexAddress(field.value) {
			return fmt.Errorf("%s must be an address", field.name)
		}
	}
	if strings.ToLower(strings.TrimSpace(action.Module)) != svc.moduleAddress {
		return fmt.Errorf("action.module must be the book-take module %s", svc.moduleAddress)
	}
	if !strings.EqualFold(strings.TrimSpace(action.Owner), strings.TrimSpace(action.Signer)) {
		return errors.New("action.signer must be action.owner; session-key takes are not supported")
	}
	now := svc.now().Unix()
	if expiry.Cmp(big.NewInt(now)) < 0 {
		return errors.New("action has expired")
	}
	if expiry.Cmp(big.NewInt(now+int64(withdrawalMaxLifetime/time.Second))) > 0 {
		return errors.New("action.expiry may be at most one hour ahead")
	}
	take, err := decodeBookTakeData(action.Data)
	if err != nil {
		return err
	}
	if !svc.allowsBook(take.book) {
		return fmt.Errorf("book %s is not traded through the venue", take.book)
	}
	if take.amount.Sign() == 0 {
		return errors.New("take amount must be greater than 0")
	}
	if take.limitPrice.Sign() == 0 {
		return errors.New("limitPrice must be greater than 0")
	}
	if take.maxLevels == 0 {
		return errors.New("maxLevels must be greater than 0")
	}
	if take.deadline < uint64(now) {
		return errors.New("take deadline has passed")
	}
	if !isSignatureHex(req.Signature) {
		return errors.New("signature must be hex of at least 65 bytes")
	}
	return nil
}

func (svc *bookTakeService) allowsBook(book string) bool {
	for _, allowed := range svc.books {
		if allowed == book {
			return true
		}
	}
	return false
}

// bookTakeData is IBookTakeModule.BookTakeData, decoded.
type bookTakeData struct {
	book       string
	marketID   *big.Int
	isBuy      bool
	amount     *big.Int
	limitPrice *big.Int
	minFill    *big.Int
	maxFee     *big.Int
	deadline   uint64
	maxLevels  uint64
	reduceOnly bool
}

// decodeBookTakeData reads abi.encode(BookTakeData): exactly ten static words. A word with dirty high bits where
// the type is narrower (the book address, the bools, the uint64 deadline, the uint16 maxLevels) is refused, as
// Solidity's abi.decode would revert on it.
func decodeBookTakeData(data string) (bookTakeData, error) {
	raw := strings.TrimPrefix(strings.TrimSpace(data), "0x")
	if len(raw) != 640 {
		return bookTakeData{}, errors.New("action.data must be abi.encode(BookTakeData): exactly ten 32-byte words")
	}
	bytes, err := hex.DecodeString(raw)
	if err != nil {
		return bookTakeData{}, errors.New("action.data must be hex")
	}
	word := func(i int) []byte { return bytes[i*32 : (i+1)*32] }
	zeroHigh := func(i, keep int) bool {
		for _, b := range word(i)[:32-keep] {
			if b != 0 {
				return false
			}
		}
		return true
	}
	if !zeroHigh(0, 20) {
		return bookTakeData{}, errors.New("action.data book word is not a left-padded address")
	}
	for _, field := range []struct {
		i    int
		name string
	}{{2, "isBuy"}, {9, "reduceOnly"}} {
		if !zeroHigh(field.i, 1) || word(field.i)[31] > 1 {
			return bookTakeData{}, fmt.Errorf("action.data %s is not a bool", field.name)
		}
	}
	if !zeroHigh(7, 8) {
		return bookTakeData{}, errors.New("action.data deadline is not a uint64")
	}
	if !zeroHigh(8, 2) {
		return bookTakeData{}, errors.New("action.data maxLevels is not a uint16")
	}
	num := func(i int) *big.Int { return new(big.Int).SetBytes(word(i)) }
	return bookTakeData{
		book:       "0x" + hex.EncodeToString(word(0)[12:]),
		marketID:   num(1),
		isBuy:      word(2)[31] == 1,
		amount:     num(3),
		limitPrice: num(4),
		minFill:    num(5),
		maxFee:     num(6),
		deadline:   num(7).Uint64(),
		maxLevels:  num(8).Uint64(),
		reduceOnly: word(9)[31] == 1,
	}, nil
}
