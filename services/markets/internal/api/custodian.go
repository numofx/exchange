package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// BookCustodian (contracts/risk-core/src/periphery/BookCustodian.sol, docs/book-custodian-spec.md) holds app users'
// accounts so the OnchainBooks can act on them. POST /custodian relays its calls through execution-service, the venue
// paying gas; GET /custodian/accounts finds a wallet's accounts. The contract checks every signature (the executor
// simulates before sending), so this layer only refuses what should not reach the executor at all.

const (
	sigCustodianAccountOwner = "0x6ed20f8c" // accountOwner(uint256)
	// AccountOpened(uint256 indexed accountId, address indexed wallet, address manager)
	topicCustodianAccountOpened = "0x812c1bdd74b680128ded3a18c4d75aad0accb01055fa1c8479fcc97bd3ae9cd2"
	// AccountDeposited(uint256 indexed accountId, address indexed wallet)
	topicCustodianAccountDeposited = "0xb893a181c25ba295a2d4ad5bb3eb7a9ebc1897ead7027499d9ca4772ff473f5a"

	custodianCallsPerWalletPerMinute = 20
	custodianMaxAccountsListed       = 20
	// publicnode caps eth_getLogs at 50,000 blocks.
	custodianLogChunk    = 40_000
	custodianIndexPeriod = 10 * time.Second
)

// custodianRequest is POST /custodian's body: execution-service's own shape (services/execution/src/custodian.ts),
// forwarded unchanged once checked.
type custodianRequest struct {
	Call           string         `json:"call"`
	Take           *custodianTake `json:"take,omitempty"`
	Signature      string         `json:"signature,omitempty"`
	Reports        string         `json:"reports,omitempty"`
	Wallet         string         `json:"wallet,omitempty"`
	AccountID      string         `json:"account_id,omitempty"`
	Asset          string         `json:"asset,omitempty"`
	Amount         string         `json:"amount,omitempty"`
	PermitDeadline string         `json:"permit_deadline,omitempty"`
	V              *int           `json:"v,omitempty"`
	R              string         `json:"r,omitempty"`
	S              string         `json:"s,omitempty"`
	Nonce          string         `json:"nonce,omitempty"`
	Deadline       string         `json:"deadline,omitempty"`
	Key            string         `json:"key,omitempty"`
	ValidUntil     string         `json:"valid_until,omitempty"`
}

type custodianTake struct {
	AccountID  string `json:"account_id"`
	Book       string `json:"book"`
	MarketID   string `json:"market_id"`
	IsBuy      bool   `json:"is_buy"`
	Amount     string `json:"amount"`
	LimitPrice string `json:"limit_price"`
	MinFill    string `json:"min_fill"`
	MaxFee     string `json:"max_fee"`
	Deadline   string `json:"deadline"`
	MaxLevels  int    `json:"max_levels"`
	ReduceOnly bool   `json:"reduce_only"`
	Nonce      string `json:"nonce"`
}

type custodianChain interface {
	ethCall(ctx context.Context, to string, data string) (string, error)
}

type custodianSubmitter interface {
	Submit(ctx context.Context, request custodianRequest) (json.RawMessage, error)
}

type custodianService struct {
	address   string
	books     []string
	assets    []string
	perpCash  string
	chain     custodianChain
	ledger    withdrawalLedger
	submitter custodianSubmitter
	limiter   *withdrawalLimiter
	index     *custodianAccountIndex
	now       func() time.Time
}

func newCustodianService(cfg config.Config) *custodianService {
	address := strings.ToLower(strings.TrimSpace(cfg.CustodianAddress))
	if !isHexAddress(address) || strings.TrimSpace(cfg.ExecutorCustodianURL) == "" {
		return nil
	}
	if len(cfg.CustodianAssets) == 0 || len(cfg.BookTakeBooks) == 0 || strings.TrimSpace(cfg.ChainRPCURL) == "" ||
		!isHexAddress(cfg.MatchingAddress) {
		slog.Warn("custodian_disabled", "reason", "CUSTODIAN_ASSETS, BOOK_TAKE_BOOKS, CHAIN_RPC_URL or MATCHING_ADDRESS is not configured")
		return nil
	}
	chain := &chainCustodyChecker{
		rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
		matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
		httpClient:      &http.Client{Timeout: 5 * time.Second},
	}
	perpCash := strings.ToLower(strings.TrimSpace(cfg.CNGNPerpCashAddress))
	var ledger withdrawalLedger
	if isHexAddress(perpCash) {
		ledger = &chainCashLedger{chain: chain, cash: perpCash}
	}
	return &custodianService{
		address:  address,
		books:    cfg.BookTakeBooks,
		assets:   cfg.CustodianAssets,
		perpCash: perpCash,
		chain:    chain,
		ledger:   ledger,
		submitter: &executorCustodianClient{
			url:        strings.TrimSpace(cfg.ExecutorCustodianURL),
			httpClient: &http.Client{Timeout: cfg.ExecutorWithdrawTimeout},
		},
		limiter: newWithdrawalLimiter(custodianCallsPerWalletPerMinute),
		index: &custodianAccountIndex{
			custodian: address,
			rpc:       &jsonRPC{url: strings.TrimSpace(cfg.ChainRPCURL), httpClient: &http.Client{Timeout: 10 * time.Second}},
			next:      cfg.CustodianDeployBlock,
			wallets:   map[string]map[string]bool{},
		},
		now: time.Now,
	}
}

// handleCustodian serves POST /custodian. In order, each failing closed:
//
//  1. the request's shape, and the venue's own policy: a listed book, a listed asset, a deadline in the next
//     minutes (400)
//  2. the custodian holds the account (one chain read; 400), whose wallet is then the rate-limit key
//  3. a relayed withdrawal of cash never takes the account's cash below zero: the venue does not pay out borrowed
//     cash (409)
//  4. one call in flight per wallet, and a bounded rate (429)
//  5. execution-service's verdict: 200 with the receipt (and `account_id` for an opened account), or 422 naming
//     the revert its simulation hit (BC_BadSignature, BC_NonceUsed, OB_BelowMinFill, ...)
func (s *Server) handleCustodian(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	svc := s.custodian
	if svc == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "custodian calls are not enabled"})
		return
	}
	var req custodianRequest
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, withdrawalMaxBodyBytes))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	accountID, err := svc.validate(req)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorBody(err))
		return
	}

	wallet := strings.ToLower(strings.TrimSpace(req.Wallet))
	if accountID != "" {
		recorded, err := svc.accountWallet(r.Context(), accountID)
		if err != nil {
			slog.Warn("custodian_owner_unreadable", "account_id", accountID, "error", err)
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the account's owner could not be read from the chain; retry shortly"})
			return
		}
		if recorded == zeroAddress {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": fmt.Sprintf("account %s is not held by the custodian", accountID)})
			return
		}
		wallet = recorded
	}
	if req.Call == "withdraw_for" {
		refusal, err := svc.cashFloor(r.Context(), accountID, req.Asset, req.Amount)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the account's cash could not be read; retry shortly"})
			return
		}
		if refusal != "" {
			writeJSON(w, http.StatusConflict, map[string]string{"error": refusal})
			return
		}
	}

	if !svc.limiter.acquire(wallet, svc.now()) {
		writeJSON(w, http.StatusTooManyRequests, map[string]string{"error": "a call for this wallet is already in progress, or too many were requested; retry shortly"})
		return
	}
	defer svc.limiter.release(wallet)

	body, err := svc.submitter.Submit(r.Context(), req)
	if err != nil {
		var rejected *executorWithdrawError
		if errors.As(err, &rejected) && (rejected.Status == http.StatusUnprocessableEntity || rejected.Status == http.StatusServiceUnavailable) {
			out := map[string]string{"error": nonEmpty(rejected.Message, "custodian calls are not enabled on the executor")}
			if rejected.Revert != "" {
				out["revert"] = rejected.Revert
			}
			slog.Info("custodian_rejected", "call", req.Call, "wallet", wallet, "revert", rejected.Revert, "error", rejected.Message)
			writeJSON(w, rejected.Status, out)
			return
		}
		// It may have been broadcast: unknown, not failed. Resending the same signed request is safe (its nonce is
		// spent once); a freshly signed one could act twice.
		slog.Error("custodian_submit_failed", "call", req.Call, "wallet", wallet, "error", err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "could not confirm whether the call was submitted; check the account before trying again"})
		return
	}
	slog.Info("custodian_submitted", "call", req.Call, "wallet", wallet, "account_id", accountID)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// validate returns the account the call acts on ("" for open_account and set_trading_key_for).
func (svc *custodianService) validate(req custodianRequest) (string, error) {
	now := svc.now().Unix()
	uintField := func(name, value string) (*big.Int, error) { return parseUint256Decimal(name, value) }
	deadline := func(name, value string, maxAhead int64) error {
		d, err := uintField(name, value)
		if err != nil {
			return err
		}
		if d.Cmp(big.NewInt(now)) < 0 {
			return fmt.Errorf("%s has passed", name)
		}
		if maxAhead > 0 && d.Cmp(big.NewInt(now+maxAhead)) > 0 {
			return fmt.Errorf("%s is more than %ds away", name, maxAhead)
		}
		return nil
	}
	signature := func() error {
		if len(strings.TrimPrefix(strings.TrimSpace(req.Signature), "0x")) < 130 || !isHex(req.Signature) {
			return errors.New("signature must be hex of at least 65 bytes")
		}
		return nil
	}
	account := func() (string, error) {
		id, err := uintField("account_id", req.AccountID)
		if err != nil {
			return "", err
		}
		if id.Sign() == 0 {
			return "", errors.New("account_id must not be 0")
		}
		return id.String(), nil
	}
	asset := func() error {
		if !containsFold(svc.assets, strings.TrimSpace(req.Asset)) {
			return fmt.Errorf("asset %s is not deposited or withdrawn through the custodian", req.Asset)
		}
		amount, err := uintField("amount", req.Amount)
		if err != nil {
			return err
		}
		if amount.Sign() == 0 {
			return errors.New("amount must be greater than 0")
		}
		return nil
	}

	switch req.Call {
	case "take":
		t := req.Take
		if t == nil {
			return "", errors.New("take is required")
		}
		if !containsFold(svc.books, strings.TrimSpace(t.Book)) {
			return "", fmt.Errorf("book %s is not traded through the custodian", t.Book)
		}
		for _, f := range []struct{ name, value string }{{"take.market_id", t.MarketID}, {"take.min_fill", t.MinFill}, {"take.max_fee", t.MaxFee}, {"take.nonce", t.Nonce}} {
			if _, err := uintField(f.name, f.value); err != nil {
				return "", err
			}
		}
		for _, f := range []struct{ name, value string }{{"take.amount", t.Amount}, {"take.limit_price", t.LimitPrice}} {
			v, err := uintField(f.name, f.value)
			if err != nil {
				return "", err
			}
			if v.Sign() == 0 {
				return "", fmt.Errorf("%s must be greater than 0", f.name)
			}
		}
		if t.MaxLevels < 1 || t.MaxLevels > 65535 {
			return "", errors.New("take.max_levels must be 1 to 65535")
		}
		if err := deadline("take.deadline", t.Deadline, 600); err != nil {
			return "", err
		}
		if err := signature(); err != nil {
			return "", err
		}
		if req.Reports != "" && !isHex(req.Reports) {
			return "", errors.New("reports must be hex")
		}
		id, err := parseUint256Decimal("take.account_id", t.AccountID)
		if err != nil {
			return "", err
		}
		if id.Sign() == 0 {
			return "", errors.New("take.account_id must not be 0")
		}
		return id.String(), nil
	case "open_account":
		if !isHexAddress(req.Wallet) || strings.EqualFold(req.Wallet, zeroAddress) {
			return "", errors.New("wallet must be a non-zero address")
		}
		return "", nil
	case "deposit_with_permit":
		if err := asset(); err != nil {
			return "", err
		}
		if err := deadline("permit_deadline", req.PermitDeadline, 0); err != nil {
			return "", err
		}
		if req.V == nil || !isBytes32(req.R) || !isBytes32(req.S) {
			return "", errors.New("v, r and s are the permit's signature")
		}
		return account()
	case "withdraw_for":
		if err := asset(); err != nil {
			return "", err
		}
		if _, err := uintField("nonce", req.Nonce); err != nil {
			return "", err
		}
		if err := deadline("deadline", req.Deadline, 3600); err != nil {
			return "", err
		}
		if err := signature(); err != nil {
			return "", err
		}
		return account()
	case "exit_for":
		if _, err := uintField("nonce", req.Nonce); err != nil {
			return "", err
		}
		if err := deadline("deadline", req.Deadline, 3600); err != nil {
			return "", err
		}
		if err := signature(); err != nil {
			return "", err
		}
		return account()
	case "set_trading_key_for":
		if !isHexAddress(req.Wallet) || !isHexAddress(req.Key) {
			return "", errors.New("wallet and key must be addresses")
		}
		for _, f := range []struct{ name, value string }{{"valid_until", req.ValidUntil}, {"nonce", req.Nonce}} {
			if _, err := uintField(f.name, f.value); err != nil {
				return "", err
			}
		}
		if err := deadline("deadline", req.Deadline, 3600); err != nil {
			return "", err
		}
		return "", signature()
	default:
		return "", fmt.Errorf("call %q is not relayed", req.Call)
	}
}

// accountWallet is the custodian's record for the account, lowercased; the zero address when it holds none.
func (svc *custodianService) accountWallet(ctx context.Context, accountID string) (string, error) {
	encoded, err := encodeUint256(accountID)
	if err != nil {
		return "", err
	}
	raw, err := svc.chain.ethCall(ctx, svc.address, sigCustodianAccountOwner+encoded)
	if err != nil {
		return "", err
	}
	return decodeAddress(raw)
}

// cashFloor: as for POST /withdrawals, a relayed withdrawal of the venue's cash may not take it below zero.
func (svc *custodianService) cashFloor(ctx context.Context, accountID, asset, amount string) (string, error) {
	if svc.ledger == nil || !strings.EqualFold(asset, svc.perpCash) {
		return "", nil
	}
	want, err := parseUint256Decimal("amount", amount)
	if err != nil {
		return "", err
	}
	balance, err := svc.ledger.CashBalance(ctx, accountID)
	if err != nil {
		return "", err
	}
	want18 := new(big.Int).Mul(want, new(big.Int).Exp(big.NewInt(10), big.NewInt(18-perpCashTokenDecimals), nil))
	if balance.Sign() <= 0 || want18.Cmp(balance) > 0 {
		return "cash_floor: this withdrawal would take the account's cash below zero; the venue does not pay out " +
			"borrowed cash. Close positions or deposit USDC first, or withdraw from your wallet directly", nil
	}
	return "", nil
}

// handleCustodianAccounts serves GET /custodian/accounts?wallet=: the accounts the custodian holds for a wallet,
// from its AccountOpened and AccountDeposited events, each confirmed against `accountOwner` now. 503 until the index
// has caught up with the chain.
func (s *Server) handleCustodianAccounts(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	svc := s.custodian
	if svc == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "custodian calls are not enabled"})
		return
	}
	wallet := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("wallet")))
	if !isHexAddress(wallet) {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "wallet must be an address"})
		return
	}
	candidates, synced := svc.index.accountsOf(wallet)
	if !synced {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the custodian index is catching up; retry shortly"})
		return
	}
	held := []string{}
	for _, id := range candidates {
		if len(held) == custodianMaxAccountsListed {
			break
		}
		recorded, err := svc.accountWallet(r.Context(), id)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "an account's owner could not be read; retry shortly"})
			return
		}
		if recorded == wallet {
			held = append(held, id)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"wallet": wallet, "custodian": svc.address, "accounts": held})
}

// custodianAccountIndex is every (wallet, account) pair the custodian has ever recorded, from its events. In memory,
// rebuilt at start in the background (the endpoint answers 503 until then): a candidate list, never trusted alone.
type custodianAccountIndex struct {
	custodian string
	rpc       rpcCaller
	mu        sync.RWMutex
	next      uint64
	synced    bool
	wallets   map[string]map[string]bool
}

type rpcCaller interface {
	call(ctx context.Context, method string, params []any) (json.RawMessage, error)
}

func (x *custodianAccountIndex) accountsOf(wallet string) ([]string, bool) {
	x.mu.RLock()
	defer x.mu.RUnlock()
	ids := make([]string, 0, len(x.wallets[wallet]))
	for id := range x.wallets[wallet] {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool {
		a, _ := new(big.Int).SetString(ids[i], 10)
		b, _ := new(big.Int).SetString(ids[j], 10)
		return a.Cmp(b) > 0
	})
	return ids, x.synced
}

// run indexes until ctx ends: every custodianIndexPeriod, from the last indexed block to the head, in chunks.
func (x *custodianAccountIndex) run(ctx context.Context) {
	for {
		if err := x.catchUp(ctx); err != nil && !errors.Is(err, context.Canceled) {
			slog.Warn("custodian_index_failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(custodianIndexPeriod):
		}
	}
}

func (x *custodianAccountIndex) catchUp(ctx context.Context) error {
	raw, err := x.rpc.call(ctx, "eth_blockNumber", []any{})
	if err != nil {
		return err
	}
	var headHex string
	if err := json.Unmarshal(raw, &headHex); err != nil {
		return err
	}
	head, err := strconv.ParseUint(strings.TrimPrefix(headHex, "0x"), 16, 64)
	if err != nil {
		return err
	}
	for {
		x.mu.RLock()
		from := x.next
		x.mu.RUnlock()
		if from > head {
			x.mu.Lock()
			x.synced = true
			x.mu.Unlock()
			return nil
		}
		to := min(from+custodianLogChunk-1, head)
		logs, err := x.logs(ctx, from, to)
		if err != nil {
			return err
		}
		x.mu.Lock()
		for _, l := range logs {
			if len(l.Topics) < 3 {
				continue
			}
			id, ok := new(big.Int).SetString(strings.TrimPrefix(l.Topics[1], "0x"), 16)
			if !ok {
				continue
			}
			wallet := "0x" + strings.ToLower(l.Topics[2][len(l.Topics[2])-40:])
			if x.wallets[wallet] == nil {
				x.wallets[wallet] = map[string]bool{}
			}
			x.wallets[wallet][id.String()] = true
		}
		x.next = to + 1
		x.mu.Unlock()
	}
}

type custodianLog struct {
	Topics []string `json:"topics"`
}

func (x *custodianAccountIndex) logs(ctx context.Context, from, to uint64) ([]custodianLog, error) {
	raw, err := x.rpc.call(ctx, "eth_getLogs", []any{map[string]any{
		"address":   x.custodian,
		"fromBlock": fmt.Sprintf("0x%x", from),
		"toBlock":   fmt.Sprintf("0x%x", to),
		"topics":    []any{[]string{topicCustodianAccountOpened, topicCustodianAccountDeposited}},
	}})
	if err != nil {
		return nil, err
	}
	var logs []custodianLog
	if err := json.Unmarshal(raw, &logs); err != nil {
		return nil, fmt.Errorf("decode custodian logs: %w", err)
	}
	return logs, nil
}

type jsonRPC struct {
	url        string
	httpClient *http.Client
}

func (c *jsonRPC) call(ctx context.Context, method string, params []any) (json.RawMessage, error) {
	body, err := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("content-type", "application/json")
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%s: http %d", method, resp.StatusCode)
	}
	var out struct {
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	if out.Error != nil {
		return nil, fmt.Errorf("%s: %s", method, out.Error.Message)
	}
	return out.Result, nil
}

// executorCustodianClient forwards to execution-service's POST /custodian, returning its 200 body as is.
type executorCustodianClient struct {
	url        string
	httpClient *http.Client
}

func (c *executorCustodianClient) Submit(ctx context.Context, request custodianRequest) (json.RawMessage, error) {
	body, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("post to execution-service: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	switch resp.StatusCode {
	case http.StatusOK:
		var receipt struct {
			TxHash string `json:"tx_hash"`
		}
		if err := json.Unmarshal(raw, &receipt); err != nil || receipt.TxHash == "" {
			return nil, errors.New("execution-service returned no tx_hash")
		}
		return raw, nil
	case http.StatusUnprocessableEntity, http.StatusServiceUnavailable:
		var payload struct {
			Error  string `json:"error"`
			Revert string `json:"revert"`
		}
		_ = json.Unmarshal(raw, &payload)
		return nil, &executorWithdrawError{Status: resp.StatusCode, Message: payload.Error, Revert: payload.Revert}
	default:
		text := string(raw)
		if len(text) > 512 {
			text = text[:512]
		}
		return nil, fmt.Errorf("execution-service returned %d: %s", resp.StatusCode, text)
	}
}

func isHex(value string) bool {
	v := strings.TrimPrefix(strings.TrimSpace(value), "0x")
	if len(v)%2 != 0 {
		return false
	}
	return strings.Trim(strings.ToLower(v), "0123456789abcdef") == ""
}

func isBytes32(value string) bool {
	return len(strings.TrimPrefix(strings.TrimSpace(value), "0x")) == 64 && isHex(value)
}
