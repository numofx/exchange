package api

import (
	"context"
	"log/slog"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/options"
	"github.com/numofx/matching-backend/internal/orders"
)

const optionAPIStateTTL = 15 * time.Second

// optionMarketState is an option strike's live state on /v1/markets. TradingOpen is absent while it cannot be read.
type optionMarketState struct {
	Strike              string    `json:"strike"`
	OptionType          string    `json:"option_type"`
	ExpiryTimestamp     int64     `json:"expiry_timestamp"`
	LastTradeTime       int64     `json:"last_trade_time"`
	VolFeedAddress      string    `json:"vol_feed_address"`
	TradingOpen         *bool     `json:"trading_open,omitempty"`
	TradingClosedReason string    `json:"trading_closed_reason,omitempty"`
	UpdatedAt           time.Time `json:"updated_at"`
}

// newOptionSeriesReaders is one reader per listed option series (every strike of an expiry shares it), for /v1/markets
// and order admission. Nil without a chain to read.
func newOptionSeriesReaders(cfg config.Config) map[string]*options.Reader {
	if strings.TrimSpace(cfg.ChainRPCURL) == "" || len(cfg.OptionSeries) == 0 {
		return nil
	}
	readers := map[string]*options.Reader{}
	for _, series := range cfg.OptionSeries {
		readers[optionSeriesKey(series.AssetAddress, series.Expiry)] = options.NewReader(cfg.ChainRPCURL, series, optionAPIStateTTL)
	}
	return readers
}

func optionSeriesKey(asset string, expiry int64) string {
	return strings.ToLower(strings.TrimSpace(asset)) + ":" + strconv.FormatInt(expiry, 10)
}

func (s *Server) optionReader(instrument instruments.Metadata) *options.Reader {
	return s.optionSeries[optionSeriesKey(instrument.AssetAddress, instrument.ExpiryTimestamp)]
}

// presentOption adds a strike's state: its terms, and whether it is matching now (and why not).
func (s *Server) presentOption(ctx context.Context, item instruments.Metadata, presentation *marketPresentation) {
	state := &optionMarketState{Strike: item.OptionStrike, OptionType: item.OptionType, ExpiryTimestamp: item.ExpiryTimestamp,
		LastTradeTime: item.LastTradeTimestamp, VolFeedAddress: item.VolFeedAddress, UpdatedAt: time.Now().UTC()}
	presentation.Option = state
	reader := s.optionReader(item)
	if reader == nil {
		return
	}
	open, reason, err := reader.TradingOpen(ctx, item.TradeModuleAddress)
	if err != nil {
		slog.Warn("read option gate", "market", item.Symbol, "error", err)
		return
	}
	state.TradingOpen, state.TradingClosedReason = &open, reason
}

// admitOption refuses an option order that can never fill: past its last trade time, from an account the option's
// engine does not manage, or at a premium no option can be worth (zero or less; a put above its strike, which is
// all it can ever pay). Before the series is enabled orders may rest, as a future's, so makers can quote ahead of it.
func (s *Server) admitOption(ctx context.Context, instrument instruments.Metadata, params orders.CreateOrderParams) (int, string) {
	if time.Now().Unix() >= instrument.LastTradeTimestamp {
		return http.StatusConflict, instrument.Symbol + " is past its last trade time: no new orders"
	}
	action, err := parseActionTradeData(params.ActionJSON)
	if err != nil {
		return http.StatusBadRequest, "action_json.data could not be decoded: " + err.Error()
	}
	if status, msg := optionPremiumBound(instrument, action.LimitPrice); msg != "" {
		return status, msg
	}
	reader := s.optionReader(instrument)
	if reader == nil {
		return http.StatusServiceUnavailable, "this deployment cannot read the option's engine"
	}
	account, ok := new(big.Int).SetString(strings.TrimSpace(params.SubaccountID), 10)
	if !ok {
		return http.StatusBadRequest, "subaccount_id is not an integer"
	}
	manager, err := reader.ManagerOf(ctx, account)
	if err != nil {
		slog.Warn("order_submit_option_manager_unreadable", "order_id", params.OrderID, "error", err)
		return http.StatusServiceUnavailable, "the account's manager could not be read; retry shortly"
	}
	if !strings.EqualFold(manager, instrument.MarginManagerAddress) {
		return http.StatusUnprocessableEntity, "subaccount " + params.SubaccountID + " is under manager " + manager + ", not the MarginEngine " +
			instrument.MarginManagerAddress + ": only its accounts can hold the option"
	}
	return 0, ""
}

// optionPremiumBound is the premium's sanity bound, in USDC per base: above zero, and a put at most its strike.
func optionPremiumBound(instrument instruments.Metadata, limit *big.Int) (int, string) {
	if limit == nil || limit.Sign() <= 0 {
		return http.StatusUnprocessableEntity, "an option's limit price is its premium, and must be above zero"
	}
	if instrument.OptionType != "put" {
		return 0, ""
	}
	strike, err := config.StrikeWei(instrument.OptionStrike)
	if err != nil {
		return http.StatusInternalServerError, "the market's strike does not parse"
	}
	if limit.Cmp(strike) > 0 {
		return http.StatusUnprocessableEntity, "premium " + futures.Decimal(limit) + " " + instrument.EnginePriceUnit + " is above the put's strike " +
			instrument.OptionStrike + ", the most it can ever pay"
	}
	return 0, ""
}
