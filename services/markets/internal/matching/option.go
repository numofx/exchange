package matching

import (
	"context"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/options"
	"github.com/numofx/matching-backend/internal/orders"
)

// optionStateTTL is how long a series' trading switches (cap, pause, vol surface) are trusted: the vol feed's heartbeat
// is 30 minutes, so a surface that lapses is seen within a tick or two.
const optionStateTTL = 15 * time.Second

// newOptionReaders is one reader per listed option series, keyed by asset and expiry: every strike of a series shares it.
func newOptionReaders(cfg config.Config) map[string]*options.Reader {
	readers := map[string]*options.Reader{}
	for _, series := range cfg.OptionSeries {
		readers[optionSeriesKey(series.AssetAddress, series.Expiry)] = options.NewReader(cfg.ChainRPCURL, series, optionStateTTL)
	}
	return readers
}

func optionSeriesKey(asset string, expiry int64) string {
	return strings.ToLower(strings.TrimSpace(asset)) + ":" + big.NewInt(expiry).String()
}

func (e *Engine) optionReader(instrument instruments.Metadata) *options.Reader {
	return e.options[optionSeriesKey(instrument.AssetAddress, instrument.ExpiryTimestamp)]
}

// optionOpen gates a strike's matching on its series: before last trade, enabled on chain, engine not paused, vol live.
// Unreadable is closed: a strike that cannot be shown open is not crossed.
func (e *Engine) optionOpen(ctx context.Context, instrument instruments.Metadata) bool {
	reader := e.optionReader(instrument)
	if reader == nil {
		return false
	}
	open, reason, err := reader.TradingOpen(ctx, instrument.TradeModuleAddress)
	if err != nil {
		slog.Warn("option_gate_unreadable", "market", instrument.Symbol, "error", err.Error())
		return false
	}
	if !open {
		slog.Debug("option_gate_closed", "market", instrument.Symbol, "reason", reason)
	}
	return open
}

// optionMarginAllows pre-checks both accounts of an option fill against the engine: the buyer pays the premium (and the
// taker its fee) in the market's own cash, the writer takes on the strike's isolated requirement. An account that cannot
// carry the fill has its order held back and, refused often enough, cancelled, as a future's (future_margin.go).
//
// Exact only for an account holding no long option of the expiry (options.Shortfall); any other account, and anything
// unreadable, is left to the chain, whose refusal backs the pair off as before.
func (e *Engine) optionMarginAllows(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillPrice, fillAmount, takerFee string) bool {
	reader := e.optionReader(instrument)
	if reader == nil {
		return true
	}
	price, okPrice := new(big.Int).SetString(fillPrice, 10)
	amount, okAmount := new(big.Int).SetString(fillAmount, 10)
	fee, okFee := new(big.Int).SetString(takerFee, 10)
	strike, okStrike := strikeWei(instrument)
	if !okPrice || !okAmount || !okFee || !okStrike {
		return true
	}
	borrowing, err := reader.Borrowing(ctx)
	if err != nil {
		slog.Warn("option_margin_precheck_unreadable", "market", instrument.Symbol, "error", err.Error())
		return true
	}
	premium := options.Premium(price, amount)
	isCall := instrument.OptionType == "call"
	allowed := true
	for _, leg := range []struct {
		order orders.Order
		role  string
	}{{candidate.Taker, "taker"}, {candidate.Maker, "maker"}} {
		account, ok := new(big.Int).SetString(strings.TrimSpace(leg.order.SubaccountID), 10)
		if !ok {
			continue
		}
		side, err := e.optionLeg(ctx, reader, instrument, account, leg.order, leg.role == "taker", strike, isCall, amount, premium, fee, borrowing)
		if err != nil {
			slog.Warn("option_margin_precheck_unreadable", "market", instrument.Symbol, "order_id", leg.order.OrderID, "error", err.Error())
			continue
		}
		if side == nil {
			continue // holds a long of the expiry: the chain decides
		}
		short, reason, post := options.Shortfall(*side)
		if !short {
			e.marginRefusals.clear(leg.order)
			continue
		}
		allowed = false
		count, cancel := e.marginRefusals.refuse(leg.order)
		slog.Warn("option_fill_refused", "market", instrument.Symbol, "reason", reason, "role", leg.role,
			"order_id", leg.order.OrderID, "subaccount_id", leg.order.SubaccountID, "after", futures.Decimal(post),
			"consecutive_refusals", count)
		if !cancel {
			continue
		}
		reconcileCtx, done := detachedContext(ctx, reconciliationTimeout)
		if err := e.orders.CancelByVenue(reconcileCtx, leg.order.OrderID, CancelReasonInsufficientMargin); err != nil {
			slog.Error("option_margin_cancel_failed", "market", instrument.Symbol, "order_id", leg.order.OrderID, "error", err)
		} else {
			slog.Warn("option_order_cancelled", "market", instrument.Symbol, "reason", CancelReasonInsufficientMargin,
				"order_id", leg.order.OrderID, "subaccount_id", leg.order.SubaccountID, "refusals", count)
			e.marginRefusals.clear(leg.order)
		}
		done()
	}
	return allowed
}

// optionLeg reads one account's side of the fill. Nil (no error) when the account holds a long of the expiry.
func (e *Engine) optionLeg(ctx context.Context, reader *options.Reader, instrument instruments.Metadata, account *big.Int, order orders.Order,
	taker bool, strike *big.Int, isCall bool, amount, premium, fee *big.Int, borrowing bool) (*options.Leg, error) {
	long, err := reader.HoldsLong(ctx, account)
	if err != nil || long {
		return nil, err
	}
	surplus, err := reader.IMSurplus(ctx, account)
	if err != nil {
		return nil, err
	}
	cash, err := reader.Cash(ctx, account, instrument.QuoteAssetAddress)
	if err != nil {
		return nil, err
	}
	position, err := reader.Position(ctx, account, instrument.SubID)
	if err != nil {
		return nil, err
	}
	delta, cashDelta := new(big.Int).Set(amount), new(big.Int).Neg(premium)
	if order.Side == orders.SideSell {
		delta.Neg(delta)
		cashDelta.Neg(cashDelta)
	}
	after := new(big.Int).Add(position, delta)
	isoBefore, err := reader.IsolatedIM(ctx, strike, isCall, position)
	if err != nil {
		return nil, err
	}
	isoAfter, err := reader.IsolatedIM(ctx, strike, isCall, after)
	if err != nil {
		return nil, err
	}
	legFee := big.NewInt(0)
	if taker {
		legFee = fee
	}
	return &options.Leg{Surplus: surplus, Cash: cash, Delta: delta, CashDelta: cashDelta, Fee: legFee,
		IsoBefore: isoBefore, IsoAfter: isoAfter, Borrowing: borrowing}, nil
}

func strikeWei(instrument instruments.Metadata) (*big.Int, bool) {
	wei, err := config.StrikeWei(instrument.OptionStrike)
	if err != nil {
		return nil, false
	}
	return wei, true
}
