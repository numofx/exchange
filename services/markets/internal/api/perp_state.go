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
// Everything is served in both orientations. The engine prices the perp in USD per NGN; the venue
// shows NGN per USD with the side flipped. Funding is the one place the flip bites: the chain's rate
// is paid by NGN-perp LONGS, which are the venue's SHORTS, so ui_long_funding_rate_1h is its negation.

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

	perpStateTTL = 10 * time.Second
	perpUIScale  = 6
	perpE18Scale = 18
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
	UpdatedAt              int64  `json:"updated_at"`
}

type presentedPosition struct {
	Market       string `json:"market"`
	SubaccountID string `json:"subaccount_id"`
	// EnginePosition is the signed NGN-perp balance; UISide/UISize are the venue's view of it.
	EnginePosition string `json:"engine_position"`
	UISide         string `json:"ui_side"`
	UISize         string `json:"ui_size"`
	MarkPriceUI    string `json:"mark_price_ui"`
	IndexPriceUI   string `json:"index_price_ui"`
	UnrealizedPnL  string `json:"unrealized_pnl"`
	// Margin surpluses as the SRM computes them: below zero means under that margin.
	InitialMarginSurplus     string `json:"initial_margin_surplus"`
	MaintenanceMarginSurplus string `json:"maintenance_margin_surplus"`
	// LiquidationPriceUI is where the account would fall below maintenance margin if nothing else
	// changed; empty when no price gets it there. An estimate, for a perp-only account.
	LiquidationPriceUI string `json:"liquidation_price_ui,omitempty"`
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
		return cached.state, cached.raw, nil
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

	state := &perpMarketState{
		MarkPrice:              e18String(mark),
		IndexPrice:             e18String(index),
		MarkPriceUI:            inverseString(mark),
		IndexPriceUI:           inverseString(index),
		FundingRate1h:          e18String(funding),
		UILongFunding1h:        e18String(new(big.Int).Neg(funding)),
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
	raw := perpRaw{mark: mark, index: index, imReq: imReq, mmReq: mmReq}

	r.mu.Lock()
	r.cache[key] = cachedPerpState{state: state, raw: raw, at: r.now()}
	r.mu.Unlock()
	return state, raw, nil
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
	if size.Sign() < 0 {
		// short the NGN perp = long USD, the venue's long
		uiSide = "long"
	}
	notional := new(big.Rat).SetFrac(new(big.Int).Mul(new(big.Int).Abs(size), raw.index), new(big.Int).Mul(perpE18, perpE18))

	presented := &presentedPosition{
		Market:                   market.Symbol,
		SubaccountID:             subaccountID,
		EnginePosition:           e18String(size),
		UISide:                   uiSide,
		UISize:                   formatDecimal(notional, perpUIScale),
		MarkPriceUI:              inverseString(raw.mark),
		IndexPriceUI:             inverseString(raw.index),
		UnrealizedPnL:            e18String(pnl),
		InitialMarginSurplus:     e18String(imSurplus),
		MaintenanceMarginSurplus: e18String(mmSurplus),
	}
	if liq := liquidationPrice(size, raw.mark, raw.mmReq, mmSurplus); liq != nil {
		presented.LiquidationPriceUI = formatDecimal(new(big.Rat).Inv(liq), perpUIScale)
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

// inverseString is 1/price for an 18dp engine price: NGN per USD from USD per NGN.
func inverseString(price *big.Int) string {
	if price.Sign() <= 0 {
		return ""
	}
	return formatDecimal(new(big.Rat).SetFrac(perpE18, price), perpUIScale)
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
	if s.perp == nil || s.instruments == nil {
		writeJSON(w, http.StatusOK, map[string]any{"positions": positions})
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
	}
	writeJSON(w, http.StatusOK, map[string]any{"positions": positions})
}
