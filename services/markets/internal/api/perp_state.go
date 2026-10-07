package api

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
	"github.com/numofx/matching-backend/internal/instruments"
)

// USDCcNGN-PERP's live state, read from its own stack on chain: mark, index, funding, open interest
// and margin rates for /v1/markets, and per-account positions for /v1/positions.
//
// The UI orientation is the engine's own: prices in USDC per cNGN, sizes in cNGN, and a UI long is
// the on-chain long of the cNGN perp. The *_ui fields are the chain's figures at the UI's scales,
// nothing inverted. ui_long_funding_rate_1h is the chain's rate as it is: positive means the UI long
// (long cNGN) pays.

const (
	sigGetIndexPrice          = "0x58c0994a" // getIndexPrice()
	sigGetPerpPrice           = "0x90f76b18" // getPerpPrice()
	sigGetFundingRate         = "0x95196f7e" // getFundingRate()
	sigOpenInterest           = "0x88e53ec8" // openInterest(uint256)
	sigAssetDetails           = "0xd21415a3" // assetDetails(address)
	sigPerpMarginRequirements = "0xbf270f9d" // perpMarginRequirements(uint256)
	sigGetMargin              = "0x623bb445" // getMargin(uint256,bool)
	sigGetBalance             = "0x0806e640" // getBalance(uint256,address,uint256)
	sigUnrealizedCash         = "0x7a4c2c3a" // getUnsettledAndUnrealizedCash(uint256)
	sigAllowedModules         = "0x8ba5a0c2" // Matching.allowedModules(address)
	sigTotalPositionCap       = "0x745ab570" // PerpAsset.totalPositionCap(address)
	sigAdjustmentsPaused      = "0xac06ba05" // BaseManager.adjustmentsPaused(): the SRM guardian's pause
	sigBaseMarginParams       = "0xcd27955d" // StandardManager.baseMarginParams(uint256): (marginFactor, IMScale)
	sigTotalPosition          = "0xa9578774" // PositionTracking.totalPosition(address): cNGN held under the manager
	sigWhitelistedManager     = "0x97d51c04" // ManagerWhitelist.whitelistedManager(address): the escrow accepts the SRM

	perpStateTTL = 10 * time.Second
	perpUIScale  = 6
	// perpPriceScale is the UI's price scale: USDC per cNGN is ~0.00072, so six places would keep
	// two digits of it.
	perpPriceScale = spotUIPriceDecimalScale
	perpE18Scale   = 18
)

var perpE18 = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

type perpMarketState struct {
	MarkPrice              string `json:"mark_price"`
	IndexPrice             string `json:"index_price"`
	MarkPriceUI            string `json:"mark_price_ui"`
	IndexPriceUI           string `json:"index_price_ui"`
	FundingRate1h          string `json:"funding_rate_1h"`
	UILongFunding1h        string `json:"ui_long_funding_rate_1h"`
	FundingIntervalSeconds int64  `json:"funding_interval_seconds"`
	OpenInterest           string `json:"open_interest"`
	OpenInterestUSD        string `json:"open_interest_usd"`
	InitialMargin          string `json:"initial_margin_rate"`
	MaintenanceMargin      string `json:"maintenance_margin_rate"`
	MaxLeverage            string `json:"max_leverage"`
	TradeModule            string `json:"trade_module_address"`
	QuoteAsset             string `json:"quote_asset_address"`
	MarginManager          string `json:"margin_manager_address"`
	// TradingEnabled is the chain's own answer, read each refresh: the perp module allowlisted on
	// Matching, an OI cap above zero, and the SRM not paused. The first two are set only by the
	// final enable action; until then the market is listed so quotes can rest, but the matcher does
	// not cross it. Paused is the guardian's pause on the SRM: every adjustment on the perp's
	// accounts reverts while it holds (trades, deposits, withdrawals, liquidation bids), so the
	// market reads as not trading and the API refuses new perp orders rather than resting them.
	TradingEnabled bool   `json:"trading_enabled"`
	Paused         bool   `json:"paused"`
	PositionCap    string `json:"position_cap"`
	// CollateralAssets are the base assets the SRM credits as margin besides cash: today at most the
	// perp's cNGN escrow, with the haircut the SRM applies and the escrow's cap. Empty when margin is
	// cash only.
	CollateralAssets []perpCollateralAsset `json:"collateral_assets"`
	// IndexLag is the index-lag gate's view (nil without the gate): the publisher's latest spot
	// sample against the on-chain index, and whether new perp orders are being refused on it.
	IndexLag *indexLagPresentation `json:"index_lag,omitempty"`
	// enabledOnChain is the enable action's half of TradingEnabled (module allowed, cap above
	// zero), kept apart so a pause re-read over a cached state can recompute the whole.
	enabledOnChain bool
	UpdatedAt      int64 `json:"updated_at"`
}

// perpCollateralAsset is one base asset a perp account may post, as the SRM values it.
type perpCollateralAsset struct {
	Symbol       string `json:"symbol"`
	AssetAddress string `json:"asset_address"`
	// MarginFactor is the share of the asset's index value that counts as maintenance margin;
	// IMScale multiplies in again for initial margin. 18dp decimals.
	MarginFactor string `json:"margin_factor"`
	IMScale      string `json:"im_scale"`
	// Cap and Total are the escrow's collateral cap under the SRM and what is posted now, whole
	// units 18dp. A deposit that would cross the cap is refused on chain.
	Cap   string `json:"cap"`
	Total string `json:"total"`
	// DepositsOpen is the escrow's own switch (whitelistedManager(srm)): the SRM may credit the
	// asset before the escrow accepts deposits for it, and a deposit offered in between reverts. The
	// app offers the asset only while this is true.
	DepositsOpen bool `json:"deposits_open"`
}

// presentedCollateral is one collateral asset in an account: the balance, what it is worth at the
// index, and how much of that the SRM credits as initial margin.
type presentedCollateral struct {
	Symbol         string `json:"symbol"`
	AssetAddress   string `json:"asset_address"`
	Balance        string `json:"balance"`
	ValueUSD       string `json:"value_usd"`
	MarginValueUSD string `json:"margin_value_usd"`
}

type presentedPosition struct {
	Market       string `json:"market"`
	SubaccountID string `json:"subaccount_id"`
	// EnginePosition is the signed cNGN-perp balance (18dp). UISide is "long" when it is positive,
	// UISize its magnitude in cNGN, and UINotionalUSDC that size at the index, in USDC.
	EnginePosition string `json:"engine_position"`
	UISide         string `json:"ui_side"`
	UISize         string `json:"ui_size"`
	UINotionalUSDC string `json:"ui_notional_usdc"`
	MarkPriceUI    string `json:"mark_price_ui"`
	IndexPriceUI   string `json:"index_price_ui"`
	UnrealizedPnL  string `json:"unrealized_pnl"`
	// Margin surpluses as the SRM computes them: below zero means under that margin.
	InitialMarginSurplus     string `json:"initial_margin_surplus"`
	MaintenanceMarginSurplus string `json:"maintenance_margin_surplus"`
	// LiquidationPriceUI is where the account would fall below maintenance margin if nothing else
	// changed, in USDC per cNGN; empty when no price gets it there. An estimate, for a perp-only
	// account.
	LiquidationPriceUI string `json:"liquidation_price_ui,omitempty"`
}

// presentedPerpAccount is the account's margin on a perp stack, whether or not it holds a position:
// what the ticket shows as available before the first trade.
type presentedPerpAccount struct {
	Market                   string `json:"market"`
	SubaccountID             string `json:"subaccount_id"`
	Cash                     string `json:"cash"`
	InitialMarginSurplus     string `json:"initial_margin_surplus"`
	MaintenanceMarginSurplus string `json:"maintenance_margin_surplus"`
	// Collateral lists every base asset the account holds (empty when none, or margin is cash only).
	Collateral []presentedCollateral `json:"collateral"`
}

type perpStateReader struct {
	chain *chainCustodyChecker // eth_call and the SubAccounts address

	mu    sync.Mutex
	cache map[string]cachedPerpState
	now   func() time.Time
}

type cachedPerpState struct {
	state *perpMarketState
	raw   perpRaw
	at    time.Time
}

// perpRaw is the chain state behind a presentation, kept for the positions endpoint's arithmetic.
type perpRaw struct {
	mark, index, imReq, mmReq *big.Int
	// collateralFactor is the SRM's margin factor for the collateral asset (18dp); nil when none.
	collateralFactor *big.Int
}

func newPerpStateReader(cfg config.Config) *perpStateReader {
	if !cfg.PerpEnabled() || strings.TrimSpace(cfg.ChainRPCURL) == "" || !isHexAddress(cfg.MatchingAddress) {
		return nil
	}
	return &perpStateReader{
		chain: &chainCustodyChecker{
			rpcURL:          strings.TrimSpace(cfg.ChainRPCURL),
			matchingAddress: strings.ToLower(strings.TrimSpace(cfg.MatchingAddress)),
			httpClient:      &http.Client{Timeout: 5 * time.Second},
		},
		cache: map[string]cachedPerpState{},
		now:   time.Now,
	}
}

func (r *perpStateReader) marketState(ctx context.Context, market instruments.Metadata) (*perpMarketState, perpRaw, error) {
	key := strings.ToLower(market.AssetAddress)
	r.mu.Lock()
	cached, ok := r.cache[key]
	r.mu.Unlock()
	if ok && r.now().Sub(cached.at) < perpStateTTL {
		// The cached prices and margins are fine for ten seconds; the guardian's pause is not. It
		// flips with one transaction and the listing must say so at once, so it is re-read on every
		// hit and laid over a copy of the cached state when it differs.
		paused, err := r.paused(ctx, strings.ToLower(market.MarginManagerAddress))
		if err != nil {
			return nil, perpRaw{}, err
		}
		if paused == cached.state.Paused {
			return cached.state, cached.raw, nil
		}
		state := *cached.state
		state.Paused = paused
		state.TradingEnabled = cached.state.enabledOnChain && !paused
		r.mu.Lock()
		r.cache[key] = cachedPerpState{state: &state, raw: cached.raw, at: cached.at}
		r.mu.Unlock()
		return &state, cached.raw, nil
	}

	perp := strings.ToLower(market.AssetAddress)
	srm := strings.ToLower(market.MarginManagerAddress)

	index, err := r.word(ctx, perp, sigGetIndexPrice, 0)
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("index: %w", err)
	}
	mark, err := r.word(ctx, perp, sigGetPerpPrice, 0)
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("mark: %w", err)
	}
	fundingRaw, err := r.chain.ethCall(ctx, perp, sigGetFundingRate)
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("funding: %w", err)
	}
	funding, err := signedWord(fundingRaw, 0)
	if err != nil {
		return nil, perpRaw{}, err
	}
	oi, err := r.word(ctx, perp, sigOpenInterest+fmt.Sprintf("%064x", 0), 0)
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("open interest: %w", err)
	}
	marketID, err := r.word(ctx, srm, sigAssetDetails+addressArg(perp), 2)
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("market id: %w", err)
	}
	reqs, err := r.chain.ethCall(ctx, srm, sigPerpMarginRequirements+fmt.Sprintf("%064x", marketID))
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("margin requirements: %w", err)
	}
	mmReq, err := signedWord(reqs, 0)
	if err != nil {
		return nil, perpRaw{}, err
	}
	imReq, err := signedWord(reqs, 1)
	if err != nil {
		return nil, perpRaw{}, err
	}

	allowedRaw, err := r.chain.ethCall(ctx, r.chain.matchingAddress, sigAllowedModules+addressArg(market.TradeModuleAddress))
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("allowed modules: %w", err)
	}
	allowed, err := signedWord(allowedRaw, 0)
	if err != nil {
		return nil, perpRaw{}, err
	}
	positionCap, err := r.word(ctx, perp, sigTotalPositionCap+addressArg(srm), 0)
	if err != nil {
		return nil, perpRaw{}, fmt.Errorf("position cap: %w", err)
	}
	paused, err := r.paused(ctx, srm)
	if err != nil {
		return nil, perpRaw{}, err
	}
	collateral, collateralFactor, err := r.collateralAssets(ctx, market, srm, marketID)
	if err != nil {
		return nil, perpRaw{}, err
	}

	state := &perpMarketState{
		CollateralAssets:       collateral,
		TradingEnabled:         allowed.Sign() > 0 && positionCap.Sign() > 0 && !paused,
		Paused:                 paused,
		enabledOnChain:         allowed.Sign() > 0 && positionCap.Sign() > 0,
		PositionCap:            e18String(positionCap),
		MarkPrice:              e18String(mark),
		IndexPrice:             e18String(index),
		MarkPriceUI:            uiPriceString(mark),
		IndexPriceUI:           uiPriceString(index),
		FundingRate1h:          e18String(funding),
		UILongFunding1h:        e18String(funding),
		FundingIntervalSeconds: int64(market.FundingInterval / time.Second),
		OpenInterest:           e18String(oi),
		OpenInterestUSD:        formatDecimal(new(big.Rat).SetFrac(new(big.Int).Mul(oi, index), new(big.Int).Mul(perpE18, perpE18)), perpUIScale),
		InitialMargin:          e18String(imReq),
		MaintenanceMargin:      e18String(mmReq),
		TradeModule:            strings.ToLower(market.TradeModuleAddress),
		QuoteAsset:             strings.ToLower(market.QuoteAssetAddress),
		MarginManager:          srm,
		UpdatedAt:              r.now().Unix(),
	}
	if imReq.Sign() > 0 {
		state.MaxLeverage = formatDecimal(new(big.Rat).SetFrac(perpE18, imReq), 2)
	}
	raw := perpRaw{mark: mark, index: index, imReq: imReq, mmReq: mmReq, collateralFactor: collateralFactor}

	r.mu.Lock()
	r.cache[key] = cachedPerpState{state: state, raw: raw, at: r.now()}
	r.mu.Unlock()
	return state, raw, nil
}

// collateralAssets reads the perp's cNGN collateral as the SRM values it: the market's base margin
// factor and IM scale, and the escrow's cap and total under the SRM. Nothing when no escrow is
// configured. A configured escrow the SRM credits at 0 is reported as such: the app shows the asset
// with no margin value rather than hiding a deposit that would lock cNGN for nothing.
func (r *perpStateReader) collateralAssets(ctx context.Context, market instruments.Metadata, srm string, marketID *big.Int) ([]perpCollateralAsset, *big.Int, error) {
	escrow := strings.ToLower(market.CollateralAssetAddress)
	if escrow == "" {
		return []perpCollateralAsset{}, nil, nil
	}
	params, err := r.chain.ethCall(ctx, srm, sigBaseMarginParams+fmt.Sprintf("%064x", marketID))
	if err != nil {
		return nil, nil, fmt.Errorf("base margin params: %w", err)
	}
	factor, err := signedWord(params, 0)
	if err != nil {
		return nil, nil, err
	}
	imScale, err := signedWord(params, 1)
	if err != nil {
		return nil, nil, err
	}
	cap, err := r.word(ctx, escrow, sigTotalPositionCap+addressArg(srm), 0)
	if err != nil {
		return nil, nil, fmt.Errorf("collateral cap: %w", err)
	}
	total, err := r.word(ctx, escrow, sigTotalPosition+addressArg(srm), 0)
	if err != nil {
		return nil, nil, fmt.Errorf("collateral total: %w", err)
	}
	open, err := r.word(ctx, escrow, sigWhitelistedManager+addressArg(srm), 0)
	if err != nil {
		return nil, nil, fmt.Errorf("collateral deposits open: %w", err)
	}
	return []perpCollateralAsset{{
		Symbol:       "cNGN",
		AssetAddress: escrow,
		MarginFactor: e18String(factor),
		IMScale:      e18String(imScale),
		Cap:          e18String(cap),
		Total:        e18String(total),
		DepositsOpen: open.Sign() > 0,
	}}, factor, nil
}

// paused reads the SRM guardian's pause flag, uncached: it is the one input that changes by a
// single transaction and must be answered as it is, both on the market listing and when an order
// arrives.
func (r *perpStateReader) paused(ctx context.Context, srm string) (bool, error) {
	raw, err := r.word(ctx, srm, sigAdjustmentsPaused, 0)
	if err != nil {
		return false, fmt.Errorf("adjustments paused: %w", err)
	}
	return raw.Sign() > 0, nil
}

// Paused reports whether the perp market's SRM is paused right now, for the order handler.
func (r *perpStateReader) Paused(ctx context.Context, market instruments.Metadata) (bool, error) {
	return r.paused(ctx, strings.ToLower(market.MarginManagerAddress))
}

// account reads the subaccount's cash and margin on the perp's stack. Surpluses are the SRM's own:
// for an account with no position the initial surplus is its cash.
func (r *perpStateReader) account(ctx context.Context, market instruments.Metadata, subaccountID string) (*presentedPerpAccount, error) {
	account, err := encodeUint256(subaccountID)
	if err != nil {
		return nil, err
	}
	srm := strings.ToLower(market.MarginManagerAddress)
	subAccounts, err := r.chain.subAccountsAddress(ctx)
	if err != nil {
		return nil, err
	}
	cashRaw, err := r.chain.ethCall(ctx, subAccounts, sigGetBalance+account+addressArg(market.QuoteAssetAddress)+strings.Repeat("0", 64))
	if err != nil {
		return nil, fmt.Errorf("cash: %w", err)
	}
	cash, err := signedWord(cashRaw, 0)
	if err != nil {
		return nil, err
	}
	imRaw, err := r.chain.ethCall(ctx, srm, sigGetMargin+account+fmt.Sprintf("%064x", 1))
	if err != nil {
		return nil, fmt.Errorf("initial margin: %w", err)
	}
	im, err := signedWord(imRaw, 0)
	if err != nil {
		return nil, err
	}
	mmRaw, err := r.chain.ethCall(ctx, srm, sigGetMargin+account+fmt.Sprintf("%064x", 0))
	if err != nil {
		return nil, fmt.Errorf("maintenance margin: %w", err)
	}
	mm, err := signedWord(mmRaw, 0)
	if err != nil {
		return nil, err
	}
	collateral, err := r.collateral(ctx, market, subAccounts, account)
	if err != nil {
		return nil, err
	}
	return &presentedPerpAccount{
		Market:                   market.Symbol,
		SubaccountID:             subaccountID,
		Cash:                     e18String(cash),
		InitialMarginSurplus:     e18String(im),
		MaintenanceMarginSurplus: e18String(mm),
		Collateral:               collateral,
	}, nil
}

// collateral reads the account's cNGN in the perp's escrow and values it at the index: the whole
// value, and the share the SRM credits as margin. Empty when none is configured or none is held.
func (r *perpStateReader) collateral(ctx context.Context, market instruments.Metadata, subAccounts, account string) ([]presentedCollateral, error) {
	escrow := strings.ToLower(market.CollateralAssetAddress)
	if escrow == "" {
		return []presentedCollateral{}, nil
	}
	balance, err := r.word(ctx, subAccounts, sigGetBalance+account+addressArg(escrow)+strings.Repeat("0", 64), 0)
	if err != nil {
		return nil, fmt.Errorf("collateral balance: %w", err)
	}
	if balance.Sign() <= 0 {
		return []presentedCollateral{}, nil
	}
	_, raw, err := r.marketState(ctx, market)
	if err != nil {
		return nil, err
	}
	value := new(big.Int).Div(new(big.Int).Mul(balance, raw.index), perpE18)
	marginValue := big.NewInt(0)
	if raw.collateralFactor != nil {
		marginValue = new(big.Int).Div(new(big.Int).Mul(value, raw.collateralFactor), perpE18)
	}
	return []presentedCollateral{{
		Symbol:         "cNGN",
		AssetAddress:   escrow,
		Balance:        e18String(balance),
		ValueUSD:       e18String(value),
		MarginValueUSD: e18String(marginValue),
	}}, nil
}

// rawPosition is the account's signed perp balance in chain units (18dp), read from SubAccounts.
func (r *perpStateReader) rawPosition(ctx context.Context, market instruments.Metadata, subaccountID string) (*big.Int, error) {
	account, err := encodeUint256(subaccountID)
	if err != nil {
		return nil, err
	}
	subAccounts, err := r.chain.subAccountsAddress(ctx)
	if err != nil {
		return nil, err
	}
	raw, err := r.chain.ethCall(ctx, subAccounts, sigGetBalance+account+addressArg(strings.ToLower(market.AssetAddress))+strings.Repeat("0", 64))
	if err != nil {
		return nil, fmt.Errorf("position: %w", err)
	}
	return signedWord(raw, 0)
}

func (r *perpStateReader) position(ctx context.Context, market instruments.Metadata, subaccountID string) (*presentedPosition, error) {
	_, raw, err := r.marketState(ctx, market)
	if err != nil {
		return nil, err
	}
	account, err := encodeUint256(subaccountID)
	if err != nil {
		return nil, err
	}
	perp := strings.ToLower(market.AssetAddress)
	srm := strings.ToLower(market.MarginManagerAddress)

	subAccounts, err := r.chain.subAccountsAddress(ctx)
	if err != nil {
		return nil, err
	}
	balanceRaw, err := r.chain.ethCall(ctx, subAccounts, sigGetBalance+account+addressArg(perp)+strings.Repeat("0", 64))
	if err != nil {
		return nil, fmt.Errorf("position: %w", err)
	}
	size, err := signedWord(balanceRaw, 0)
	if err != nil {
		return nil, err
	}
	if size.Sign() == 0 {
		return nil, nil
	}

	pnlRaw, err := r.chain.ethCall(ctx, perp, sigUnrealizedCash+account)
	if err != nil {
		return nil, fmt.Errorf("unrealized pnl: %w", err)
	}
	pnl, err := signedWord(pnlRaw, 0)
	if err != nil {
		return nil, err
	}
	imRaw, err := r.chain.ethCall(ctx, srm, sigGetMargin+account+fmt.Sprintf("%064x", 1))
	if err != nil {
		return nil, fmt.Errorf("initial margin: %w", err)
	}
	imSurplus, err := signedWord(imRaw, 0)
	if err != nil {
		return nil, err
	}
	mmRaw, err := r.chain.ethCall(ctx, srm, sigGetMargin+account+fmt.Sprintf("%064x", 0))
	if err != nil {
		return nil, fmt.Errorf("maintenance margin: %w", err)
	}
	mmSurplus, err := signedWord(mmRaw, 0)
	if err != nil {
		return nil, err
	}

	uiSide := "short"
	if size.Sign() > 0 {
		uiSide = "long"
	}
	contracts := new(big.Int).Abs(size)
	notional := new(big.Rat).SetFrac(new(big.Int).Mul(contracts, raw.index), new(big.Int).Mul(perpE18, perpE18))

	presented := &presentedPosition{
		Market:                   market.Symbol,
		SubaccountID:             subaccountID,
		EnginePosition:           e18String(size),
		UISide:                   uiSide,
		UISize:                   formatDecimal(new(big.Rat).SetFrac(contracts, perpE18), perpUIScale),
		UINotionalUSDC:           formatDecimal(notional, perpUIScale),
		MarkPriceUI:              uiPriceString(raw.mark),
		IndexPriceUI:             uiPriceString(raw.index),
		UnrealizedPnL:            e18String(pnl),
		InitialMarginSurplus:     e18String(imSurplus),
		MaintenanceMarginSurplus: e18String(mmSurplus),
	}
	if liq := liquidationPrice(size, raw.mark, raw.mmReq, mmSurplus); liq != nil {
		presented.LiquidationPriceUI = formatDecimal(liq, perpPriceScale)
	}
	return presented, nil
}

// liquidationPrice solves for the engine price at which a perp-only account's maintenance surplus
// reaches zero. Surplus is linear in price for a single position:
//
//	surplus(P) = surplus(M) + (S - |S| x mm) x (P - M)
//
// so P = M - surplus(M) / (S - |S| x mm). Nil when no positive price gets there.
func liquidationPrice(size, mark, mmReq, mmSurplus *big.Int) *big.Rat {
	s := new(big.Rat).SetFrac(size, perpE18)
	absS := new(big.Rat).Abs(s)
	mm := new(big.Rat).SetFrac(mmReq, perpE18)
	slope := new(big.Rat).Sub(s, new(big.Rat).Mul(absS, mm))
	if slope.Sign() == 0 {
		return nil
	}
	m := new(big.Rat).SetFrac(mark, perpE18)
	surplus := new(big.Rat).SetFrac(mmSurplus, perpE18)
	p := new(big.Rat).Sub(m, new(big.Rat).Quo(surplus, slope))
	if p.Sign() <= 0 {
		return nil
	}
	return p
}

func (r *perpStateReader) word(ctx context.Context, to, data string, index int) (*big.Int, error) {
	raw, err := r.chain.ethCall(ctx, to, data)
	if err != nil {
		return nil, err
	}
	return signedWord(raw, index)
}

// signedWord reads the index-th 32-byte word as a two's-complement int256.
func signedWord(raw string, index int) (*big.Int, error) {
	cleaned := strings.TrimPrefix(strings.TrimSpace(strings.ToLower(raw)), "0x")
	start := index * 64
	if len(cleaned) < start+64 {
		return nil, errors.New("return data too short")
	}
	word := cleaned[start : start+64]
	value, ok := new(big.Int).SetString(word, 16)
	if !ok {
		return nil, fmt.Errorf("invalid word %q", word)
	}
	if word[0] >= '8' {
		value.Sub(value, new(big.Int).Lsh(big.NewInt(1), 256))
	}
	return value, nil
}

func addressArg(address string) string {
	return strings.Repeat("0", 24) + strings.TrimPrefix(strings.ToLower(address), "0x")
}

func e18String(value *big.Int) string {
	return formatSignedE18(value, perpE18Scale)
}

func formatSignedE18(value *big.Int, scale int) string {
	rat := new(big.Rat).SetFrac(value, perpE18)
	if rat.Sign() < 0 {
		return "-" + formatDecimal(new(big.Rat).Neg(rat), scale)
	}
	return formatDecimal(rat, scale)
}

// uiPriceString is an 18dp engine price (USDC per cNGN) at the UI's price scale.
func uiPriceString(price *big.Int) string {
	if price.Sign() <= 0 {
		return ""
	}
	return formatDecimal(new(big.Rat).SetFrac(price, perpE18), perpPriceScale)
}

// handlePositions serves GET /v1/positions?subaccount_id=N: the account's perp positions, read from
// chain. Positions are public on chain, so this needs no signature.
func (s *Server) handlePositions(w http.ResponseWriter, r *http.Request) {
	subaccountID := strings.TrimSpace(r.URL.Query().Get("subaccount_id"))
	if subaccountID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "subaccount_id is required"})
		return
	}
	if _, err := encodeUint256(subaccountID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "subaccount_id must be a non-negative integer"})
		return
	}
	positions := []presentedPosition{}
	accounts := []presentedPerpAccount{}
	if s.perp == nil || s.instruments == nil {
		writeJSON(w, http.StatusOK, map[string]any{"positions": positions, "accounts": accounts})
		return
	}
	for _, market := range s.instruments.Enabled() {
		if !market.IsPerpetual() {
			continue
		}
		position, err := s.perp.position(r.Context(), market, subaccountID)
		if err != nil {
			slog.Error("read perp position", "market", market.Symbol, "subaccount_id", subaccountID, "error", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "could not read positions from chain"})
			return
		}
		if position != nil {
			positions = append(positions, *position)
		}
		account, err := s.perp.account(r.Context(), market, subaccountID)
		if err != nil {
			slog.Error("read perp account", "market", market.Symbol, "subaccount_id", subaccountID, "error", err)
			writeJSON(w, http.StatusBadGateway, map[string]string{"error": "could not read the account from chain"})
			return
		}
		accounts = append(accounts, *account)
	}
	writeJSON(w, http.StatusOK, map[string]any{"positions": positions, "accounts": accounts})
}
