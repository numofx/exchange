// Package futures reads a FutureAsset series' state from the chain and applies the fill band it
// enforces, so the venue refuses an order or a fill exactly where the chain would revert one.
//
// The band is FutureAsset._checkFillInsideIndexBand: a fill at price p is refused when
// |p - index| * 1e18 > index * markIndexBand(expiry), where index = 1e36 / indexFeed.getSpot() is the
// index in cNGN per USDC (the feed is USDC per cNGN). A band of zero, or no index feed, is no check.
// The order API and the matcher both use this package, so the band an order is admitted against is
// the band its fill is checked against.
package futures

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
)

const (
	sigIndexFeed          = "0x198cae76" // indexFeed()
	sigGetSpot            = "0x2b37269c" // getSpot()
	sigMarkIndexBand      = "0x968564c5" // markIndexBand(uint64)
	sigFutureContracts    = "0xc3c74b34" // futureContracts(uint256)
	sigContractSize       = "0x3d7cc610" // contractSize()
	sigIsDatedFutureAsset = "0x761822ef" // isDatedFutureAsset(address)
	sigTotalPositionCap   = "0x745ab570" // totalPositionCap(address)
	sigAdjustmentsPaused  = "0xac06ba05" // adjustmentsPaused()
	sigSubAccounts        = "0x779e5012" // subAccounts()
	sigManager            = "0x52981457" // SubAccounts.manager(uint256)

	// errDataTooOld is the index feed's revert when its last update is older than its heartbeat. Every
	// path that reads the index reverts with it, so fills do too: the band is unknowable, not wide.
	errDataTooOld = "0x1141796d" // BLF_DataTooOld()
)

var (
	one18 = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	one36 = new(big.Int).Exp(big.NewInt(10), big.NewInt(36), nil)

	// ErrIndexStale is a band that cannot be read because the index feed is stale. The chain refuses
	// every fill then, so the venue does too.
	ErrIndexStale = errors.New("the future's index feed is stale (BLF_DataTooOld): no fill can settle until it updates")
)

// Band is the fill band at one moment: the index and the band's half-width, both 18dp.
type Band struct {
	Index  *big.Int // cNGN per USDC, 1e36 / getSpot(), as FutureAsset computes it
	Width  *big.Int // markIndexBand(expiry): 0.10e18 is the index -/+ 10%
	ReadAt time.Time
}

// Allows is FutureAsset's own test, in the same integer arithmetic: true when a fill at price would
// not revert FA_FillOutsideIndexBand. A zero width is no check on chain, and so none here.
func (b Band) Allows(price *big.Int) bool {
	if b.Width.Sign() == 0 {
		return true
	}
	diff := new(big.Int).Sub(price, b.Index)
	diff.Abs(diff)
	return new(big.Int).Mul(diff, one18).Cmp(new(big.Int).Mul(b.Index, b.Width)) <= 0
}

// Low and High are the band's edges, 18dp cNGN per USDC. Informational: Allows is the test.
func (b Band) Low() *big.Int {
	return new(big.Int).Div(new(big.Int).Mul(b.Index, new(big.Int).Sub(one18, b.Width)), one18)
}

func (b Band) High() *big.Int {
	return new(big.Int).Div(new(big.Int).Mul(b.Index, new(big.Int).Add(one18, b.Width)), one18)
}

// Contract is FutureAsset.futureContracts(subId).
type Contract struct {
	Listed        bool
	Settled       bool
	Expiry        int64
	LastTradeTime int64
	MarkPrice     *big.Int
}

// Reader reads one series. Band is cached for bandTTL, the series and the trading switches for
// stateTTL; the index feed and the contract size are immutable and read once.
type Reader struct {
	rpcURL   string
	future   string
	expiry   int64
	bandTTL  time.Duration
	stateTTL time.Duration
	http     *http.Client
	now      func() time.Time

	mu           sync.Mutex
	feed         string
	subAccounts  string
	imRate       *big.Int
	imRateAt     time.Time
	contractSize *big.Int
	band         *Band
	contract     *Contract
	contractAt   time.Time
	open         *openState
}

type openState struct {
	at     time.Time
	open   bool
	reason string
}

func NewReader(rpcURL, future string, expiry int64, bandTTL, stateTTL time.Duration) *Reader {
	return &Reader{
		rpcURL:   strings.TrimSpace(rpcURL),
		future:   strings.ToLower(strings.TrimSpace(future)),
		expiry:   expiry,
		bandTTL:  bandTTL,
		stateTTL: stateTTL,
		http:     &http.Client{Timeout: 5 * time.Second},
		now:      time.Now,
	}
}

// Band is the band now. ErrIndexStale when the feed is stale; any other error is a read failure. Both
// mean no fill can be checked, and callers refuse.
func (r *Reader) Band(ctx context.Context) (Band, error) {
	r.mu.Lock()
	if r.band != nil && r.now().Sub(r.band.ReadAt) < r.bandTTL {
		band := *r.band
		r.mu.Unlock()
		return band, nil
	}
	r.mu.Unlock()

	feed, err := r.indexFeed(ctx)
	if err != nil {
		return Band{}, err
	}
	spotWord, err := r.call(ctx, feed, sigGetSpot)
	if err != nil {
		return Band{}, err
	}
	spot, err := word(spotWord, 0)
	if err != nil {
		return Band{}, fmt.Errorf("getSpot: %w", err)
	}
	if spot.Sign() == 0 {
		return Band{}, errors.New("getSpot returned zero")
	}
	widthWord, err := r.call(ctx, r.future, sigMarkIndexBand+uintWord(big.NewInt(r.expiry)))
	if err != nil {
		return Band{}, err
	}
	width, err := word(widthWord, 0)
	if err != nil {
		return Band{}, fmt.Errorf("markIndexBand: %w", err)
	}
	band := Band{Index: new(big.Int).Div(one36, spot), Width: width, ReadAt: r.now()}
	r.mu.Lock()
	r.band = &band
	r.mu.Unlock()
	return band, nil
}

// Contract is the series as the chain has it.
func (r *Reader) Contract(ctx context.Context) (Contract, error) {
	r.mu.Lock()
	if r.contract != nil && r.now().Sub(r.contractAt) < r.stateTTL {
		contract := *r.contract
		r.mu.Unlock()
		return contract, nil
	}
	r.mu.Unlock()

	raw, err := r.call(ctx, r.future, sigFutureContracts+uintWord(big.NewInt(r.expiry)))
	if err != nil {
		return Contract{}, err
	}
	words := make([]*big.Int, 6)
	for i := range words {
		if words[i], err = word(raw, i); err != nil {
			return Contract{}, fmt.Errorf("futureContracts: %w", err)
		}
	}
	contract := Contract{
		Listed:        words[0].Sign() != 0,
		Settled:       words[1].Sign() != 0,
		Expiry:        words[2].Int64(),
		LastTradeTime: words[3].Int64(),
		MarkPrice:     words[5],
	}
	r.mu.Lock()
	r.contract = &contract
	r.contractAt = r.now()
	r.mu.Unlock()
	return contract, nil
}

// ContractSize is FutureAsset.contractSize(), 18dp USDC per contract.
func (r *Reader) ContractSize(ctx context.Context) (*big.Int, error) {
	r.mu.Lock()
	if r.contractSize != nil {
		size := new(big.Int).Set(r.contractSize)
		r.mu.Unlock()
		return size, nil
	}
	r.mu.Unlock()
	raw, err := r.call(ctx, r.future, sigContractSize)
	if err != nil {
		return nil, err
	}
	size, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("contractSize: %w", err)
	}
	r.mu.Lock()
	r.contractSize = size
	r.mu.Unlock()
	return new(big.Int).Set(size), nil
}

// TradingOpen reports whether a fill can settle now, and if not, why. Every condition is one the
// chain would revert a fill on, or one that would settle it wrongly:
//   - the series is listed, not settled, and before its last trade time (FA_TradingClosed after);
//   - the TradeModule treats the asset as a dated future (until the enable batch does, a fill takes
//     its spot branch and moves price x amount as a quote leg);
//   - the manager has a position cap on the asset (zero until enable: every fill would breach it);
//   - the manager is not paused.
func (r *Reader) TradingOpen(ctx context.Context, tradeModule, manager string) (bool, string, error) {
	r.mu.Lock()
	if r.open != nil && r.now().Sub(r.open.at) < r.stateTTL {
		state := *r.open
		r.mu.Unlock()
		return state.open, state.reason, nil
	}
	r.mu.Unlock()

	open, reason, err := r.readOpen(ctx, tradeModule, manager)
	if err != nil {
		return false, "", err
	}
	r.mu.Lock()
	r.open = &openState{at: r.now(), open: open, reason: reason}
	r.mu.Unlock()
	return open, reason, nil
}

func (r *Reader) readOpen(ctx context.Context, tradeModule, manager string) (bool, string, error) {
	contract, err := r.Contract(ctx)
	if err != nil {
		return false, "", err
	}
	switch {
	case !contract.Listed:
		return false, "the series is not listed on its FutureAsset", nil
	case contract.Settled:
		return false, "the series has settled", nil
	case r.now().Unix() >= contract.LastTradeTime:
		return false, "the series is past its last trade time", nil
	}
	dated, err := r.boolCall(ctx, tradeModule, sigIsDatedFutureAsset+addressWord(r.future))
	if err != nil {
		return false, "", err
	}
	if !dated {
		return false, "the TradeModule does not yet treat the asset as a dated future (the enable batch has not landed)", nil
	}
	capRaw, err := r.call(ctx, r.future, sigTotalPositionCap+addressWord(manager))
	if err != nil {
		return false, "", err
	}
	positionCap, err := word(capRaw, 0)
	if err != nil {
		return false, "", fmt.Errorf("totalPositionCap: %w", err)
	}
	if positionCap.Sign() == 0 {
		return false, "the manager has no position cap on the future (the enable batch has not landed)", nil
	}
	paused, err := r.boolCall(ctx, manager, sigAdjustmentsPaused)
	if err != nil {
		return false, "", err
	}
	if paused {
		return false, "the manager is paused", nil
	}
	return true, "", nil
}

// ManagerOf is SubAccounts.manager(account), lowercased: the future admits a position only under a
// manager it whitelists (MW_UnknownManager otherwise). Not cached: an account can migrate.
func (r *Reader) ManagerOf(ctx context.Context, account *big.Int) (string, error) {
	ledger, err := r.ledger(ctx)
	if err != nil {
		return "", err
	}
	raw, err := r.call(ctx, ledger, sigManager+uintWord(account))
	if err != nil {
		return "", err
	}
	if len(raw) < 2+64 {
		return "", errors.New("manager: short result")
	}
	return "0x" + raw[len(raw)-40:], nil
}

// ledger is the future's SubAccounts, read once.
func (r *Reader) ledger(ctx context.Context) (string, error) {
	r.mu.Lock()
	ledger := r.subAccounts
	r.mu.Unlock()
	if ledger != "" {
		return ledger, nil
	}
	raw, err := r.call(ctx, r.future, sigSubAccounts)
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

func (r *Reader) indexFeed(ctx context.Context) (string, error) {
	r.mu.Lock()
	if r.feed != "" {
		feed := r.feed
		r.mu.Unlock()
		return feed, nil
	}
	r.mu.Unlock()
	raw, err := r.call(ctx, r.future, sigIndexFeed)
	if err != nil {
		return "", err
	}
	if len(raw) < 2+64 {
		return "", errors.New("indexFeed: short result")
	}
	feed := "0x" + raw[len(raw)-40:]
	if strings.Trim(feed[2:], "0") == "" {
		return "", errors.New("the future has no index feed")
	}
	r.mu.Lock()
	r.feed = feed
	r.mu.Unlock()
	return feed, nil
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

// call is one eth_call. A revert carrying BLF_DataTooOld is ErrIndexStale.
func (r *Reader) call(ctx context.Context, to, data string) (string, error) {
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "eth_call",
		"params":  []any{map[string]string{"to": to, "data": data}, "latest"},
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
			Message string          `json:"message"`
			Data    json.RawMessage `json:"data"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return "", err
	}
	if payload.Error != nil {
		if strings.Contains(strings.ToLower(string(payload.Error.Data)), errDataTooOld) ||
			strings.Contains(strings.ToLower(payload.Error.Message), errDataTooOld) ||
			strings.Contains(payload.Error.Message, "BLF_DataTooOld") {
			return "", ErrIndexStale
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

func uintWord(value *big.Int) string {
	return fmt.Sprintf("%064x", value)
}

func addressWord(address string) string {
	return strings.Repeat("0", 24) + strings.TrimPrefix(strings.ToLower(strings.TrimSpace(address)), "0x")
}

// Decimal renders an 18dp fixed-point value as a decimal string: 1400123400000000000000 -> "1400.1234".
func Decimal(value *big.Int) string {
	sign := ""
	v := new(big.Int).Set(value)
	if v.Sign() < 0 {
		sign = "-"
		v.Abs(v)
	}
	whole, frac := new(big.Int).QuoRem(v, one18, new(big.Int))
	if frac.Sign() == 0 {
		return sign + whole.String()
	}
	digits := frac.String()
	digits = strings.Repeat("0", 18-len(digits)) + digits
	return sign + whole.String() + "." + strings.TrimRight(digits, "0")
}
