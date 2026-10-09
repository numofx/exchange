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
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/ordersig"
)

// Signed deposits: POST /v1/deposits opens a perp margin account (subaccount_id 0) or tops one up, through the
// already-deployed DepositModule, with the venue paying gas. The trader still approves USDC to the DepositModule
// once, on chain; everything after that is this endpoint.
//
// What the chain itself enforces, from contracts/execution/test/modules/DepositModuleFork.t.sol against the live
// deployment: the signer, the expiry, ownership of an existing account, the nonce, and -- in the perp CashAsset --
// that the account is under the perp SRM (MW_UnknownManager). What it does NOT: another wrapped asset (the cNGN
// escrow is accepted) or the max sentinel (which deposits the owner's whole balance). This endpoint pins all of it,
// and reads everything it can before the executor simulates, so the common mistakes come back as 400s with a reason.

const (
	depositMaxBodyBytes = 64 << 10
	// depositMaxLifetime caps how far ahead a signed deposit may expire, as for withdrawals.
	depositMaxLifetime = time.Hour
	// depositTokenDecimals is Base USDC's. A deposit names its amount in 6-decimal base units; the ledger credits it
	// at 18. depositUnitsToLedger is the only place the two meet.
	depositTokenDecimals = 6
	// Selectors, derived with `cast sig` and pinned in TestDepositSelectorsMatchTheirSignatures.
	sigUsedNonces  = "0x6a8a6894" // usedNonces(address,uint256)
	sigManagerOf   = "0x52981457" // manager(uint256)
	sigWrapped     = "0xd9a1836a" // wrappedAsset()
	sigBalanceOf   = "0x70a08231" // balanceOf(address)
	sigAllowanceOf = "0xdd62ed3e" // allowance(address,address)
)

var maxUint256 = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))

// depositRequest is one user-signed DepositModule action, in the shape execution-service's POST /deposit accepts.
// The action is the same EIP-712 Action every module signs; `data` is
// abi.encode(uint256 amount, address asset, address managerForNewAccount), amount in 6-decimal USDC base units.
type depositRequest struct {
	Action    withdrawalAction `json:"action"`
	Signature string           `json:"signature"`
}

// depositReceipt is the answer: execution-service's receipt, the account credited, and the amount in each unit.
type depositReceipt struct {
	Accepted      bool   `json:"accepted"`
	TxHash        string `json:"tx_hash"`
	ReceiptStatus string `json:"receipt_status,omitempty"`
	BlockNumber   string `json:"block_number,omitempty"`
	// SubaccountID is the account credited: for subaccount_id 0, the new one. Absent until the receipt is known.
	SubaccountID string `json:"subaccount_id,omitempty"`
	// AmountUSDC is the deposit as a decimal string with 6 places; AmountUnits the same in 6-decimal base units, as
	// signed; CreditedCashE18 what the account's cash rises by, at the ledger's 18 decimals.
	AmountUSDC      string `json:"amount_usdc"`
	AmountUnits     string `json:"amount_units"`
	CreditedCashE18 string `json:"credited_cash_e18"`
}

type depositData struct {
	amount  *big.Int
	asset   string
	manager string
}

// depositChain is every read the endpoint makes before submitting.
type depositChain interface {
	NonceUsed(ctx context.Context, module, owner string, nonce *big.Int) (bool, error)
	DepositedOwner(ctx context.Context, subaccountID string) (string, error)
	AccountManager(ctx context.Context, subaccountID string) (string, error)
	WrappedToken(ctx context.Context, asset string) (string, error)
	TokenBalance(ctx context.Context, token, owner string) (*big.Int, error)
	TokenAllowance(ctx context.Context, token, owner, spender string) (*big.Int, error)
}

type depositSubmitter interface {
	SubmitDeposit(ctx context.Context, request depositRequest) (depositReceipt, error)
}

// depositService is everything POST /v1/deposits needs. Nil unless DEPOSITS_ENABLED and fully configured; the
// endpoint then answers 503.
type depositService struct {
	moduleAddress string
	assets        []string
	manager       string
	minAmount     *big.Int
	chain         depositChain
	submitter     depositSubmitter
	limiter       *withdrawalLimiter
	now           func() time.Time
}

func newDepositService(cfg config.Config, signatures signatureChecker) *depositService {
	if !cfg.DepositsEnabled {
		return nil
	}
	module := strings.ToLower(strings.TrimSpace(cfg.DepositModuleAddress))
	manager := strings.ToLower(strings.TrimSpace(cfg.DepositManagerAddress))
	if !isHexAddress(module) || !isHexAddress(manager) || len(cfg.DepositAssetAddresses) == 0 ||
		strings.TrimSpace(cfg.ExecutorDepositURL) == "" || cfg.DepositMinAmount == nil {
		slog.Warn("deposits_disabled", "reason", "DEPOSITS_ENABLED but the module, manager, assets or EXECUTOR_DEPOSIT_URL is unset")
		return nil
	}
	// Every check must be able to run. A deposit spends the venue's gas and moves the trader's funds, so a missing
	// verifier or chain reader disables it rather than letting a request through half-checked.
	if signatures == nil || !isHexAddress(cfg.MatchingAddress) || strings.TrimSpace(cfg.ChainRPCURL) == "" {
		slog.Warn("deposits_disabled", "reason", "signature verifier, MATCHING_ADDRESS or CHAIN_RPC_URL is not configured")
		return nil
	}
	return &depositService{
		moduleAddress: module,
		assets:        cfg.DepositAssetAddresses,
		manager:       manager,
		minAmount:     cfg.DepositMinAmount,
		chain: &chainDepositReader{chainCustodyChecker: &chainCustodyChecker{
			rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
			matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
			httpClient:      &http.Client{Timeout: 5 * time.Second},
		}},
		submitter: &executorDepositClient{
			url:        strings.TrimSpace(cfg.ExecutorDepositURL),
			httpClient: &http.Client{Timeout: cfg.ExecutorDepositTimeout},
		},
		limiter: newWithdrawalLimiter(cfg.DepositsPerOwnerPerMinute),
		now:     time.Now,
	}
}

// depositUnitsToLedger is the one place a deposit amount changes units: 6-decimal USDC to the 18-decimal ledger.
func depositUnitsToLedger(units *big.Int) *big.Int {
	return new(big.Int).Mul(units, new(big.Int).Exp(big.NewInt(10), big.NewInt(18-depositTokenDecimals), nil))
}

// formatDepositUnits prints base units as USDC with all 6 places ("1000.000000"), as execution-service does.
func formatDepositUnits(units *big.Int) string {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(depositTokenDecimals), nil)
	whole, frac := new(big.Int).QuoRem(units, scale, new(big.Int))
	return fmt.Sprintf("%s.%0*s", whole, depositTokenDecimals, frac.String())
}

// handleCreateDeposit serves POST /v1/deposits. Every check fails closed, in order:
//
//  1. the request itself -- module, owner = signer, expiry, data, asset, amount, manager (400)
//  2. at most one deposit in flight per owner, and a few a minute (429)
//  3. the signature authorizes the action (401)
//  4. chain pre-checks, each a 400 naming the fix: the nonce is unused; for a top-up, the owner owns the account and
//     it is under the perp SRM; the owner holds the USDC and has approved the DepositModule for it
//  5. execution-service's verdict: 200 with the receipt and the account credited; known reverts as 400; any other
//     revert as 422 with its name
func (s *Server) handleCreateDeposit(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")

	svc := s.deposits
	if svc == nil || s.signatures == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "deposits are not enabled"})
		return
	}

	var req depositRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, depositMaxBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	data, err := svc.validate(req)
	if err != nil {
		slog.Info("deposit_rejected", "stage", "request", "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	owner := strings.ToLower(strings.TrimSpace(req.Action.Owner))
	if !svc.limiter.acquire(owner, svc.now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{
			"error": "a deposit for this owner is already in progress, or too many were requested; retry shortly",
		})
		return
	}
	defer svc.limiter.release(owner)

	if _, err := s.signatures.Verify(r.Context(), withdrawalOrdersigAction(req.Action), req.Signature, req.Action.Signer); err != nil {
		if errors.Is(err, ordersig.ErrInvalidSignature) {
			slog.Info("deposit_rejected", "stage", "signature", "owner", owner)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
			return
		}
		slog.Warn("deposit_signature_unverifiable", "owner", owner, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the signature could not be verified; retry shortly"})
		return
	}

	if message, err := svc.preflight(r.Context(), req, data); err != nil {
		slog.Warn("deposit_chain_unreadable", "owner", owner, "subaccount_id", req.Action.SubaccountID, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the chain could not be read to check this deposit; retry shortly"})
		return
	} else if message != "" {
		slog.Info("deposit_rejected", "stage", "preflight", "owner", owner, "subaccount_id", req.Action.SubaccountID, "reason", message)
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": message})
		return
	}

	receipt, err := svc.submitter.SubmitDeposit(r.Context(), req)
	if err != nil {
		writeDepositSubmitError(w, req, svc.moduleAddress, err)
		return
	}
	slog.Info("deposit_submitted", "owner", owner, "subaccount_id", receipt.SubaccountID, "amount_usdc", receipt.AmountUSDC,
		"tx_hash", receipt.TxHash, "receipt_status", receipt.ReceiptStatus, "accepted", receipt.Accepted)
	writeJSON(w, http.StatusOK, receipt)
}

// validate refuses what is malformed or off-policy before any chain read.
func (svc *depositService) validate(req depositRequest) (depositData, error) {
	action := req.Action

	subaccountID, err := parseUint256Decimal("action.subaccount_id", action.SubaccountID)
	if err != nil {
		return depositData{}, err
	}
	if _, err := parseUint256Decimal("action.nonce", action.Nonce); err != nil {
		return depositData{}, err
	}
	expiry, err := parseUint256Decimal("action.expiry", action.Expiry)
	if err != nil {
		return depositData{}, err
	}
	for _, field := range []struct{ name, value string }{
		{"action.module", action.Module},
		{"action.owner", action.Owner},
		{"action.signer", action.Signer},
	} {
		if !isHexAddress(field.value) {
			return depositData{}, fmt.Errorf("%s must be an address", field.name)
		}
	}
	if strings.ToLower(strings.TrimSpace(action.Module)) != svc.moduleAddress {
		return depositData{}, fmt.Errorf("action.module must be the deposit module %s", svc.moduleAddress)
	}
	// On chain a session key may sign a deposit that pulls USDC from the owner's wallet. Not supported here.
	if !strings.EqualFold(strings.TrimSpace(action.Owner), strings.TrimSpace(action.Signer)) {
		return depositData{}, errors.New("action.signer must be action.owner; session-key deposits are not supported")
	}
	now := svc.now().Unix()
	if expiry.Cmp(big.NewInt(now)) < 0 {
		return depositData{}, errors.New("action has expired; sign a fresh one")
	}
	if expiry.Cmp(big.NewInt(now+int64(depositMaxLifetime/time.Second))) > 0 {
		return depositData{}, errors.New("action.expiry may be at most one hour ahead")
	}

	data, err := decodeDepositData(action.Data)
	if err != nil {
		return depositData{}, err
	}
	if !containsFold(svc.assets, data.asset) {
		return depositData{}, fmt.Errorf("asset %s is not depositable; only the perp cash asset is", data.asset)
	}
	if data.amount.Cmp(maxUint256) == 0 {
		return depositData{}, errors.New("amount must be explicit; the max sentinel (deposit the whole balance) is not accepted")
	}
	if data.amount.Cmp(svc.minAmount) < 0 {
		return depositData{}, fmt.Errorf("amount %s USDC is below the minimum %s USDC (amounts are 6-decimal USDC base units)",
			formatDepositUnits(data.amount), formatDepositUnits(svc.minAmount))
	}
	if subaccountID.Sign() == 0 {
		if data.manager != svc.manager {
			return depositData{}, fmt.Errorf("a new account must be opened under the perp risk manager %s", svc.manager)
		}
	} else if data.manager != svc.manager && data.manager != zeroAddress {
		return depositData{}, fmt.Errorf("managerForNewAccount must be %s or zero for an existing account", svc.manager)
	}
	if !isSignatureHex(req.Signature) {
		return depositData{}, errors.New("signature must be hex of at least 65 bytes")
	}
	return data, nil
}

// preflight reads what the executor's simulation would otherwise discover, so each comes back as a 400 that says what
// to do. Returns the refusal, or an error when a read failed (the handler fails closed).
func (svc *depositService) preflight(ctx context.Context, req depositRequest, data depositData) (string, error) {
	owner := strings.ToLower(strings.TrimSpace(req.Action.Owner))
	nonce, _ := new(big.Int).SetString(strings.TrimSpace(req.Action.Nonce), 10)

	used, err := svc.chain.NonceUsed(ctx, svc.moduleAddress, owner, nonce)
	if err != nil {
		return "", err
	}
	if used {
		return fmt.Sprintf("nonce %s is already used for this owner; sign a fresh action with a new nonce", req.Action.Nonce), nil
	}

	if strings.TrimSpace(req.Action.SubaccountID) != "0" {
		recorded, err := svc.chain.DepositedOwner(ctx, req.Action.SubaccountID)
		if err != nil {
			if errors.Is(err, errNotDepositedInMatching) {
				return err.Error(), nil
			}
			return "", err
		}
		if recorded != owner {
			return fmt.Sprintf("subaccount_id %s is not owned by action.owner", req.Action.SubaccountID), nil
		}
		manager, err := svc.chain.AccountManager(ctx, req.Action.SubaccountID)
		if err != nil {
			return "", err
		}
		if manager != svc.manager {
			return fmt.Sprintf("subaccount_id %s is under manager %s, not the perp risk manager %s; perp cash can only be "+
				"deposited into a perp account", req.Action.SubaccountID, manager, svc.manager), nil
		}
	}

	token, err := svc.chain.WrappedToken(ctx, data.asset)
	if err != nil {
		return "", err
	}
	balance, err := svc.chain.TokenBalance(ctx, token, owner)
	if err != nil {
		return "", err
	}
	if balance.Cmp(data.amount) < 0 {
		return fmt.Sprintf("the owner holds %s USDC, less than the %s USDC deposit", formatDepositUnits(balance), formatDepositUnits(data.amount)), nil
	}
	allowance, err := svc.chain.TokenAllowance(ctx, token, owner, svc.moduleAddress)
	if err != nil {
		return "", err
	}
	if allowance.Cmp(data.amount) < 0 {
		return fmt.Sprintf("the owner's USDC allowance to the deposit module is %s USDC, less than the %s USDC deposit; "+
			"approve %s for at least the amount first", formatDepositUnits(allowance), formatDepositUnits(data.amount), svc.moduleAddress), nil
	}
	return "", nil
}

// knownDepositReverts are the reverts a deposit can still hit after preflight (a race, or a check preflight cannot
// make), each mapped to a 400 that says what to do. Anything else is reported as a 422 with its name.
var knownDepositReverts = map[string]string{
	"MW_UnknownManager":                    "the account is not under the perp risk manager; perp cash can only be deposited into a perp account",
	"BM_NonceAlreadyUsed":                  "the nonce is already used for this owner; sign a fresh action with a new nonce",
	"OV_ActionExpired":                     "action has expired; sign a fresh one",
	"OV_SignerNotOwnerOrSessionKeyExpired": "action.signer is not action.owner",
	"OV_InvalidActionOwner":                "subaccount_id is not owned by action.owner",
	"OV_InvalidSignature":                  "the signature does not match the action",
}

func depositRevertMessage(revert, module string) (string, bool) {
	if message, ok := knownDepositReverts[revert]; ok {
		return message, true
	}
	// USDC reverts with require strings, not custom errors.
	switch lower := strings.ToLower(revert); {
	case strings.Contains(lower, "exceeds allowance"):
		return fmt.Sprintf("the owner's USDC allowance to the deposit module is below the amount; approve %s first", module), true
	case strings.Contains(lower, "exceeds balance"):
		return "the owner's USDC balance is below the amount", true
	}
	return "", false
}

func writeDepositSubmitError(w http.ResponseWriter, req depositRequest, module string, err error) {
	var rejected *executorWithdrawError
	if errors.As(err, &rejected) {
		switch rejected.Status {
		case http.StatusUnprocessableEntity:
			if message, ok := depositRevertMessage(rejected.Revert, module); ok {
				slog.Info("deposit_rejected", "stage", "executor", "revert", rejected.Revert)
				writeJSON(w, http.StatusBadRequest, map[string]string{"error": message, "revert": rejected.Revert})
				return
			}
			body := map[string]string{"error": rejected.Message}
			if rejected.Revert != "" {
				body["revert"] = rejected.Revert
			}
			slog.Info("deposit_rejected", "stage", "executor", "revert", rejected.Revert, "error", rejected.Message)
			writeJSON(w, http.StatusUnprocessableEntity, body)
			return
		case http.StatusServiceUnavailable:
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": nonEmpty(rejected.Message, "deposits are not enabled on the executor")})
			return
		}
	}
	// The executor may have broadcast before this failed. Retrying the SAME signed action is safe (the executor is
	// idempotent on it and the nonce is spent once); a freshly signed one could deposit twice.
	slog.Error("deposit_submit_failed", "nonce", req.Action.Nonce, "error", err)
	writeJSON(w, http.StatusBadGateway, map[string]string{
		"error": "could not confirm whether the deposit was submitted; retry the same signed request, or check the account before signing a new one",
	})
}

func nonEmpty(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func containsFold(list []string, value string) bool {
	for _, item := range list {
		if strings.EqualFold(item, value) {
			return true
		}
	}
	return false
}

// decodeDepositData reads abi.encode(DepositData{uint256 amount; address asset; address managerForNewAccount}):
// exactly three static words. Addresses come back lowercased.
func decodeDepositData(data string) (depositData, error) {
	malformed := errors.New("action.data must be abi.encode(uint256 amount, address asset, address managerForNewAccount): exactly 96 bytes")
	cleaned := strings.TrimSpace(data)
	if len(cleaned) != 2+192 || !strings.HasPrefix(cleaned, "0x") {
		return depositData{}, malformed
	}
	raw, err := hex.DecodeString(cleaned[2:])
	if err != nil {
		return depositData{}, malformed
	}
	if !bytes.Equal(raw[32:44], make([]byte, 12)) || !bytes.Equal(raw[64:76], make([]byte, 12)) {
		return depositData{}, errors.New("action.data address words are not left-padded addresses")
	}
	return depositData{
		amount:  new(big.Int).SetBytes(raw[0:32]),
		asset:   "0x" + hex.EncodeToString(raw[44:64]),
		manager: "0x" + hex.EncodeToString(raw[76:96]),
	}, nil
}

// chainDepositReader is depositChain over eth_call.
type chainDepositReader struct {
	*chainCustodyChecker
}

func (c *chainDepositReader) NonceUsed(ctx context.Context, module, owner string, nonce *big.Int) (bool, error) {
	raw, err := c.ethCall(ctx, module, sigUsedNonces+addressArg(owner)+fmt.Sprintf("%064x", nonce))
	if err != nil {
		return false, err
	}
	word, err := unsignedWord(raw)
	if err != nil {
		return false, err
	}
	return word.Sign() != 0, nil
}

func (c *chainDepositReader) AccountManager(ctx context.Context, subaccountID string) (string, error) {
	subAccounts, err := c.subAccountsAddress(ctx)
	if err != nil {
		return "", err
	}
	return c.callAddress(ctx, subAccounts, sigManagerOf, subaccountID)
}

func (c *chainDepositReader) WrappedToken(ctx context.Context, asset string) (string, error) {
	raw, err := c.ethCall(ctx, asset, sigWrapped)
	if err != nil {
		return "", err
	}
	return decodeAddress(raw)
}

func (c *chainDepositReader) TokenBalance(ctx context.Context, token, owner string) (*big.Int, error) {
	raw, err := c.ethCall(ctx, token, sigBalanceOf+addressArg(owner))
	if err != nil {
		return nil, err
	}
	return unsignedWord(raw)
}

func (c *chainDepositReader) TokenAllowance(ctx context.Context, token, owner, spender string) (*big.Int, error) {
	raw, err := c.ethCall(ctx, token, sigAllowanceOf+addressArg(owner)+addressArg(spender))
	if err != nil {
		return nil, err
	}
	return unsignedWord(raw)
}

func unsignedWord(raw string) (*big.Int, error) {
	cleaned := strings.TrimPrefix(strings.TrimSpace(raw), "0x")
	if len(cleaned) < 64 {
		return nil, fmt.Errorf("short eth_call result %q", raw)
	}
	value, ok := new(big.Int).SetString(cleaned[:64], 16)
	if !ok {
		return nil, fmt.Errorf("malformed eth_call result %q", raw)
	}
	return value, nil
}

type executorDepositClient struct {
	url        string
	httpClient *http.Client
}

func (c *executorDepositClient) SubmitDeposit(ctx context.Context, request depositRequest) (depositReceipt, error) {
	body, err := json.Marshal(request)
	if err != nil {
		return depositReceipt{}, fmt.Errorf("encode deposit: %w", err)
	}
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return depositReceipt{}, fmt.Errorf("build deposit request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")
	resp, err := c.httpClient.Do(httpReq)
	if err != nil {
		return depositReceipt{}, fmt.Errorf("post deposit to execution-service: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return depositReceipt{}, fmt.Errorf("read execution-service response: %w", err)
	}

	switch resp.StatusCode {
	case http.StatusOK:
		var receipt depositReceipt
		if err := json.Unmarshal(raw, &receipt); err != nil {
			return depositReceipt{}, fmt.Errorf("decode execution-service receipt: %w", err)
		}
		if receipt.TxHash == "" {
			return depositReceipt{}, errors.New("execution-service returned no tx_hash")
		}
		return receipt, nil
	case http.StatusUnprocessableEntity, http.StatusServiceUnavailable:
		var payload struct {
			Error  string `json:"error"`
			Revert string `json:"revert"`
		}
		_ = json.Unmarshal(raw, &payload)
		return depositReceipt{}, &executorWithdrawError{Status: resp.StatusCode, Message: payload.Error, Revert: payload.Revert}
	default:
		text := string(raw)
		if len(text) > 512 {
			text = text[:512]
		}
		return depositReceipt{}, fmt.Errorf("execution-service returned %d: %s", resp.StatusCode, text)
	}
}
