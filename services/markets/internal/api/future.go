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
