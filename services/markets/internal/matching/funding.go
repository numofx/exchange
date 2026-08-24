package matching

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
)

// A buy leg costs the taker quote *plus* the fee, and both land in the same batch.
//
// TradeModule._addAssetTransfers appends the fee as a third quote-asset transfer alongside
// the quote and base legs. SubAccounts.submitTransfers applies the whole batch and then runs
// one handleAdjustment per account, so the manager sees a single NET cash delta:
//
//	buyer   -(notional + fee)
//	seller  +notional - fee
//
// Under the SRM at marginFactor 0 with borrowing disabled, netMargin for a spot-only account
// reduces to cash, so a buyer short by even one wei reverts SRM_NoNegativeCash. Crossing on
// notional alone therefore emits matches that cannot settle: the order is accepted, crossed,
// and the settlement transaction reverts after the book has already moved.
//
// The seller side needs no check while notional > fee, because the proceeds arrive in the same
// adjustment the fee is taken from -- the gross fee never has to be pre-funded.
//
// DUST CASE: that inequality is an assumption, not an invariant. If a fill is small enough that
// notional <= fee, the seller's net delta goes negative too and a cash-free seller reverts
// exactly like an underfunded buyer. It cannot happen today -- takerFillFee and makerFillFeeZero
// are both "0", so a seller's net delta is always +notional -- and it stays impossible for any
// proportional fee, where fee = notional * rate < notional for rate < 1. It becomes reachable the
// moment a FLAT or minimum fee is introduced, because a dust fill can then owe more than it
// earns. If that happens, gate the sell side here too; do not assume the buy check covers it.
// The on-chain boundary is pinned by risk-core's testFork_CashFreeSellerSettlesOnNetDelta.
//
// This is a pre-trade check, not a safety boundary. The chain is the enforcement; this exists
// so the venue does not reject exactly-funded orders after crossing them.

// quoteScale is the fixed-point base of the on-chain quote math: amtQuote is
// price.multiplyDecimal(amountFilled), i.e. price * amount / 1e18, with both operands in 18dp.
var quoteScale = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

// requiredQuote returns the cash a buyer must hold to settle this fill: the notional plus the
// fee they will be charged in the same batch.
func requiredQuote(fillPrice string, fillAmount string, takerFee string) (*big.Int, error) {
	price, err := parsePositiveInt(fillPrice, "fill_price")
	if err != nil {
		return nil, err
	}
	amount, err := parsePositiveInt(fillAmount, "fill_amount")
	if err != nil {
		return nil, err
	}
	fee, err := parseNonNegativeInt(takerFee, "taker_fee")
	if err != nil {
		return nil, err
	}

	notional := new(big.Int).Mul(price, amount)
	notional.Div(notional, quoteScale)

	// The on-chain multiplyDecimal truncates, so a fill whose product is below 1 wei of quote
	// costs the buyer nothing and cannot be what this check is protecting.
	return notional.Add(notional, fee), nil
}

// fundingChecker reports the cash balance of a subaccount, in 18dp quote units.
type fundingChecker interface {
	CashBalance(ctx context.Context, subaccountID string) (*big.Int, error)
}

// buyerCanFund reports whether the buy side of a prospective fill can settle. It returns the
// shortfall when it cannot, so the caller can log something a human can act on.
//
// A nil checker means the check is disabled and every pair is allowed through.
func buyerCanFund(
	ctx context.Context,
	checker fundingChecker,
	candidate orders.MatchCandidate,
	fillPrice string,
	fillAmount string,
	takerFee string,
) (ok bool, required *big.Int, available *big.Int, err error) {
	if checker == nil {
		return true, nil, nil, nil
	}

	buyer, buyerIsTaker := buyerOf(candidate)
	if buyer == nil {
		return false, nil, nil, errors.New("match candidate has no buy side")
	}

	// only the taker is charged a fee on this venue; maker fills are fee-free and enforced so
	// in execution-service, so a maker-side buyer owes notional only
	fee := takerFee
	if !buyerIsTaker {
		fee = "0"
	}

	required, err = requiredQuote(fillPrice, fillAmount, fee)
	if err != nil {
		return false, nil, nil, err
	}

	available, err = checker.CashBalance(ctx, buyer.SubaccountID)
	if err != nil {
		return false, required, nil, err
	}

	return available.Cmp(required) >= 0, required, available, nil
}

func buyerOf(candidate orders.MatchCandidate) (*orders.Order, bool) {
	if candidate.Taker.Side == orders.SideBuy {
		return &candidate.Taker, true
	}
	if candidate.Maker.Side == orders.SideBuy {
		return &candidate.Maker, false
	}
	return nil, false
}

// ---------------------------------------------------------------------------------------------
// chain-backed implementation
// ---------------------------------------------------------------------------------------------

const (
	// SubAccounts.getBalance(uint256 accountId, address asset, uint256 subId) -> int256
	getBalanceSelector = "0x0806e640"
	// Matching.subAccounts() -> address
	subAccountsSelector = "0x779e5012"
)

type chainFundingChecker struct {
	rpcURL          string
	matchingAddress string
	cashAsset       string
	httpClient      *http.Client
	ttl             time.Duration
	now             func() time.Time

	mu              sync.Mutex
	subAccountsAddr string
	cache           map[string]cachedBalance
}

type cachedBalance struct {
	value *big.Int
	at    time.Time
}

// newFundingChecker returns nil when the check is disabled or not configured, which
// buyerCanFund treats as "allow everything". A misconfigured checker must not silently
// become a permanent halt on matching.
func newFundingChecker(cfg config.Config) fundingChecker {
	if !cfg.EnforceFundingCheck {
		slog.Warn(
			"funding_check_disabled",
			"reason", "ENFORCE_FUNDING_CHECK=false",
			"effect", "underfunded buys are only caught when the settlement transaction reverts",
		)
		return nil
	}
	if strings.TrimSpace(cfg.ChainRPCURL) == "" || !isHexAddress(cfg.CashAssetAddress) || !isHexAddress(cfg.MatchingAddress) {
		// config.Load refuses to start in production for exactly this, so reaching here means a
		// dev or test environment. Say so anyway: a silently inert guard is the failure mode this
		// whole path exists to avoid.
		slog.Warn(
			"funding_check_inert",
			"reason", "CASH_ASSET_ADDRESS, MATCHING_ADDRESS or CHAIN_RPC_URL is unset",
			"cash_asset_set", isHexAddress(cfg.CashAssetAddress),
			"matching_address_set", isHexAddress(cfg.MatchingAddress),
			"chain_rpc_set", strings.TrimSpace(cfg.ChainRPCURL) != "",
			"app_env", cfg.AppEnv,
			"effect", "matching proceeds without a pre-trade funding check",
		)
		return nil
	}
	slog.Info(
		"funding_check_enabled",
		"cash_asset", strings.ToLower(strings.TrimSpace(cfg.CashAssetAddress)),
	)
	return &chainFundingChecker{
		rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
		matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
		cashAsset:       strings.ToLower(strings.TrimSpace(cfg.CashAssetAddress)),
		httpClient:      &http.Client{Timeout: 5 * time.Second},
		ttl:             2 * time.Second,
		now:             time.Now,
		cache:           map[string]cachedBalance{},
	}
}

func (c *chainFundingChecker) CashBalance(ctx context.Context, subaccountID string) (*big.Int, error) {
	subaccountID = strings.TrimSpace(subaccountID)
	if subaccountID == "" {
		return nil, errors.New("subaccount_id is required")
	}

	if cached, ok := c.cached(subaccountID); ok {
		return cached, nil
	}

	subAccounts, err := c.subAccountsAddress(ctx)
	if err != nil {
		return nil, fmt.Errorf("resolve subaccounts contract: %w", err)
	}

	accountWord, err := encodeUint256Word(subaccountID)
	if err != nil {
		return nil, err
	}
	data := getBalanceSelector + accountWord + encodeAddressArg(c.cashAsset) + strings.Repeat("0", 64)

	raw, err := c.ethCall(ctx, subAccounts, data)
	if err != nil {
		return nil, fmt.Errorf("read cash balance: %w", err)
	}
	balance, err := decodeInt256(raw)
	if err != nil {
		return nil, err
	}

	c.store(subaccountID, balance)
	return balance, nil
}

func (c *chainFundingChecker) cached(subaccountID string) (*big.Int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := c.cache[subaccountID]
	if !ok || c.now().Sub(entry.at) > c.ttl {
		return nil, false
	}
	return new(big.Int).Set(entry.value), true
}

func (c *chainFundingChecker) store(subaccountID string, value *big.Int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.cache[subaccountID] = cachedBalance{value: new(big.Int).Set(value), at: c.now()}
}

func (c *chainFundingChecker) subAccountsAddress(ctx context.Context) (string, error) {
	c.mu.Lock()
	cached := c.subAccountsAddr
	c.mu.Unlock()
	if cached != "" {
		return cached, nil
	}

	raw, err := c.ethCall(ctx, c.matchingAddress, subAccountsSelector)
	if err != nil {
		return "", err
	}
	address, err := decodeAddressWord(raw)
	if err != nil {
		return "", err
	}

	c.mu.Lock()
	c.subAccountsAddr = address
	c.mu.Unlock()
	return address, nil
}

func (c *chainFundingChecker) ethCall(ctx context.Context, to string, data string) (string, error) {
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "eth_call",
		"params":  []any{map[string]string{"to": to, "data": data}, "latest"},
	})
	if err != nil {
		return "", err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.rpcURL, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("content-type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("rpc status %d", resp.StatusCode)
	}

	var payload struct {
		Result string `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if payload.Error != nil {
		return "", errors.New(payload.Error.Message)
	}
	if strings.TrimSpace(payload.Result) == "" {
		return "", errors.New("empty rpc result")
	}
	return strings.ToLower(strings.TrimSpace(payload.Result)), nil
}

// ---------------------------------------------------------------------------------------------
// encoding helpers
// ---------------------------------------------------------------------------------------------

func encodeUint256Word(raw string) (string, error) {
	value, ok := new(big.Int).SetString(strings.TrimSpace(raw), 10)
	if !ok || value.Sign() < 0 {
		return "", fmt.Errorf("invalid subaccount_id %q", raw)
	}
	return fmt.Sprintf("%064x", value), nil
}

func encodeAddressArg(address string) string {
	return strings.Repeat("0", 24) + strings.TrimPrefix(strings.ToLower(address), "0x")
}

// decodeInt256 reads a two's-complement word. Cash can legitimately be negative when borrowing
// is enabled, so this must not be read as a uint.
func decodeInt256(raw string) (*big.Int, error) {
	cleaned := strings.TrimPrefix(strings.TrimSpace(strings.ToLower(raw)), "0x")
	if len(cleaned) < 64 {
		return nil, fmt.Errorf("short int256 payload %q", raw)
	}
	word := cleaned[len(cleaned)-64:]
	value, ok := new(big.Int).SetString(word, 16)
	if !ok {
		return nil, fmt.Errorf("invalid int256 payload %q", raw)
	}
	if word[0] >= '8' {
		value.Sub(value, new(big.Int).Lsh(big.NewInt(1), 256))
	}
	return value, nil
}

func decodeAddressWord(raw string) (string, error) {
	cleaned := strings.TrimPrefix(strings.TrimSpace(strings.ToLower(raw)), "0x")
	if len(cleaned) < 64 {
		return "", fmt.Errorf("short address payload %q", raw)
	}
	return "0x" + cleaned[len(cleaned)-40:], nil
}

func isHexAddress(value string) bool {
	trimmed := strings.TrimSpace(strings.ToLower(value))
	if !strings.HasPrefix(trimmed, "0x") || len(trimmed) != 42 {
		return false
	}
	for _, r := range trimmed[2:] {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return trimmed != zeroAddressLower
}

const zeroAddressLower = "0x0000000000000000000000000000000000000000"
