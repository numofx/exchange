package api

import (
	"context"
	"errors"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

var futureWad = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

// The API's view of the band may be a few seconds older than the matcher's: it decides what rests on
// the book, and the matcher re-checks every fill against a fresher read.
const (
	futureAPIBandTTL  = 5 * time.Second
	futureAPIStateTTL = 30 * time.Second
)

func newFutureStateReader(cfg config.Config) *futures.Reader {
	if !cfg.FutureEnabled() {
		return nil
	}
	return futures.NewReader(cfg.ChainRPCURL, cfg.CNGNFutureAssetAddress, cfg.CNGNFutureExpiry, futureAPIBandTTL, futureAPIStateTTL)
}

// futureMarketState is the series as the chain has it, on its /v1/markets entry. Prices are cNGN per
// USDC. Absent fields were unreadable: a client must treat them as unknown, not as zero.
type futureMarketState struct {
	ExpiryTimestamp     int64  `json:"expiry_timestamp"`
	LastTradeTime       *int64 `json:"last_trade_time,omitempty"`
	Listed              *bool  `json:"listed,omitempty"`
	Settled             *bool  `json:"settled,omitempty"`
	TradingOpen         *bool  `json:"trading_open,omitempty"`
	TradingClosedReason string `json:"trading_closed_reason,omitempty"`
	MarkPrice           string `json:"mark_price,omitempty"`
	IndexPrice          string `json:"index_price,omitempty"`
	// BandWidth is markIndexBand(expiry): 0.1 is the index -/+ 10%. It narrows before expiry.
	BandWidth string `json:"band_width,omitempty"`
	// BandStatus is "ok", "index_stale" (the feed reverts BLF_DataTooOld: nothing can fill) or
	// "unreadable".
	BandStatus       string    `json:"band_status"`
	ContractSizeUSDC string    `json:"contract_size_usdc,omitempty"`
	UpdatedAt        time.Time `json:"updated_at"`
}

// presentFuture fills the entry's fill band and future block. fill_band_enforced is true for every
// future: the order API admits and the matcher fills only inside the band (internal/futures), and the
// band's edges are shown only when they could be read.
func (s *Server) presentFuture(ctx context.Context, item instruments.Metadata, presentation *marketPresentation) {
	enforced := true
	presentation.FillBandEnforced = &enforced
	state := &futureMarketState{ExpiryTimestamp: item.ExpiryTimestamp, BandStatus: "unreadable", UpdatedAt: time.Now().UTC()}
	presentation.Future = state
	if s.future == nil {
		return
	}
	switch band, err := s.future.Band(ctx); {
	case errors.Is(err, futures.ErrIndexStale):
		state.BandStatus = "index_stale"
	case err != nil:
		slog.Warn("read future band", "market", item.Symbol, "error", err)
	default:
		state.BandStatus = "ok"
		state.IndexPrice = futures.Decimal(band.Index)
		state.BandWidth = futures.Decimal(band.Width)
		presentation.FillBandLow = futures.Decimal(band.Low())
		presentation.FillBandHigh = futures.Decimal(band.High())
	}
	if contract, err := s.future.Contract(ctx); err != nil {
		slog.Warn("read future contract", "market", item.Symbol, "error", err)
	} else {
		state.Listed, state.Settled, state.LastTradeTime = &contract.Listed, &contract.Settled, &contract.LastTradeTime
		state.MarkPrice = futures.Decimal(contract.MarkPrice)
	}
	if size, err := s.future.ContractSize(ctx); err == nil {
		state.ContractSizeUSDC = futures.Decimal(size)
	}
	if open, reason, err := s.future.TradingOpen(ctx, item.TradeModuleAddress, item.MarginManagerAddress); err == nil {
		state.TradingOpen = &open
		state.TradingClosedReason = reason
	}
}

// admitFuture refuses a futures order that could never settle: one priced outside the band now, which
// would rest as depth no fill can take (the chain reverts FA_FillOutsideIndexBand), one from an account
// not under the MarginEngine (MW_UnknownManager), or one for a series that is settled or past its last
// trade time. Unreadable refuses: the band is the guard, and an order
// admitted blind is exactly the order it exists to stop. A series not yet enabled still takes resting
// orders, as the perp does before its gate opens. Returns the status and message, or "" to admit.
func (s *Server) admitFuture(ctx context.Context, instrument instruments.Metadata, params orders.CreateOrderParams) (int, string) {
	if s.future == nil {
		return http.StatusServiceUnavailable, "this deployment cannot read the future's fill band"
	}
	contract, err := s.future.Contract(ctx)
	if err != nil {
		slog.Warn("order_submit_future_unreadable", "order_id", params.OrderID, "error", err)
		return http.StatusServiceUnavailable, "the future's state could not be read; retry shortly"
	}
	if contract.Settled || time.Now().Unix() >= contract.LastTradeTime {
		return http.StatusConflict, instrument.Symbol + " is past its last trade time: no new orders"
	}
	account, ok := new(big.Int).SetString(strings.TrimSpace(params.SubaccountID), 10)
	if !ok {
		return http.StatusBadRequest, "subaccount_id is not an integer"
	}
	manager, err := s.future.ManagerOf(ctx, account)
	if err != nil {
		slog.Warn("order_submit_future_manager_unreadable", "order_id", params.OrderID, "error", err)
		return http.StatusServiceUnavailable, "the account's manager could not be read; retry shortly"
	}
	if !strings.EqualFold(manager, instrument.MarginManagerAddress) {
		return http.StatusUnprocessableEntity, "subaccount " + params.SubaccountID + " is under manager " + manager + ", not the MarginEngine " +
			instrument.MarginManagerAddress + ": only MarginEngine accounts can hold the future"
	}
	action, err := parseActionTradeData(params.ActionJSON)
	if err != nil {
		return http.StatusBadRequest, "action_json.data could not be decoded: " + err.Error()
	}
	band, err := s.future.Band(ctx)
	if errors.Is(err, futures.ErrIndexStale) {
		return http.StatusServiceUnavailable, "the future's index is stale, so no fill can settle; retry once it updates"
	}
	if err != nil {
		slog.Warn("order_submit_future_band_unreadable", "order_id", params.OrderID, "error", err)
		return http.StatusServiceUnavailable, "the future's fill band could not be read; retry shortly"
	}
	if !band.Allows(action.LimitPrice) {
		return http.StatusUnprocessableEntity, "fill_band: limit price " + futures.Decimal(action.LimitPrice) +
			" cNGN per USDC is outside the band " + futures.Decimal(band.Low()) + " to " + futures.Decimal(band.High()) +
			" (the index " + strings.TrimSpace(futures.Decimal(band.Index)) + " -/+ " + futures.Decimal(band.Width) + "); the chain refuses a fill there"
	}
	return 0, ""
}

// futureSeriesKey names a series by its FutureAsset and sub id (the expiry).
func futureSeriesKey(asset, subID string) string {
	return strings.ToLower(strings.TrimSpace(asset)) + ":" + strings.TrimSpace(subID)
}

// newFutureSeriesReaders gives every enabled future in the registry a reader, reusing primary for the
// series it reads. Nil without a chain to read.
func newFutureSeriesReaders(cfg config.Config, registry *instruments.Registry, primary *futures.Reader) map[string]*futures.Reader {
	if registry == nil || strings.TrimSpace(cfg.ChainRPCURL) == "" {
		return nil
	}
	readers := map[string]*futures.Reader{}
	for _, market := range registry.Enabled() {
		if !market.IsFuture() {
			continue
		}
		key := futureSeriesKey(market.AssetAddress, market.SubID)
		if primary != nil && key == futureSeriesKey(cfg.CNGNFutureAssetAddress, cfg.FutureSubID()) {
			readers[key] = primary
			continue
		}
		readers[key] = futures.NewReader(cfg.ChainRPCURL, market.AssetAddress, market.ExpiryTimestamp, futureAPIBandTTL, futureAPIStateTTL)
	}
	return readers
}

// Series status on /v1/positions: trading until last trade time, closing from then until the
// settlement price is fixed, settled after.
const (
	futureStatusTrading = "trading"
	futureStatusClosing = "closing"
	futureStatusSettled = "settled"
)

// presentedFuturePosition is an account's position in one dated-futures series, on /v1/positions. The
// series are USDC-cNGN, priced in cNGN per USDC: a long is long USDC, and gains when the naira weakens
// (the price rises). Variation margin accrues at every mark and is realised into cash at each
// settlement, when the manager next touches the account; PendingVMCNGN is what has accrued since.
//
// Every field but Market and SubID is read from chain, and is absent when its read failed: a client
// must treat an absent field as unknown, not zero. An entry with no Contracts is a series whose
// position could not be read.
type presentedFuturePosition struct {
	Market string `json:"market"`
	SubID  string `json:"sub_id"`
	// Status is trading, closing (past last trade time, not yet settled) or settled.
	Status string `json:"status,omitempty"`
	// Contracts is the signed FutureAsset balance; Side is "long" when it is positive.
	Contracts    string `json:"contracts,omitempty"`
	Side         string `json:"side,omitempty"`
	NotionalUSDC string `json:"notional_usdc,omitempty"`
	MarkPrice    string `json:"mark_price,omitempty"`
	// MarkUpdatedAt is when the mark was set (the settlement's time, once settled).
	MarkUpdatedAt *time.Time `json:"mark_updated_at,omitempty"`
	// PendingVMCNGN is accrued, unsettled variation margin in cNGN: positive is owed to the account.
	PendingVMCNGN string `json:"pending_vm_cngn,omitempty"`
}

// presentedFuturesAccount is the account's margin under the futures' MarginEngine. It covers the whole
// account (every series, and the cNGN it holds at its haircut), so it is reported once, not per
// position. Surpluses are USD, below zero under that margin; absent when unreadable.
type presentedFuturesAccount struct {
	SubaccountID string `json:"subaccount_id"`
	Manager      string `json:"manager"`
	IMSurplusUSD string `json:"im_surplus_usd,omitempty"`
	MMSurplusUSD string `json:"mm_surplus_usd,omitempty"`
}

// futurePosition reads the account's position in a series. Nil when the account is flat. A failed
// position read still lists the series, with the position absent; any other failed read leaves only
// its own fields out.
func (s *Server) futurePosition(ctx context.Context, market instruments.Metadata, reader *futures.Reader, account *big.Int, now time.Time) *presentedFuturePosition {
	presented := &presentedFuturePosition{Market: market.Symbol, SubID: market.SubID}
	size, err := reader.Position(ctx, account)
	if err != nil {
		slog.Warn("read future position", "market", market.Symbol, "subaccount_id", account.String(), "error", err)
		return presented
	}
	if size.Sign() == 0 {
		return nil
	}
	presented.Contracts = futures.Decimal(size)
	presented.Side = "short"
	if size.Sign() > 0 {
		presented.Side = "long"
	}
	if contract, err := reader.Contract(ctx); err != nil {
		slog.Warn("read future contract", "market", market.Symbol, "error", err)
	} else {
		switch {
		case contract.Settled:
			presented.Status = futureStatusSettled
		case now.Unix() >= contract.LastTradeTime:
			presented.Status = futureStatusClosing
		default:
			presented.Status = futureStatusTrading
		}
		presented.MarkPrice = futures.Decimal(contract.MarkPrice)
		updated := time.Unix(contract.LastMarkTime, 0).UTC()
		presented.MarkUpdatedAt = &updated
	}
	if contractSize, err := reader.ContractSize(ctx); err != nil {
		slog.Warn("read future contract size", "market", market.Symbol, "error", err)
	} else {
		notional := new(big.Int).Mul(new(big.Int).Abs(size), contractSize)
		presented.NotionalUSDC = futures.Decimal(notional.Div(notional, futureWad))
	}
	if vm, err := reader.PendingVM(ctx, account); err != nil {
		slog.Warn("read future pending vm", "market", market.Symbol, "subaccount_id", account.String(), "error", err)
	} else {
		presented.PendingVMCNGN = futures.Decimal(vm)
	}
	return presented
}

// futuresAccount reads the account's margin under the engine. Nil when the account is under another
// manager: it holds no futures, and the engine's margin of it means nothing.
func (s *Server) futuresAccount(ctx context.Context, reader *futures.Reader, engine string, account *big.Int) *presentedFuturesAccount {
	presented := &presentedFuturesAccount{SubaccountID: account.String(), Manager: engine}
	manager, err := reader.ManagerOf(ctx, account)
	if err != nil {
		slog.Warn("read futures account manager", "subaccount_id", account.String(), "error", err)
		return presented
	}
	if !strings.EqualFold(manager, engine) {
		return nil
	}
	if im, err := reader.IMSurplus(ctx, engine, account); err != nil {
		slog.Warn("read futures im surplus", "subaccount_id", account.String(), "error", err)
	} else {
		presented.IMSurplusUSD = futures.Decimal(im)
	}
	if mm, err := reader.MMSurplus(ctx, engine, account); err != nil {
		slog.Warn("read futures mm surplus", "subaccount_id", account.String(), "error", err)
	} else {
		presented.MMSurplusUSD = futures.Decimal(mm)
	}
	return presented
}

// futuresPositions is the account's position in every listed series, and its margin under their
// engine. Never an error: a read that fails is an absent field.
func (s *Server) futuresPositions(ctx context.Context, subaccountID string) ([]presentedFuturePosition, *presentedFuturesAccount) {
	positions := []presentedFuturePosition{}
	account, ok := new(big.Int).SetString(subaccountID, 10)
	if !ok || s.instruments == nil {
		return positions, nil
	}
	var engine string
	var engineReader *futures.Reader
	now := time.Now()
	for _, market := range s.instruments.Enabled() {
		if !market.IsFuture() {
			continue
		}
		reader := s.futureSeries[futureSeriesKey(market.AssetAddress, market.SubID)]
		if reader == nil {
			continue
		}
		if engineReader == nil {
			engine, engineReader = market.MarginManagerAddress, reader
		}
		if position := s.futurePosition(ctx, market, reader, account, now); position != nil {
			positions = append(positions, *position)
		}
	}
	if engineReader == nil {
		return positions, nil
	}
	return positions, s.futuresAccount(ctx, engineReader, engine, account)
}
