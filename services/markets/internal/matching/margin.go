package matching

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/hedge"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// The perp's pre-trade check. It replaces buyerCanFund for perpetual markets, which would be wrong
// twice over: a perp fill costs margin, not notional, so requiring the buyer to hold the full
// notional rejects every leveraged order; and it checks only the buyer, while a perp short takes as
// much risk as a long.
//
// Both sides are checked the way the perp SRM will judge them after the fill:
//
//	surplus_after = IM surplus now                    (SRM.getMargin(account, true))
//	              + price-vs-mark cash leg            (TradeModule moves (fill - mark) x amount)
//	              - taker fee                         (taker only; makers pay none on this venue)
//	              - initial margin the fill ADDS      (|new position| - |old position|) x mark x imReq
//
// An order that only reduces a position is always allowed: that is how an account under margin gets
// out, and the SRM itself lets risk-reducing trades through.
//
// Like the funding check this is not the safety boundary -- the SRM is, on chain -- and it fails open
// on an RPC error so an outage degrades to the chain's own enforcement rather than halting the book.
// It is conservative where it approximates: it ignores any offset a new position could have against
// other holdings, of which a perp-only account has none.

const (
	getMarginSelector              = "0x623bb445" // getMargin(uint256,bool)
	getPerpPriceSelector           = "0x90f76b18" // getPerpPrice()
	assetDetailsSelector           = "0xd21415a3" // assetDetails(address)
	perpMarginRequirementsSelector = "0xbf270f9d" // perpMarginRequirements(uint256)
)

// perpSide is one account's view of a prospective fill, in engine units (18dp).
type perpSide struct {
	// ImSurplus is SRM.getMargin(account, true): positive means headroom above initial margin.
	ImSurplus *big.Int
	// Position is the account's current perp balance, signed, in NGN.
	Position *big.Int
	// Delta is what the fill adds: +amount for the engine buyer, -amount for the seller.
	Delta *big.Int
	// Fee is charged to the taker only.
	Fee *big.Int
}

// perpFillCheck is the arithmetic, kept pure so every case is testable without a chain.
// fillPrice and mark are USDC per cNGN at 18dp; imReq is 18dp (0.33333e18 = 33.333%).
func perpFillCheck(side perpSide, fillPrice, mark, imReq *big.Int) (ok bool, surplusAfter *big.Int) {
	newPosition := new(big.Int).Add(side.Position, side.Delta)
	if reducesOnly(side.Position, newPosition) {
		return true, nil
	}

	surplusAfter = new(big.Int).Set(side.ImSurplus)

	// TradeModule moves (fill - mark) x amount: the buyer pays it when the fill is above the mark.
	priceLeg := new(big.Int).Sub(fillPrice, mark)
	priceLeg.Mul(priceLeg, side.Delta)
	priceLeg.Quo(priceLeg, quoteScale)
	surplusAfter.Sub(surplusAfter, priceLeg)

	surplusAfter.Sub(surplusAfter, side.Fee)

	added := new(big.Int).Sub(new(big.Int).Abs(newPosition), new(big.Int).Abs(side.Position))
	if added.Sign() > 0 {
		addedIM := new(big.Int).Mul(added, mark)
		addedIM.Quo(addedIM, quoteScale)
		addedIM.Mul(addedIM, imReq)
		addedIM.Quo(addedIM, quoteScale)
		surplusAfter.Sub(surplusAfter, addedIM)
	}

	return surplusAfter.Sign() >= 0, surplusAfter
}

// reducesOnly reports whether moving from `before` to `after` only shrinks the position toward zero
// without flipping it.
func reducesOnly(before, after *big.Int) bool {
	if new(big.Int).Abs(after).Cmp(new(big.Int).Abs(before)) > 0 {
		return false
	}
	return after.Sign() == 0 || after.Sign() == before.Sign()
}

// marginChecker judges a prospective perp fill for both sides.
type marginChecker interface {
	CheckPerpFill(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillPrice, fillAmount, takerFee string) (marginVerdict, error)
}

type marginVerdict struct {
	OK bool
	// Account is the subaccount that would fail, and SurplusAfter its projected IM surplus.
	Account      string
	SurplusAfter *big.Int
	// Reason is set when the fill fails the venue's cNGN rule rather than margin (internal/hedge).
	Reason string
}

type chainMarginChecker struct {
	rpc *chainFundingChecker // eth_call and the SubAccounts address, shared with the funding check

	mu        sync.Mutex
	imReq     map[string]cachedBalance // keyed by perp asset
	imReqTTL  time.Duration
	markCache map[string]cachedBalance
	markTTL   time.Duration
	now       func() time.Time
}

// newMarginChecker returns nil when there is no chain to read or no perp configured; a nil checker
// lets every perp fill through to the chain's own enforcement, and says so once at start.
func newMarginChecker(cfg config.Config) marginChecker {
	if !cfg.PerpEnabled() {
		return nil
	}
	if strings.TrimSpace(cfg.ChainRPCURL) == "" || !isHexAddress(cfg.MatchingAddress) {
		slog.Warn("perp_margin_check_inert", "reason", "CHAIN_RPC_URL or MATCHING_ADDRESS is unset",
			"effect", "perp fills are only margin-checked on chain, after crossing")
		return nil
	}
	slog.Info("perp_margin_check_enabled", "srm", cfg.CNGNPerpSRMAddress, "perp", cfg.CNGNPerpAssetAddress)
	return &chainMarginChecker{
		rpc: &chainFundingChecker{
			rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
			matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
			httpClient:      &http.Client{Timeout: 5 * time.Second},
			ttl:             2 * time.Second,
			now:             time.Now,
			cache:           map[string]cachedBalance{},
		},
		imReq:     map[string]cachedBalance{},
		imReqTTL:  time.Minute,
		markCache: map[string]cachedBalance{},
		markTTL:   2 * time.Second,
		now:       time.Now,
	}
}

func (c *chainMarginChecker) CheckPerpFill(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillPrice, fillAmount, takerFee string) (marginVerdict, error) {
	srm := strings.ToLower(strings.TrimSpace(instrument.MarginManagerAddress))
	perp := strings.ToLower(strings.TrimSpace(instrument.AssetAddress))
	if !isHexAddress(srm) || !isHexAddress(perp) {
		return marginVerdict{}, errors.New("perp market has no margin manager or asset configured")
	}

	price, err := parsePositiveInt(fillPrice, "fill_price")
	if err != nil {
		return marginVerdict{}, err
	}
	amount, err := parsePositiveInt(fillAmount, "fill_amount")
	if err != nil {
		return marginVerdict{}, err
	}
	fee, err := parseNonNegativeInt(takerFee, "taker_fee")
	if err != nil {
		return marginVerdict{}, err
	}

	mark, err := c.mark(ctx, perp)
	if err != nil {
		return marginVerdict{}, fmt.Errorf("read mark: %w", err)
	}
	imReq, err := c.initialMarginRate(ctx, srm, perp)
	if err != nil {
		return marginVerdict{}, fmt.Errorf("read initial margin rate: %w", err)
	}

	for _, leg := range []struct {
		order   orders.Order
		isTaker bool
	}{{candidate.Taker, true}, {candidate.Maker, false}} {
		surplus, err := c.imSurplus(ctx, srm, leg.order.SubaccountID)
		if err != nil {
			return marginVerdict{}, fmt.Errorf("read margin of %s: %w", leg.order.SubaccountID, err)
		}
		position, err := c.position(ctx, perp, leg.order.SubaccountID)
		if err != nil {
			return marginVerdict{}, fmt.Errorf("read position of %s: %w", leg.order.SubaccountID, err)
		}
		delta := new(big.Int).Set(amount)
		if leg.order.Side == orders.SideSell {
			delta.Neg(delta)
		}
		sideFee := big.NewInt(0)
		if leg.isTaker {
			sideFee = fee
		}
		ok, surplusAfter := perpFillCheck(perpSide{ImSurplus: surplus, Position: position, Delta: delta, Fee: sideFee}, price, mark, imReq)
		if !ok {
			return marginVerdict{OK: false, Account: leg.order.SubaccountID, SurplusAfter: surplusAfter}, nil
		}
		// The venue's rule for cNGN-margined accounts, re-checked at the fill the order was
		// submitted under may have been followed by others.
		if escrow := strings.ToLower(strings.TrimSpace(instrument.CollateralAssetAddress)); escrow != "" {
			cngn, err := c.position(ctx, escrow, leg.order.SubaccountID)
			if err != nil {
				return marginVerdict{}, fmt.Errorf("read cNGN collateral of %s: %w", leg.order.SubaccountID, err)
			}
			if err := hedge.Check(cngn, position, delta, nil); err != nil {
				return marginVerdict{OK: false, Account: leg.order.SubaccountID, Reason: err.Error()}, nil
			}
		}
	}
	return marginVerdict{OK: true}, nil
}

func (c *chainMarginChecker) imSurplus(ctx context.Context, srm, subaccountID string) (*big.Int, error) {
	account, err := encodeUint256Word(subaccountID)
	if err != nil {
		return nil, err
	}
	raw, err := c.rpc.ethCall(ctx, srm, getMarginSelector+account+fmt.Sprintf("%064x", 1))
	if err != nil {
		return nil, err
	}
	return decodeInt256(raw)
}

func (c *chainMarginChecker) position(ctx context.Context, perp, subaccountID string) (*big.Int, error) {
	subAccounts, err := c.rpc.subAccountsAddress(ctx)
	if err != nil {
		return nil, err
	}
	account, err := encodeUint256Word(subaccountID)
	if err != nil {
		return nil, err
	}
	raw, err := c.rpc.ethCall(ctx, subAccounts, getBalanceSelector+account+encodeAddressArg(perp)+strings.Repeat("0", 64))
	if err != nil {
		return nil, err
	}
	return decodeInt256(raw)
}

func (c *chainMarginChecker) mark(ctx context.Context, perp string) (*big.Int, error) {
	if value, ok := c.cachedValue(c.markCache, perp, c.markTTL); ok {
		return value, nil
	}
	raw, err := c.rpc.ethCall(ctx, perp, getPerpPriceSelector)
	if err != nil {
		return nil, err
	}
	mark, err := wordAt(raw, 0)
	if err != nil {
		return nil, err
	}
	c.storeValue(c.markCache, perp, mark)
	return mark, nil
}

// initialMarginRate reads imPerpReq for the perp's market on its SRM: assetDetails(perp) gives the
// market id, perpMarginRequirements(marketId) gives (mm, im).
func (c *chainMarginChecker) initialMarginRate(ctx context.Context, srm, perp string) (*big.Int, error) {
	if value, ok := c.cachedValue(c.imReq, perp, c.imReqTTL); ok {
		return value, nil
	}
	details, err := c.rpc.ethCall(ctx, srm, assetDetailsSelector+encodeAddressArg(perp))
	if err != nil {
		return nil, err
	}
	marketID, err := wordAt(details, 2)
	if err != nil {
		return nil, err
	}
	reqs, err := c.rpc.ethCall(ctx, srm, perpMarginRequirementsSelector+fmt.Sprintf("%064x", marketID))
	if err != nil {
		return nil, err
	}
	im, err := wordAt(reqs, 1)
	if err != nil {
		return nil, err
	}
	if im.Sign() <= 0 {
		return nil, errors.New("perp market has no initial margin requirement")
	}
	c.storeValue(c.imReq, perp, im)
	return im, nil
}

func (c *chainMarginChecker) cachedValue(cache map[string]cachedBalance, key string, ttl time.Duration) (*big.Int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	entry, ok := cache[key]
	if !ok || c.now().Sub(entry.at) > ttl {
		return nil, false
	}
	return new(big.Int).Set(entry.value), true
}

func (c *chainMarginChecker) storeValue(cache map[string]cachedBalance, key string, value *big.Int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	cache[key] = cachedBalance{value: new(big.Int).Set(value), at: c.now()}
}

// wordAt reads the index-th 32-byte word of an ABI-encoded return as an unsigned integer.
func wordAt(raw string, index int) (*big.Int, error) {
	cleaned := strings.TrimPrefix(strings.TrimSpace(strings.ToLower(raw)), "0x")
	start := index * 64
	if len(cleaned) < start+64 {
		return nil, fmt.Errorf("return data too short for word %d: %q", index, raw)
	}
	value, ok := new(big.Int).SetString(cleaned[start:start+64], 16)
	if !ok {
		return nil, fmt.Errorf("invalid word %d in %q", index, raw)
	}
	return value, nil
}

// perpTradingGate reports whether the perp is open on chain: its module allowlisted on Matching AND
// its OI cap above zero. Both are the final enable action's; until it runs, the matcher does not
// cross perp orders, which could only settle into a revert (module) or a cap breach (cap).
//
// Unlike the pre-trade checks this fails CLOSED: not knowing whether the market is open is not a
// reason to cross orders into it. Cached briefly so it costs two reads per interval, not per tick.
type perpTradingGate struct {
	rpc      *chainFundingChecker
	matching string
	module   string
	perp     string
	srm      string

	mu      sync.Mutex
	open    bool
	checked time.Time
	ttl     time.Duration
	now     func() time.Time
}

func newPerpTradingGate(cfg config.Config) *perpTradingGate {
	if !cfg.PerpEnabled() || strings.TrimSpace(cfg.ChainRPCURL) == "" {
		return nil
	}
	return &perpTradingGate{
		rpc:      &chainFundingChecker{rpcURL: strings.TrimSpace(cfg.ChainRPCURL), httpClient: &http.Client{Timeout: 5 * time.Second}},
		matching: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
		module:   strings.ToLower(strings.TrimSpace(cfg.CNGNPerpTradeModuleAddress)),
		perp:     strings.ToLower(strings.TrimSpace(cfg.CNGNPerpAssetAddress)),
		srm:      strings.ToLower(strings.TrimSpace(cfg.CNGNPerpSRMAddress)),
		ttl:      30 * time.Second,
		now:      time.Now,
	}
}

// Open reports the cached verdict, refreshing it when stale. An unreadable chain reads as closed.
func (g *perpTradingGate) Open(ctx context.Context) bool {
	g.mu.Lock()
	if !g.checked.IsZero() && g.now().Sub(g.checked) < g.ttl {
		open := g.open
		g.mu.Unlock()
		return open
	}
	g.mu.Unlock()

	open, err := g.read(ctx)
	if err != nil {
		slog.Warn("perp_trading_gate_unreadable", "error", err.Error(), "effect", "perp treated as closed")
		open = false
	}
	g.mu.Lock()
	if open != g.open || g.checked.IsZero() {
		slog.Info("perp_trading_gate", "open", open)
	}
	g.open, g.checked = open, g.now()
	g.mu.Unlock()
	return open
}

func (g *perpTradingGate) read(ctx context.Context) (bool, error) {
	allowedRaw, err := g.rpc.ethCall(ctx, g.matching, allowedModulesSelector+encodeAddressArg(g.module))
	if err != nil {
		return false, fmt.Errorf("allowedModules: %w", err)
	}
	allowed, err := wordAt(allowedRaw, 0)
	if err != nil {
		return false, err
	}
	capRaw, err := g.rpc.ethCall(ctx, g.perp, totalPositionCapSelector+encodeAddressArg(g.srm))
	if err != nil {
		return false, fmt.Errorf("totalPositionCap: %w", err)
	}
	positionCap, err := wordAt(capRaw, 0)
	if err != nil {
		return false, err
	}
	pausedRaw, err := g.rpc.ethCall(ctx, g.srm, adjustmentsPausedSelector)
	if err != nil {
		return false, fmt.Errorf("adjustmentsPaused: %w", err)
	}
	paused, err := wordAt(pausedRaw, 0)
	if err != nil {
		return false, err
	}
	// A guardian pause reverts every settlement; crossing orders into it would only queue
	// failures for the executor to retry.
	return allowed.Sign() > 0 && positionCap.Sign() > 0 && paused.Sign() == 0, nil
}

const (
	allowedModulesSelector    = "0x8ba5a0c2" // Matching.allowedModules(address)
	totalPositionCapSelector  = "0x745ab570" // PerpAsset.totalPositionCap(address)
	adjustmentsPausedSelector = "0xac06ba05" // BaseManager.adjustmentsPaused()
)
