package api

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/ordersig"
)

const (
	// withdrawalMaxBodyBytes bounds a withdrawal request; a real one is well under 2 KB.
	withdrawalMaxBodyBytes = 64 << 10
	// withdrawalMaxLifetime caps how far ahead a signed withdrawal may expire. A long-lived signature is a
	// standing authorization to move funds, and a client signs a fresh one for every withdrawal.
	withdrawalMaxLifetime = time.Hour
	// withdrawalsPerOwnerPerMinute caps how often one owner can make the executor simulate, and potentially
	// pay gas for, a withdrawal.
	withdrawalsPerOwnerPerMinute = 5
)

type withdrawalAction struct {
	SubaccountID string `json:"subaccount_id"`
	Nonce        string `json:"nonce"`
	Module       string `json:"module"`
	Data         string `json:"data"`
	Expiry       string `json:"expiry"`
	Owner        string `json:"owner"`
	Signer       string `json:"signer"`
}

// withdrawalRequest is one user-signed WithdrawalModule action, in the shape execution-service's POST /withdraw
// accepts. `data` is abi.encode(address asset, uint256 amount), with the amount in the token's native decimals.
type withdrawalRequest struct {
	Action    withdrawalAction `json:"action"`
	Signature string           `json:"signature"`
}

// withdrawalReceipt is execution-service's answer for a submitted withdrawal. ReceiptStatus "timeout" means the
// transaction was broadcast and its outcome is not known yet; "reverted" means it mined and moved nothing.
type withdrawalReceipt struct {
	Accepted      bool   `json:"accepted"`
	TxHash        string `json:"tx_hash"`
	ReceiptStatus string `json:"receipt_status,omitempty"`
	BlockNumber   string `json:"block_number,omitempty"`
}

type withdrawalCustody interface {
	// DepositedOwner returns the owner Matching records for a subaccount it holds, or an error wrapping
	// errNotDepositedInMatching when Matching does not hold it.
	DepositedOwner(ctx context.Context, subaccountID string) (string, error)
}

type withdrawalSubmitter interface {
	SubmitWithdrawal(ctx context.Context, request withdrawalRequest) (withdrawalReceipt, error)
}

// withdrawalService is everything POST /v1/withdrawals needs. A nil service means withdrawals are not fully
// configured, and the endpoint answers 503 rather than accept anything it cannot completely check.
type withdrawalService struct {
	moduleAddress string
	assets        []string
	custody       withdrawalCustody
	submitter     withdrawalSubmitter
	limiter       *withdrawalLimiter
	now           func() time.Time
}

func newWithdrawalService(cfg config.Config, signatures signatureChecker) *withdrawalService {
	moduleAddress := strings.ToLower(strings.TrimSpace(cfg.WithdrawalModuleAddress))
	if !isHexAddress(moduleAddress) || strings.TrimSpace(cfg.ExecutorWithdrawURL) == "" || len(cfg.WithdrawalAssetAddresses) == 0 {
		return nil
	}
	// Every check the endpoint makes must be able to run. A withdrawal moves funds, so a missing verifier or
	// chain reader disables it rather than letting a request through half-checked.
	if signatures == nil || !isHexAddress(cfg.MatchingAddress) || strings.TrimSpace(cfg.ChainRPCURL) == "" {
		slog.Warn("withdrawals_disabled", "reason", "signature verifier, MATCHING_ADDRESS or CHAIN_RPC_URL is not configured")
		return nil
	}

	return &withdrawalService{
		moduleAddress: moduleAddress,
		assets:        cfg.WithdrawalAssetAddresses,
		custody: &chainCustodyChecker{
			rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
			matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
			httpClient:      &http.Client{Timeout: 5 * time.Second},
		},
		submitter: &executorWithdrawClient{
			url:        strings.TrimSpace(cfg.ExecutorWithdrawURL),
			httpClient: &http.Client{Timeout: cfg.ExecutorWithdrawTimeout},
		},
		limiter: newWithdrawalLimiter(withdrawalsPerOwnerPerMinute),
		now:     time.Now,
	}
}

// handleCreateWithdrawal serves POST /v1/withdrawals: a trader's signed withdrawal from a subaccount held by
// Matching, submitted by execution-service through the WithdrawalModule.
//
// Unlike order submission, every check here fails closed: a signature that cannot be verified, or an owner that
// cannot be read from the chain, is refused rather than waved through, because what follows is a transaction
// the venue pays for that moves the trader's funds. In order:
//
//  1. the request itself — module, subaccount, owner and signer, expiry, asset, amount, signature shape (400)
//  2. one withdrawal in flight per owner, and at most a few a minute (429)
//  3. the signature authorizes the action (401)
//  4. Matching holds the subaccount (400) and records action.owner as its owner (403)
//  5. execution-service's verdict: 200 with the receipt, or 422 with the revert that the simulation hit
func (s *Server) handleCreateWithdrawal(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")

	svc := s.withdrawals
	if svc == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "withdrawals are not enabled"})
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
		slog.Info("withdrawal_rejected", "stage", "request", "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	owner := strings.ToLower(strings.TrimSpace(req.Action.Owner))
	if !svc.limiter.acquire(owner, svc.now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{
			"error": "a withdrawal for this owner is already in progress, or too many were requested; retry shortly",
		})
		return
	}
	defer svc.limiter.release(owner)

	if s.signatures == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "withdrawals are not enabled"})
		return
	}
	if _, err := s.signatures.Verify(r.Context(), withdrawalOrdersigAction(req.Action), req.Signature, req.Action.Signer); err != nil {
		if errors.Is(err, ordersig.ErrInvalidSignature) {
			slog.Info("withdrawal_rejected", "stage", "signature", "owner", owner, "subaccount_id", req.Action.SubaccountID)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
			return
		}
		slog.Warn("withdrawal_signature_unverifiable", "owner", owner, "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the signature could not be verified; retry shortly"})
		return
	}

	recordedOwner, err := svc.custody.DepositedOwner(r.Context(), req.Action.SubaccountID)
	if err != nil {
		if errors.Is(err, errNotDepositedInMatching) {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		slog.Warn("withdrawal_custody_unreadable", "owner", owner, "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the subaccount's owner could not be read from the chain; retry shortly"})
		return
	}
	if recordedOwner != owner {
		slog.Warn("withdrawal_rejected", "stage", "custody", "owner", owner, "recorded_owner", recordedOwner, "subaccount_id", req.Action.SubaccountID)
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error": fmt.Sprintf("subaccount_id %s is not owned by action.owner", req.Action.SubaccountID),
		})
		return
	}

	receipt, err := svc.submitter.SubmitWithdrawal(r.Context(), req)
	if err != nil {
		writeWithdrawalSubmitError(w, req, err)
		return
	}

	slog.Info(
		"withdrawal_submitted",
		"owner", owner,
		"subaccount_id", req.Action.SubaccountID,
		"nonce", req.Action.Nonce,
		"tx_hash", receipt.TxHash,
		"receipt_status", receipt.ReceiptStatus,
		"accepted", receipt.Accepted,
	)
	writeJSON(w, http.StatusOK, receipt)
}

func writeWithdrawalSubmitError(w http.ResponseWriter, req withdrawalRequest, err error) {
	var rejected *executorWithdrawError
	if errors.As(err, &rejected) {
		switch rejected.Status {
		case http.StatusUnprocessableEntity:
			body := map[string]string{"error": rejected.Message}
			if rejected.Revert != "" {
				body["revert"] = rejected.Revert
			}
			slog.Info("withdrawal_rejected", "stage", "executor", "subaccount_id", req.Action.SubaccountID, "revert", rejected.Revert, "error", rejected.Message)
			writeJSON(w, http.StatusUnprocessableEntity, body)
			return
		case http.StatusServiceUnavailable:
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "withdrawals are not enabled on the executor"})
			return
		}
	}

	// The executor may have broadcast before this failed, so the outcome is unknown, not failed. Retrying the
	// same signed action is safe (its nonce is spent once), but a freshly signed one could withdraw twice.
	slog.Error("withdrawal_submit_failed", "subaccount_id", req.Action.SubaccountID, "nonce", req.Action.Nonce, "error", err)
	writeJSON(w, http.StatusBadGateway, map[string]string{
		"error": "could not confirm whether the withdrawal was submitted; check the account balance before trying again",
	})
}

func withdrawalOrdersigAction(action withdrawalAction) ordersig.Action {
	return ordersig.Action{
		SubaccountID: action.SubaccountID,
		Nonce:        action.Nonce,
		Module:       action.Module,
		Data:         action.Data,
		Expiry:       action.Expiry,
		Owner:        action.Owner,
		Signer:       action.Signer,
	}
}

// validate refuses a withdrawal that is malformed or that the executor would refuse anyway, before any chain
// read. The chain enforces the signature, custody and nonce; these keep junk off the RPC and out of the queue.
func (svc *withdrawalService) validate(req withdrawalRequest) error {
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
		return fmt.Errorf("action.module must be the withdrawal module %s", svc.moduleAddress)
	}
	// Tokens always go to the owner. Session keys are not checked off-chain, so only the owner may sign.
	if !strings.EqualFold(strings.TrimSpace(action.Owner), strings.TrimSpace(action.Signer)) {
		return errors.New("action.signer must be action.owner; session-key withdrawals are not supported")
	}

	// ActionVerifier reverts only once block.timestamp is past the expiry, so an expiry of exactly now is valid.
	now := svc.now().Unix()
	if expiry.Cmp(big.NewInt(now)) < 0 {
		return errors.New("action has expired")
	}
	if expiry.Cmp(big.NewInt(now+int64(withdrawalMaxLifetime/time.Second))) > 0 {
		return errors.New("action.expiry may be at most one hour ahead")
	}

	asset, amount, err := decodeWithdrawalData(action.Data)
	if err != nil {
		return err
	}
	if !svc.allowsAsset(asset) {
		return fmt.Errorf("asset %s is not withdrawable", asset)
	}
	if amount.Sign() == 0 {
		return errors.New("withdrawal amount must be greater than 0")
	}

	if !isSignatureHex(req.Signature) {
		return errors.New("signature must be hex of at least 65 bytes")
	}
	return nil
}

func (svc *withdrawalService) allowsAsset(asset string) bool {
	for _, allowed := range svc.assets {
		if strings.EqualFold(allowed, asset) {
			return true
		}
	}
	return false
}

func parseUint256Decimal(field string, raw string) (*big.Int, error) {
	value := strings.TrimSpace(raw)
	if value == "" || strings.TrimLeft(value, "0123456789") != "" {
		return nil, fmt.Errorf("%s must be an unsigned decimal integer", field)
	}
	parsed, ok := new(big.Int).SetString(value, 10)
	if !ok || parsed.BitLen() > 256 {
		return nil, fmt.Errorf("%s must be an unsigned decimal integer", field)
	}
	return parsed, nil
}

// decodeWithdrawalData reads abi.encode(WithdrawalData{address asset; uint256 assetAmount}): exactly two static
// words. The asset comes back lowercased.
func decodeWithdrawalData(data string) (string, *big.Int, error) {
	malformed := errors.New("action.data must be abi.encode(address asset, uint256 amount): exactly 64 bytes")
	cleaned := strings.TrimSpace(data)
	if len(cleaned) != 2+128 || !strings.HasPrefix(cleaned, "0x") {
		return "", nil, malformed
	}
	raw, err := hex.DecodeString(cleaned[2:])
	if err != nil {
		return "", nil, malformed
	}
	// Solidity's abi.decode reverts on an address word with dirty high bits.
	if !bytes.Equal(raw[:12], make([]byte, 12)) {
		return "", nil, errors.New("action.data asset word is not a left-padded address")
	}
	return "0x" + hex.EncodeToString(raw[12:32]), new(big.Int).SetBytes(raw[32:64]), nil
}

// isSignatureHex accepts a 65-byte EOA signature or a longer ERC-1271 one.
func isSignatureHex(value string) bool {
	cleaned := strings.TrimSpace(value)
	if !strings.HasPrefix(cleaned, "0x") || len(cleaned) < 2+130 || len(cleaned)%2 != 0 {
		return false
	}
	_, err := hex.DecodeString(cleaned[2:])
	return err == nil
}

// withdrawalLimiter admits at most one withdrawal in flight per owner, and at most perMinute a minute. It is per
// API task: with several tasks an owner gets that allowance on each, which still bounds it.
type withdrawalLimiter struct {
	mu        sync.Mutex
	perMinute int
	inFlight  map[string]bool
	recent    map[string][]time.Time
}

func newWithdrawalLimiter(perMinute int) *withdrawalLimiter {
	return &withdrawalLimiter{
		perMinute: perMinute,
		inFlight:  map[string]bool{},
		recent:    map[string][]time.Time{},
	}
}

func (l *withdrawalLimiter) acquire(owner string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.inFlight[owner] {
		return false
	}
	kept := l.recent[owner][:0]
	for _, at := range l.recent[owner] {
		if now.Sub(at) < time.Minute {
			kept = append(kept, at)
		}
	}
	if len(kept) >= l.perMinute {
		l.recent[owner] = kept
		return false
	}
	l.recent[owner] = append(kept, now)
	l.inFlight[owner] = true
	return true
}

func (l *withdrawalLimiter) release(owner string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.inFlight, owner)
}

// executorWithdrawError is execution-service refusing a withdrawal outright: 422 when it breaks policy or the
// simulation reverted (Revert names the revert), 503 when withdrawals are not enabled there.
type executorWithdrawError struct {
	Status  int
	Message string
	Revert  string
}

func (e *executorWithdrawError) Error() string {
	if e.Revert != "" {
		return fmt.Sprintf("execution-service %d: %s (%s)", e.Status, e.Message, e.Revert)
	}
	return fmt.Sprintf("execution-service %d: %s", e.Status, e.Message)
}

type executorWithdrawClient struct {
	url        string
	httpClient *http.Client
}

func (c *executorWithdrawClient) SubmitWithdrawal(ctx context.Context, request withdrawalRequest) (withdrawalReceipt, error) {
	body, err := json.Marshal(request)
	if err != nil {
		return withdrawalReceipt{}, fmt.Errorf("encode withdrawal: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return withdrawalReceipt{}, fmt.Errorf("build withdrawal request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return withdrawalReceipt{}, fmt.Errorf("post withdrawal to execution-service: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return withdrawalReceipt{}, fmt.Errorf("read execution-service response: %w", err)
	}

	switch resp.StatusCode {
	case http.StatusOK:
		var receipt withdrawalReceipt
		if err := json.Unmarshal(raw, &receipt); err != nil {
			return withdrawalReceipt{}, fmt.Errorf("decode execution-service receipt: %w", err)
		}
		if receipt.TxHash == "" {
			return withdrawalReceipt{}, errors.New("execution-service returned no tx_hash")
		}
		return receipt, nil
	case http.StatusUnprocessableEntity, http.StatusServiceUnavailable:
		var payload struct {
			Error  string `json:"error"`
			Revert string `json:"revert"`
		}
		_ = json.Unmarshal(raw, &payload)
		return withdrawalReceipt{}, &executorWithdrawError{Status: resp.StatusCode, Message: payload.Error, Revert: payload.Revert}
	default:
		text := string(raw)
		if len(text) > 512 {
			text = text[:512]
		}
		return withdrawalReceipt{}, fmt.Errorf("execution-service returned %d: %s", resp.StatusCode, text)
	}
}
