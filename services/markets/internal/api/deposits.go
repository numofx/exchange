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
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

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
	// A WrappedERC20Asset escrow's cap under a manager, what is posted under it, and whether it accepts that manager:
	// the same reads GET /v1/perp/state makes for collateral_assets.
	sigEscrowCap   = "0x745ab570" // totalPositionCap(address)
	sigEscrowTotal = "0xa9578774" // totalPosition(address)
	sigEscrowOpen  = "0x97d51c04" // whitelistedManager(address)
	// topicDepositedSubAccount is DepositedSubAccount(uint256,address), which Matching emits for a new account.
	topicDepositedSubAccount = "0x043a568d47b1a65cdc989ff14c921411b62abf40132dc4b5e78675ba8d0bc9df"
)

var maxUint256 = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 256), big.NewInt(1))

// depositRequest is one user-signed DepositModule action, in the shape execution-service's POST /deposit accepts.
// The action is the same EIP-712 Action every module signs; `data` is
// abi.encode(uint256 amount, address asset, address managerForNewAccount), amount in 6-decimal USDC base units.
type depositRequest struct {
	Action    withdrawalAction `json:"action"`
	Signature string           `json:"signature"`
	// Permit is an optional EIP-2612 permit on USDC from action.owner to the DepositModule, for a deposit with no
	// prior approve. The spender is not sent: the executor always submits it with the DepositModule as spender.
	Permit *depositPermit `json:"permit,omitempty"`
}

type depositPermit struct {
	Value     string `json:"value"`
	Deadline  string `json:"deadline"`
	Signature string `json:"signature"`
}

// depositReceipt is the answer: execution-service's receipt, the account credited, and the amount in each unit.
type depositReceipt struct {
	// ActionHash is Matching.getActionHash of the signed action: the key for GET /v1/deposits/{action_hash}.
	ActionHash string `json:"action_hash,omitempty"`
	// Status is the record's: pending, submitted, confirmed, reverted, rejected or unknown (migration 000018).
	Status        string `json:"status,omitempty"`
	Accepted      bool   `json:"accepted"`
	TxHash        string `json:"tx_hash"`
	ReceiptStatus string `json:"receipt_status,omitempty"`
	BlockNumber   string `json:"block_number,omitempty"`
	// SubaccountID is the account credited: for subaccount_id 0, the new one. Absent until the receipt is known.
	SubaccountID string `json:"subaccount_id,omitempty"`
	// Asset is the wrapped asset credited and AssetSymbol its token's. Amount is the deposit as a decimal string with
	// 6 places, AmountUnits the same in 6-decimal base units, as signed, and CreditedE18 what the account's balance of
	// the asset rises by, at the ledger's 18 decimals.
	Asset       string `json:"asset"`
	AssetSymbol string `json:"asset_symbol"`
	Amount      string `json:"amount"`
	AmountUnits string `json:"amount_units"`
	CreditedE18 string `json:"credited_e18"`
	// AmountUSDC and CreditedCashE18 are the same numbers under their original names, on USDC deposits only: a cNGN
	// deposit has no USDC amount, and labelling cNGN as USDC would misstate it by three orders of magnitude.
	AmountUSDC      string `json:"amount_usdc,omitempty"`
	CreditedCashE18 string `json:"credited_cash_e18,omitempty"`
	// PermitTxHash is the permit's transaction, when the deposit carried one and it was needed.
	PermitTxHash string `json:"permit_tx_hash,omitempty"`
}

type depositData struct {
	amount  *big.Int
	asset   string
	manager string
	// symbol is the asset's token's, from DEPOSIT_ASSETS.
	symbol string
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

// depositReceipts reads a broadcast deposit's outcome from the chain, for a record whose receipt was not known when
// it was answered. mined false means not yet; account is the new subaccount from Matching's DepositedSubAccount for
// owner, when there is one.
type depositReceipts interface {
	DepositOutcome(ctx context.Context, txHash, owner string) (mined, success bool, block, account string, err error)
}

// depositService is everything POST /v1/deposits needs. Nil unless DEPOSITS_ENABLED and fully configured; the
// endpoint then answers 503.
type depositService struct {
	moduleAddress string
	// assets is each depositable wrapped asset, by lowercased address.
	assets  map[string]config.DepositAsset
	manager string
	chain   depositChain
	// tokens reads the issuer's pause and freezes for token_controls.go; nil skips that check.
	tokens    tokenStateReader
	submitter depositSubmitter
	store     depositStore
	receipts  depositReceipts
	limiter   *withdrawalLimiter
	// hourly counts deposits submitted to the executor per owner -- the ones the venue may pay gas for. A request
	// refused before that (a 400, a 401) does not count, so fixing a mistake costs nothing.
	hourly *ownerHourlyCap
	now    func() time.Time
}

func newDepositService(cfg config.Config, signatures signatureChecker, pool *pgxpool.Pool) *depositService {
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
	if signatures == nil || !isHexAddress(cfg.MatchingAddress) || strings.TrimSpace(cfg.ChainRPCURL) == "" || pool == nil {
		slog.Warn("deposits_disabled", "reason", "signature verifier, MATCHING_ADDRESS, CHAIN_RPC_URL or the database is not configured")
		return nil
	}
	reader := &chainDepositReader{chainCustodyChecker: &chainCustodyChecker{
		rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
		matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
		httpClient:      &http.Client{Timeout: 5 * time.Second},
	}}
	return &depositService{
		moduleAddress: module,
		assets:        depositAssetsByAddress(cfg.DepositAssets),
		manager:       manager,
		chain:         reader,
		tokens:        reader,
		receipts:      reader,
		store:         &pgDepositStore{pool: pool},
		submitter: &executorDepositClient{
			url:        strings.TrimSpace(cfg.ExecutorDepositURL),
			httpClient: &http.Client{Timeout: cfg.ExecutorDepositTimeout},
		},
		limiter: newWithdrawalLimiter(cfg.DepositsPerOwnerPerMinute),
		hourly:  newOwnerHourlyCap(cfg.DepositsPerOwnerPerHour),
		now:     time.Now,
	}
}

// ownerHourlyCap admits at most `limit` recorded events per owner in a rolling hour. Per API task, which is a
// singleton (desired_count_markets = 1).
type ownerHourlyCap struct {
	mu     sync.Mutex
	limit  int
	recent map[string][]time.Time
}

func newOwnerHourlyCap(limit int) *ownerHourlyCap {
	return &ownerHourlyCap{limit: limit, recent: map[string][]time.Time{}}
}

func (c *ownerHourlyCap) prune(owner string, now time.Time) []time.Time {
	kept := c.recent[owner][:0]
	for _, at := range c.recent[owner] {
		if now.Sub(at) < time.Hour {
			kept = append(kept, at)
		}
	}
	c.recent[owner] = kept
	return kept
}

// full reports whether the owner has used the hour's allowance, and when the oldest use expires.
func (c *ownerHourlyCap) full(owner string, now time.Time) (bool, time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	kept := c.prune(owner, now)
	if len(kept) < c.limit {
		return false, 0
	}
	return true, time.Hour - now.Sub(kept[0])
}

func (c *ownerHourlyCap) record(owner string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.recent[owner] = append(c.prune(owner, now), now)
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
//  2. at most one deposit in flight per owner, a few a minute, and DEPOSITS_PER_OWNER_PER_HOUR submitted an hour (429)
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
	actionHash, err := ordersig.ActionHash(withdrawalOrdersigAction(req.Action))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	// The same signed request again -- a retry after a timeout, a double click, a restart in between -- is answered
	// from what already happened, never resubmitted. A rejected one (nothing was sent) may be tried again.
	if existing, found, err := svc.store.Get(r.Context(), actionHash); err != nil {
		slog.Warn("deposit_store_unreadable", "action_hash", actionHash, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "deposits could not be read; retry shortly"})
		return
	} else if found && existing.Status != depositRejected {
		svc.writeRecord(r.Context(), w, existing)
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

	if full, retryIn := svc.hourly.full(owner, svc.now()); full {
		slog.Info("deposit_rejected", "stage", "hourly_cap", "owner", owner)
		w.Header().Set("Retry-After", fmt.Sprintf("%d", int(retryIn.Seconds())+1))
		writeJSON(w, http.StatusTooManyRequests, map[string]string{
			"error": fmt.Sprintf("this owner has made %d deposits in the last hour, the most allowed; retry in %d minutes",
				svc.hourly.limit, int(retryIn.Minutes())+1),
		})
		return
	}

	if svc.tokens != nil {
		stop, err := checkTokenControls(r.Context(), svc.tokens, data.asset, "deposit", []custodyParty{
			{address: owner, role: "depositing owner"},
			{address: svc.moduleAddress, role: "deposit module", venue: true},
			{address: data.asset, role: "custody contract", venue: true},
		})
		if err != nil {
			slog.Warn("deposit_token_controls_unreadable", "owner", owner, "asset", data.asset, "error", err)
		} else if stop != nil {
			logTokenStop("deposit", owner, data.asset, stop)
			writeJSON(w, stop.status, map[string]string{"error": stop.message})
			return
		}
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

	rec, claimed, err := svc.store.Claim(r.Context(), depositRecord{
		ActionHash: actionHash, Owner: owner, Nonce: strings.TrimSpace(req.Action.Nonce),
		SubaccountIDRequested: strings.TrimSpace(req.Action.SubaccountID), AmountUnits: data.amount.String(), Asset: data.asset,
	})
	if err != nil {
		slog.Warn("deposit_store_unwritable", "action_hash", actionHash, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the deposit could not be recorded; nothing was sent; retry shortly"})
		return
	}
	if !claimed {
		// Another request for this action got here first.
		svc.writeRecord(r.Context(), w, rec)
		return
	}

	// Counted when submitted, success or not: from here the venue may have paid gas.
	svc.hourly.record(owner, svc.now())
	receipt, err := svc.submitter.SubmitDeposit(r.Context(), req)
	if err != nil {
		rec.Status, rec.Error, rec.Revert = depositUnknown, err.Error(), ""
		var rejected *executorWithdrawError
		if errors.As(err, &rejected) && (rejected.Status == http.StatusUnprocessableEntity || rejected.Status == http.StatusServiceUnavailable) {
			// Refused before anything was broadcast: the same request may be retried.
			rec.Status, rec.Error, rec.Revert = depositRejected, rejected.Message, rejected.Revert
		}
		svc.save(r.Context(), rec)
		writeDepositSubmitError(w, req, svc.moduleAddress, data.symbol, err)
		return
	}
	rec.TxHash, rec.PermitTxHash, rec.BlockNumber, rec.SubaccountID = receipt.TxHash, receipt.PermitTxHash, receipt.BlockNumber, receipt.SubaccountID
	switch receipt.ReceiptStatus {
	case "success":
		rec.Status = depositConfirmed
	case "reverted":
		rec.Status = depositReverted
	default:
		rec.Status = depositSubmitted
	}
	svc.save(r.Context(), rec)
	receipt.ActionHash, receipt.Status = actionHash, rec.Status
	// The amounts are this service's, from the signed action and the asset's own symbol, not the executor's wording.
	amounts := depositAmounts(svc.assets[data.asset], data.amount)
	receipt.Asset, receipt.AssetSymbol, receipt.Amount, receipt.AmountUnits, receipt.CreditedE18 =
		amounts.Asset, amounts.AssetSymbol, amounts.Amount, amounts.AmountUnits, amounts.CreditedE18
	receipt.AmountUSDC, receipt.CreditedCashE18 = amounts.AmountUSDC, amounts.CreditedCashE18
	slog.Info("deposit_submitted", "owner", owner, "action_hash", actionHash, "status", rec.Status, "subaccount_id", receipt.SubaccountID,
		"asset", data.symbol, "amount", receipt.Amount, "tx_hash", receipt.TxHash)
	writeJSON(w, http.StatusOK, receipt)
}

func (svc *depositService) save(ctx context.Context, rec depositRecord) {
	if err := svc.store.Save(ctx, rec); err != nil {
		// The answer to this request is still right; only a later GET would be stale.
		slog.Error("deposit_store_save_failed", "action_hash", rec.ActionHash, "status", rec.Status, "error", err)
	}
}

// handleGetDeposit serves GET /v1/deposits/{action_hash}: the deposit's record, with a broadcast deposit whose receipt
// was not known re-read from the chain first.
func (s *Server) handleGetDeposit(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	svc := s.deposits
	if svc == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "deposits are not enabled"})
		return
	}
	hash := strings.ToLower(strings.TrimSpace(chi.URLParam(r, "action_hash")))
	if len(hash) != 66 || !strings.HasPrefix(hash, "0x") || !isHexString(hash[2:]) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "action_hash must be 0x followed by 64 hex digits"})
		return
	}
	rec, found, err := svc.store.Get(r.Context(), hash)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "deposits could not be read; retry shortly"})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no deposit with this action_hash"})
		return
	}
	svc.writeRecord(r.Context(), w, rec)
}

// writeRecord answers from a stored deposit: 202 while it is pending, 200 otherwise. A submitted (or unknown, with a
// hash) deposit is re-read from the chain first, so a receipt that timed out resolves on the next read.
func (svc *depositService) writeRecord(ctx context.Context, w http.ResponseWriter, rec depositRecord) {
	if (rec.Status == depositSubmitted || rec.Status == depositUnknown) && rec.TxHash != "" && svc.receipts != nil {
		mined, success, block, account, err := svc.receipts.DepositOutcome(ctx, rec.TxHash, rec.Owner)
		if err != nil {
			slog.Warn("deposit_receipt_unreadable", "action_hash", rec.ActionHash, "tx_hash", rec.TxHash, "error", err)
		} else if mined {
			rec.Status, rec.BlockNumber = depositReverted, block
			if success {
				rec.Status = depositConfirmed
				if rec.SubaccountIDRequested != "0" {
					rec.SubaccountID = rec.SubaccountIDRequested
				} else if account != "" {
					rec.SubaccountID = account
				}
			}
			svc.save(ctx, rec)
		}
	}
	units, _ := new(big.Int).SetString(rec.AmountUnits, 10)
	if units == nil {
		units = new(big.Int)
	}
	status := http.StatusOK
	if rec.Status == depositPending {
		status = http.StatusAccepted
	}
	amounts := depositAmounts(svc.assetOf(rec.Asset), units)
	body := map[string]any{
		"action_hash": rec.ActionHash, "status": rec.Status, "owner": rec.Owner, "nonce": rec.Nonce,
		"subaccount_id_requested": rec.SubaccountIDRequested, "subaccount_id": rec.SubaccountID,
		"tx_hash": rec.TxHash, "permit_tx_hash": rec.PermitTxHash, "block_number": rec.BlockNumber,
		"asset": amounts.Asset, "asset_symbol": amounts.AssetSymbol, "amount": amounts.Amount,
		"amount_units": amounts.AmountUnits, "credited_e18": amounts.CreditedE18,
		"error": rec.Error, "revert": rec.Revert, "created_at": rec.CreatedAt, "updated_at": rec.UpdatedAt,
	}
	if amounts.AmountUSDC != "" {
		body["amount_usdc"], body["credited_cash_e18"] = amounts.AmountUSDC, amounts.CreditedCashE18
	}
	writeJSON(w, status, body)
}

func isHexString(s string) bool {
	_, err := hex.DecodeString(s)
	return err == nil
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
	asset, ok := svc.assets[data.asset]
	if !ok {
		return depositData{}, fmt.Errorf("asset %s is not depositable; these are: %s", data.asset, svc.assetList())
	}
	data.symbol = asset.Symbol
	if data.amount.Cmp(maxUint256) == 0 {
		return depositData{}, errors.New("amount must be explicit; the max sentinel (deposit the whole balance) is not accepted")
	}
	if data.amount.Cmp(asset.MinAmount) < 0 {
		return depositData{}, fmt.Errorf("amount %s %s is below the minimum %s %s (amounts are 6-decimal %s base units)",
			formatDepositUnits(data.amount), asset.Symbol, formatDepositUnits(asset.MinAmount), asset.Symbol, asset.Symbol)
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
	if req.Permit != nil && asset.Symbol != "USDC" {
		return depositData{}, fmt.Errorf("%s has no permit (EIP-2612); approve the deposit module %s for %s on chain once, "+
			"then send the deposit without a permit", asset.Symbol, svc.moduleAddress, asset.Symbol)
	}
	if req.Permit != nil {
		value, err := parseUint256Decimal("permit.value", req.Permit.Value)
		if err != nil {
			return depositData{}, err
		}
		if value.Cmp(data.amount) < 0 {
			return depositData{}, fmt.Errorf("permit.value %s %s is below the deposit amount %s %s",
				formatDepositUnits(value), asset.Symbol, formatDepositUnits(data.amount), asset.Symbol)
		}
		deadline, err := parseUint256Decimal("permit.deadline", req.Permit.Deadline)
		if err != nil {
			return depositData{}, err
		}
		if deadline.Cmp(big.NewInt(now)) < 0 {
			return depositData{}, errors.New("permit has expired")
		}
		if sig := strings.TrimSpace(req.Permit.Signature); len(sig) != 2+130 || !isSignatureHex(sig) {
			return depositData{}, errors.New("permit.signature must be a 65-byte hex signature")
		}
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
		return fmt.Sprintf("the owner holds %s %s, less than the %s %s deposit", formatDepositUnits(balance), data.symbol, formatDepositUnits(data.amount), data.symbol), nil
	}
	allowance, err := svc.chain.TokenAllowance(ctx, token, owner, svc.moduleAddress)
	if err != nil {
		return "", err
	}
	// With a permit the executor sets the allowance itself; without one it must already be there.
	if allowance.Cmp(data.amount) < 0 && req.Permit == nil {
		return fmt.Sprintf("the owner's %s allowance to the deposit module is %s %s, less than the %s %s deposit; "+
			"approve %s for at least the amount first", data.symbol, formatDepositUnits(allowance), data.symbol, formatDepositUnits(data.amount), data.symbol, svc.moduleAddress), nil
	}
	return svc.escrowRoom(ctx, data)
}

// knownDepositReverts are the reverts a deposit can still hit after preflight (a race, or a check preflight cannot
// make), each mapped to a 400 that says what to do. Anything else is reported as a 422 with its name.
var knownDepositReverts = map[string]string{
	"MW_UnknownManager":                    "the account is not under the perp risk manager; deposits go only into accounts under it",
	"BM_AssetCapExceeded":                  "the deposit would take the asset past its collateral cap under the perp risk manager",
	"BM_NonceAlreadyUsed":                  "the nonce is already used for this owner; sign a fresh action with a new nonce",
	"OV_ActionExpired":                     "action has expired; sign a fresh one",
	"OV_SignerNotOwnerOrSessionKeyExpired": "action.signer is not action.owner",
	"OV_InvalidActionOwner":                "subaccount_id is not owned by action.owner",
	"OV_InvalidSignature":                  "the signature does not match the action",
}

func depositRevertMessage(revert, module, symbol string) (string, bool) {
	if message, ok := knownDepositReverts[revert]; ok {
		return message, true
	}
	// USDC and cNGN revert with require strings, not custom errors.
	switch lower := strings.ToLower(revert); {
	case strings.HasPrefix(lower, "permit:"):
		return "USDC refused the permit (expired, already used, or not signed by action.owner for the deposit module " +
			module + "), and the allowance does not cover the deposit; sign a fresh permit or approve the module", true
	case strings.Contains(lower, "exceeds allowance") || strings.Contains(lower, "insufficient allowance"):
		return fmt.Sprintf("the owner's %s allowance to the deposit module is below the amount; approve %s first", symbol, module), true
	case strings.Contains(lower, "exceeds balance") || strings.Contains(lower, "insufficient balance"):
		return fmt.Sprintf("the owner's %s balance is below the amount", symbol), true
	}
	return "", false
}

func writeDepositSubmitError(w http.ResponseWriter, req depositRequest, module, symbol string, err error) {
	var rejected *executorWithdrawError
	if errors.As(err, &rejected) {
		switch rejected.Status {
		case http.StatusUnprocessableEntity:
			if message, ok := depositRevertMessage(rejected.Revert, module, symbol); ok {
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

// DepositOutcome reads eth_getTransactionReceipt. A null result is "not mined yet".
func (c *chainDepositReader) DepositOutcome(ctx context.Context, txHash, owner string) (bool, bool, string, string, error) {
	body, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "eth_getTransactionReceipt", "params": []any{txHash}})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.rpcURL, bytes.NewReader(body))
	if err != nil {
		return false, false, "", "", err
	}
	req.Header.Set("content-type", "application/json")
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return false, false, "", "", err
	}
	defer resp.Body.Close()
	var payload struct {
		Result *struct {
			Status      string `json:"status"`
			BlockNumber string `json:"blockNumber"`
			Logs        []struct {
				Address string   `json:"address"`
				Topics  []string `json:"topics"`
			} `json:"logs"`
		} `json:"result"`
		Error *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return false, false, "", "", err
	}
	if payload.Error != nil {
		return false, false, "", "", errors.New(payload.Error.Message)
	}
	if payload.Result == nil {
		return false, false, "", "", nil
	}
	block := ""
	if n, ok := new(big.Int).SetString(strings.TrimPrefix(payload.Result.BlockNumber, "0x"), 16); ok {
		block = n.String()
	}
	account := ""
	for _, log := range payload.Result.Logs {
		if strings.EqualFold(log.Address, c.matchingAddress) && len(log.Topics) == 3 &&
			strings.EqualFold(log.Topics[0], topicDepositedSubAccount) &&
			strings.EqualFold("0x"+log.Topics[2][26:], owner) {
			if id, ok := new(big.Int).SetString(strings.TrimPrefix(log.Topics[1], "0x"), 16); ok {
				account = id.String()
			}
		}
	}
	return true, payload.Result.Status == "0x1", block, account, nil
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

func depositAssetsByAddress(assets []config.DepositAsset) map[string]config.DepositAsset {
	out := make(map[string]config.DepositAsset, len(assets))
	for _, asset := range assets {
		out[strings.ToLower(asset.Address)] = asset
	}
	return out
}

// assetList names the depositable assets for a refusal: "0xa74e… (USDC), 0x37c9… (cNGN)", in a stable order.
func (svc *depositService) assetList() string {
	names := make([]string, 0, len(svc.assets))
	for address, asset := range svc.assets {
		names = append(names, fmt.Sprintf("%s (%s)", address, asset.Symbol))
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// escrowRoom refuses a deposit the asset would turn away under the perp manager: one that no longer accepts it, or one
// that would cross the asset's collateral cap (BM_AssetCapExceeded). The cash asset has no cap -- totalPositionCap
// reverts on it -- so only an escrow is held to one.
func (svc *depositService) escrowRoom(ctx context.Context, data depositData) (string, error) {
	reader := svc.tokens
	if reader == nil {
		return "", nil
	}
	raw, err := reader.ethCall(ctx, data.asset, sigEscrowOpen+addressArg(svc.manager))
	if err != nil {
		return "", err
	}
	if open, err := unsignedWord(raw); err != nil {
		return "", err
	} else if open.Sign() == 0 {
		return fmt.Sprintf("%s deposits are closed: the asset %s does not accept the perp risk manager", data.symbol, data.asset), nil
	}
	raw, err = reader.ethCall(ctx, data.asset, sigEscrowCap+addressArg(svc.manager))
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "revert") {
			return "", nil // no cap on this asset
		}
		return "", err
	}
	capacity, err := unsignedWord(raw)
	if err != nil {
		return "", err
	}
	raw, err = reader.ethCall(ctx, data.asset, sigEscrowTotal+addressArg(svc.manager))
	if err != nil {
		return "", err
	}
	total, err := unsignedWord(raw)
	if err != nil {
		return "", err
	}
	after := new(big.Int).Add(total, depositUnitsToLedger(data.amount))
	if after.Cmp(capacity) > 0 {
		room := new(big.Int).Sub(capacity, total)
		if room.Sign() < 0 {
			room.SetInt64(0)
		}
		return fmt.Sprintf("the deposit would take %s posted under the perp risk manager past its cap of %s %s (%s %s posted, room for %s %s)",
			data.symbol, formatE18Whole(capacity), data.symbol, formatE18Whole(total), data.symbol, formatE18Whole(room), data.symbol), nil
	}
	return "", nil
}

// formatE18Whole prints an 18-decimal amount in whole units, rounded down: "8000000".
func formatE18Whole(value *big.Int) string {
	return new(big.Int).Quo(value, new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)).String()
}

// depositAmounts states a deposit in every unit, under the names for its asset: amount_usdc and credited_cash_e18
// only when the asset is USDC.
func depositAmounts(asset config.DepositAsset, units *big.Int) depositReceipt {
	out := depositReceipt{
		Asset:       asset.Address,
		AssetSymbol: asset.Symbol,
		Amount:      formatDepositUnits(units),
		AmountUnits: units.String(),
		CreditedE18: depositUnitsToLedger(units).String(),
	}
	if asset.Symbol == "USDC" {
		out.AmountUSDC, out.CreditedCashE18 = out.Amount, out.CreditedE18
	}
	return out
}

// assetOf is the configured asset a record names. A record from before migration 000019 names none: those are all
// deposits of the USDC cash asset, the only one accepted then.
func (svc *depositService) assetOf(address string) config.DepositAsset {
	if asset, ok := svc.assets[strings.ToLower(address)]; ok {
		return asset
	}
	for _, asset := range svc.assets {
		if address == "" && asset.Symbol == "USDC" {
			return asset
		}
	}
	return config.DepositAsset{Address: address, Symbol: "unknown"}
}
