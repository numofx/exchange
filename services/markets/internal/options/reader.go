// Package options reads an OptionAsset series and its engine for the matcher: whether a strike may trade now, and
// what a fill does to each account's initial margin.
package options

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// Selectors from `cast sig`; internal/selectorcheck checks each against the compiled ABIs.
const (
	sigTotalPositionCap       = "0x745ab570" // totalPositionCap(address)
	sigIsDatedFutureAsset     = "0x761822ef" // isDatedFutureAsset(address)
	sigIsPerpAsset            = "0x4a318e69" // isPerpAsset(address)
	sigAdjustmentsPaused      = "0xac06ba05" // adjustmentsPaused()
	sigGetExpiryMinConfidence = "0xd4435817" // getExpiryMinConfidence(uint64)
	sigGetMargin              = "0x623bb445" // getMargin(uint256,bool)
	sigGetIsolatedMargin      = "0xba00770b" // getIsolatedMargin(uint256,uint256,uint256,bool,int256,bool)
	sigAssetDetails           = "0xd21415a3" // assetDetails(address)
	sigGetBalance             = "0x0806e640" // getBalance(uint256,address,uint256)
	sigSubAccounts            = "0x779e5012" // subAccounts()
)

// Reader reads one series (one OptionAsset at one expiry): its trading switches, cached for stateTTL, and its accounts.
type Reader struct {
	rpcURL      string
	option      string
	manager     string
	volFeed     string
	expiry      int64
	tradingEnds int64
	stateTTL    time.Duration
	http        *http.Client
	now         func() time.Time

	mu          sync.Mutex
	marketID    *big.Int
	subAccounts string
	open        *openState
}

type openState struct {
	at     time.Time
	open   bool
	reason string
}

// NewReader reads a configured series.
func NewReader(rpcURL string, series config.OptionSeries, stateTTL time.Duration) *Reader {
	return &Reader{
		rpcURL:      strings.TrimSpace(rpcURL),
		option:      series.AssetAddress,
		manager:     series.ManagerAddress,
		volFeed:     series.VolFeedAddress,
		expiry:      series.Expiry,
		tradingEnds: series.TradingEnds(),
		stateTTL:    stateTTL,
		http:        &http.Client{Timeout: 5 * time.Second},
		now:         time.Now,
	}
}

// TradingOpen reports whether the series may match now, and why not:
//   - before its last trade time (the vol feed cannot be published past expiry, so margin stops soon after);
//   - the TradeModule treats the option as neither perp nor dated future, so a fill moves the premium;
//   - the option has a position cap under its engine (the enable batch), and the engine is not paused;
//   - the vol feed has a live surface for the expiry: without one no option account can be margined.
func (r *Reader) TradingOpen(ctx context.Context, tradeModule string) (bool, string, error) {
	r.mu.Lock()
	if r.open != nil && r.now().Sub(r.open.at) < r.stateTTL {
		state := *r.open
		r.mu.Unlock()
		return state.open, state.reason, nil
	}
	r.mu.Unlock()
	open, reason, err := r.readOpen(ctx, tradeModule)
	if err != nil {
		return false, "", err
	}
	r.mu.Lock()
	r.open = &openState{at: r.now(), open: open, reason: reason}
	r.mu.Unlock()
	return open, reason, nil
}

func (r *Reader) readOpen(ctx context.Context, tradeModule string) (bool, string, error) {
	if r.now().Unix() >= r.tradingEnds {
		return false, "the series is past its last trade time", nil
	}
	for _, check := range []struct{ sig, why string }{
		{sigIsDatedFutureAsset, "the TradeModule treats the option as a dated future: a fill would move no premium"},
		{sigIsPerpAsset, "the TradeModule treats the option as a perp: a fill would move no premium"},
	} {
		registered, err := r.boolCall(ctx, tradeModule, check.sig+addressWord(r.option))
		if err != nil {
			return false, "", err
		}
		if registered {
			return false, check.why, nil
		}
	}
	capRaw, err := r.call(ctx, r.option, sigTotalPositionCap+addressWord(r.manager))
	if err != nil {
		return false, "", err
	}
	positionCap, err := word(capRaw, 0)
	if err != nil {
		return false, "", fmt.Errorf("totalPositionCap: %w", err)
	}
	if positionCap.Sign() == 0 {
		return false, "the option has no position cap under its engine (the enable batch has not landed)", nil
	}
	paused, err := r.boolCall(ctx, r.manager, sigAdjustmentsPaused)
	if err != nil {
		return false, "", err
	}
	if paused {
		return false, "the engine is paused", nil
	}
	if _, err := r.call(ctx, r.volFeed, sigGetExpiryMinConfidence+uintWord(big.NewInt(r.expiry))); err != nil {
		var reverted *revertError
		if errors.As(err, &reverted) {
			return false, "the vol feed has no live surface for the expiry", nil
		}
		return false, "", err
	}
	return true, "", nil
}

// IMSurplus is engine.getMargin(account, true): the initial-margin surplus in USD, 18dp, signed.
func (r *Reader) IMSurplus(ctx context.Context, account *big.Int) (*big.Int, error) {
	raw, err := r.call(ctx, r.manager, sigGetMargin+uintWord(account)+uintWord(big.NewInt(1)))
	if err != nil {
		return nil, err
	}
	value, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("getMargin: %w", err)
	}
	return signed(value), nil
}

// Position is the account's balance of one strike and side (sub id), 18dp base units, signed.
func (r *Reader) Position(ctx context.Context, account *big.Int, subID string) (*big.Int, error) {
	return r.balance(ctx, account, r.option, subID)
}

// Cash is the account's balance of an asset at sub id 0 (the premium's cash), 18dp, signed.
func (r *Reader) Cash(ctx context.Context, account *big.Int, cash string) (*big.Int, error) {
	return r.balance(ctx, account, cash, "0")
}

func (r *Reader) balance(ctx context.Context, account *big.Int, asset, subID string) (*big.Int, error) {
	id, ok := new(big.Int).SetString(subID, 10)
	if !ok {
		return nil, fmt.Errorf("sub id %q is not an integer", subID)
	}
	ledger, err := r.ledger(ctx)
	if err != nil {
		return nil, err
	}
	raw, err := r.call(ctx, ledger, sigGetBalance+uintWord(account)+addressWord(asset)+uintWord(id))
	if err != nil {
		return nil, err
	}
	value, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("getBalance: %w", err)
	}
	return signed(value), nil
}

// IsolatedIM is engine.getIsolatedMargin(market, strike, expiry, isCall, balance, true)'s margin: the initial margin
// the engine charges a position of `balance` in one strike on its own (0 for a long; for a short its mark-to-market
// plus the spot add-on), as a signed requirement (negative).
func (r *Reader) IsolatedIM(ctx context.Context, strike *big.Int, isCall bool, balance *big.Int) (*big.Int, error) {
	if balance.Sign() >= 0 {
		return big.NewInt(0), nil
	}
	market, err := r.market(ctx)
	if err != nil {
		return nil, err
	}
	call := big.NewInt(0)
	if isCall {
		call = big.NewInt(1)
	}
	raw, err := r.call(ctx, r.manager, sigGetIsolatedMargin+uintWord(market)+uintWord(strike)+uintWord(big.NewInt(r.expiry))+
		uintWord(call)+intWord(balance)+uintWord(big.NewInt(1)))
	if err != nil {
		return nil, err
	}
	value, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("getIsolatedMargin: %w", err)
	}
	return signed(value), nil
}

// market is the engine's market id for the option, from assetDetails (word 1), read once.
func (r *Reader) market(ctx context.Context) (*big.Int, error) {
	r.mu.Lock()
	if r.marketID != nil {
		id := r.marketID
		r.mu.Unlock()
		return id, nil
	}
	r.mu.Unlock()
	raw, err := r.call(ctx, r.manager, sigAssetDetails+addressWord(r.option))
	if err != nil {
		return nil, err
	}
	whitelisted, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("assetDetails: %w", err)
	}
	if whitelisted.Sign() == 0 {
		return nil, errors.New("the engine does not whitelist the option")
	}
	id, err := word(raw, 1)
	if err != nil {
		return nil, fmt.Errorf("assetDetails: %w", err)
	}
	r.mu.Lock()
	r.marketID = id
	r.mu.Unlock()
	return id, nil
}

func (r *Reader) ledger(ctx context.Context) (string, error) {
	r.mu.Lock()
	ledger := r.subAccounts
	r.mu.Unlock()
	if ledger != "" {
		return ledger, nil
	}
	raw, err := r.call(ctx, r.option, sigSubAccounts)
	if err != nil {
		return "", err
	}
	if len(raw) < 2+64 {
		return "", errors.New("subAccounts: short result")
	}
	ledger = "0x" + raw[len(raw)-40:]
	r.mu.Lock()
	r.subAccounts = ledger
	r.mu.Unlock()
	return ledger, nil
}

func (r *Reader) boolCall(ctx context.Context, to, data string) (bool, error) {
	raw, err := r.call(ctx, to, data)
	if err != nil {
		return false, err
	}
	value, err := word(raw, 0)
	if err != nil {
		return false, err
	}
	return value.Sign() != 0, nil
}

// revertError is an eth_call the node executed and the contract reverted: a fact about the chain, unlike a transport
// failure, so a gate may read it as "closed".
type revertError struct{ message string }

func (e *revertError) Error() string { return e.message }

func (r *Reader) call(ctx context.Context, to, data string) (string, error) {
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "eth_call",
		"params": []any{map[string]string{"to": to, "data": data}, "latest"},
	})
	if err != nil {
		return "", err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.rpcURL, bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("content-type", "application/json")
	resp, err := r.http.Do(req)
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
			Code    int             `json:"code"`
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if payload.Error != nil {
		// Execution reverted (code 3, or a message saying so): the chain answered. Anything else is the transport's.
		if payload.Error.Code == 3 || strings.Contains(strings.ToLower(payload.Error.Message), "revert") {
			return "", &revertError{message: fmt.Sprintf("eth_call %s reverted: %s", data[:10], payload.Error.Message)}
		}
		return "", fmt.Errorf("eth_call %s: %s", data[:10], payload.Error.Message)
	}
	result := strings.ToLower(strings.TrimSpace(payload.Result))
	if result == "" || result == "0x" {
		return "", fmt.Errorf("eth_call %s: empty result", data[:10])
	}
	return result, nil
}

func word(raw string, index int) (*big.Int, error) {
	hexed := strings.TrimPrefix(raw, "0x")
	start, end := index*64, (index+1)*64
	if len(hexed) < end {
		return nil, fmt.Errorf("result too short for word %d", index)
	}
	value, ok := new(big.Int).SetString(hexed[start:end], 16)
	if !ok {
		return nil, fmt.Errorf("word %d is not hex", index)
	}
	return value, nil
}

var two256 = new(big.Int).Lsh(big.NewInt(1), 256)
var two255 = new(big.Int).Lsh(big.NewInt(1), 255)

func signed(value *big.Int) *big.Int {
	if value.Cmp(two255) >= 0 {
		return new(big.Int).Sub(value, two256)
	}
	return value
}

func uintWord(value *big.Int) string {
	return fmt.Sprintf("%064x", value)
}

// intWord is a signed int256 in two's complement.
func intWord(value *big.Int) string {
	if value.Sign() >= 0 {
		return uintWord(value)
	}
	return uintWord(new(big.Int).Add(two256, value))
}

func addressWord(address string) string {
	return strings.Repeat("0", 24) + strings.TrimPrefix(strings.ToLower(strings.TrimSpace(address)), "0x")
}
