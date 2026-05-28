package matching

import (
	"context"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

type Engine struct {
	cfg      config.Config
	orders   *orders.Repository
	executor *ExecutorClient
	registry *instruments.Registry
}

const reconciliationTimeout = 5 * time.Second

func NewEngine(cfg config.Config, pool *pgxpool.Pool) *Engine {
	return &Engine{
		cfg:      cfg,
		orders:   orders.NewRepository(pool),
		executor: NewExecutorClient(cfg.ExecutorURL, cfg.ExecutorManagerData),
		registry: instruments.DefaultRegistry(cfg),
	}
}

func (e *Engine) Run(ctx context.Context) error {
	ticker := time.NewTicker(e.cfg.MatcherPollInterval)
	defer ticker.Stop()

	slog.Info("matcher started", "interval", e.cfg.MatcherPollInterval)

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			for _, instrument := range e.registry.Enabled() {
				e.tickInstrument(ctx, instrument)
			}
		}
	}
}

func (e *Engine) tickInstrument(ctx context.Context, instrument instruments.Metadata) {
	now := time.Now()

	candidate, err := e.orders.AcquireMatchCandidate(ctx, instrument.AssetAddress, instrument.SubID, now)
	if err != nil {
		slog.Error("acquire match candidate", "market", instrument.Symbol, "error", err)
		return
	}
	if candidate == nil {
		slog.Debug("matcher tick", "market", instrument.Symbol, "status", "book_not_crossed")
		return
	}

	slog.Info(
		"match_trace_candidate",
		"market", instrument.Symbol,
		"asset_address", strings.ToLower(instrument.AssetAddress),
		"sub_id", instrument.SubID,
		"taker_order_id", candidate.Taker.OrderID,
		"taker_side", candidate.Taker.Side,
		"taker_price_ticks", candidate.Taker.LimitPriceTicks,
		"maker_order_id", candidate.Maker.OrderID,
		"maker_side", candidate.Maker.Side,
		"maker_price_ticks", candidate.Maker.LimitPriceTicks,
	)

	release := true
	defer func() {
		if !release {
			return
		}
		reconcileCtx, cancel := detachedContext(ctx, reconciliationTimeout)
		defer cancel()
		if err := e.orders.ReleaseMatch(reconcileCtx, candidate.Taker.OrderID, candidate.Maker.OrderID); err != nil {
			slog.Error("release reserved orders", "market", instrument.Symbol, "taker_order_id", candidate.Taker.OrderID, "maker_order_id", candidate.Maker.OrderID, "error", err)
		}
	}()

	if candidate.Taker.IsExpired(now) || candidate.Maker.IsExpired(now) {
		slog.Debug("matcher tick", "market", instrument.Symbol, "status", "expired_order_present")
		return
	}

	priceCrossed, err := crosses(candidate.Taker, candidate.Maker)
	if err != nil {
		slog.Error("compare prices", "market", instrument.Symbol, "error", err)
		return
	}
	if !priceCrossed {
		slog.Debug("matcher tick", "market", instrument.Symbol, "status", "book_not_crossed")
		return
	}

	slog.Info(
		"match_trace_crossed",
		"market", instrument.Symbol,
		"asset_address", strings.ToLower(instrument.AssetAddress),
		"sub_id", instrument.SubID,
		"taker_order_id", candidate.Taker.OrderID,
		"maker_order_id", candidate.Maker.OrderID,
	)

	fillPrice := candidate.Maker.LimitPriceTicks
	logPrice := candidate.Maker.LimitPrice
	fillAmount, err := minDecimalString(remainingAmount(candidate.Taker), remainingAmount(candidate.Maker))
	if err != nil {
		slog.Error("compute fill amount", "market", instrument.Symbol, "error", err)
		return
	}
	if fillAmount == "0" {
		slog.Error(
			"crossed_order_zero_fill",
			"market", instrument.Symbol,
			"asset_address", strings.ToLower(instrument.AssetAddress),
			"sub_id", instrument.SubID,
			"taker_order_id", candidate.Taker.OrderID,
			"maker_order_id", candidate.Maker.OrderID,
			"taker_desired_amount", candidate.Taker.DesiredAmount,
			"taker_filled_amount", candidate.Taker.FilledAmount,
			"maker_desired_amount", candidate.Maker.DesiredAmount,
			"maker_filled_amount", candidate.Maker.FilledAmount,
		)
		return
	}

	executionFill, err := computeExecutionUnits(instrument, *candidate, fillPrice, fillAmount)
	if err != nil {
		slog.Error(
			"match_trace_invariant_failed",
			"market", instrument.Symbol,
			"asset_address", strings.ToLower(instrument.AssetAddress),
			"sub_id", instrument.SubID,
			"taker_order_id", candidate.Taker.OrderID,
			"maker_order_id", candidate.Maker.OrderID,
			"fill_price_ticks", fillPrice,
			"fill_amount_atomic", fillAmount,
			"error", err,
		)

		reconcileCtx, cancel := detachedContext(ctx, reconciliationTimeout)
		defer cancel()
		_ = e.orders.MarkMatchFailed(reconcileCtx, []string{candidate.Taker.OrderID, candidate.Maker.OrderID}, err.Error())
		return
	}

	slog.Info(
		"match_trace_executor_submit",
		"market", instrument.Symbol,
		"asset_address", strings.ToLower(instrument.AssetAddress),
		"sub_id", instrument.SubID,
		"taker_order_id", candidate.Taker.OrderID,
		"maker_order_id", candidate.Maker.OrderID,
		"fill_price_ticks", fillPrice,
		"fill_amount_atomic", fillAmount,
		"executor_fill_price", executionFill.FillPrice,
		"executor_fill_amount", executionFill.FillAmount,
	)
	executorResp, err := e.executor.SubmitMatchForMarket(ctx, instrument.Symbol, *candidate, executionFill.FillPrice, executionFill.FillAmount)
	if err != nil {
		reconcileCtx, cancel := detachedContext(ctx, reconciliationTimeout)
		defer cancel()

		if shouldFinalizeAfterExecutorError(err) {
			if finalizeErr := e.orders.FinalizeMatchWithPrice(reconcileCtx, candidate.Taker.OrderID, candidate.Maker.OrderID, logPrice, fillAmount); finalizeErr != nil {
				slog.Error("reconcile already-filled match",
					"market", instrument.Symbol,
					"taker_order_id", candidate.Taker.OrderID,
					"maker_order_id", candidate.Maker.OrderID,
					"executor_error", err,
					"error", finalizeErr,
				)
				return
			}

			release = false
			slog.Warn("reconciled match after executor error",
				"market", instrument.Symbol,
				"price_semantics", instrument.PriceSemantics,
				"maker_order_id", candidate.Maker.OrderID,
				"taker_order_id", candidate.Taker.OrderID,
				"fill_price", logPrice,
				"fill_price_ticks", fillPrice,
				"amount", fillAmount,
				"executor_error", err,
			)
			return
		}

		slog.Error("submit match", "market", instrument.Symbol, "taker_order_id", candidate.Taker.OrderID, "maker_order_id", candidate.Maker.OrderID, "error", err)
		_ = e.orders.MarkMatchFailed(reconcileCtx, []string{candidate.Taker.OrderID, candidate.Maker.OrderID}, err.Error())
		return
	}

	slog.Info(
		"match_trace_executor_result",
		"market", instrument.Symbol,
		"taker_order_id", candidate.Taker.OrderID,
		"maker_order_id", candidate.Maker.OrderID,
		"accepted", executorResp.Accepted,
		"tx_hash", executorResp.TxHash,
	)

	reconcileCtx, cancel := detachedContext(ctx, reconciliationTimeout)
	defer cancel()
	if err := e.orders.FinalizeMatchWithPrice(reconcileCtx, candidate.Taker.OrderID, candidate.Maker.OrderID, logPrice, fillAmount); err != nil {
		slog.Error("finalize match", "market", instrument.Symbol, "taker_order_id", candidate.Taker.OrderID, "maker_order_id", candidate.Maker.OrderID, "error", err)
		return
	}

	slog.Info(
		"match_trace_finalize_success",
		"market", instrument.Symbol,
		"taker_order_id", candidate.Taker.OrderID,
		"maker_order_id", candidate.Maker.OrderID,
		"fill_amount", fillAmount,
		"fill_price", logPrice,
	)

	release = false

	slog.Info("match executed",
		"market", instrument.Symbol,
		"price_semantics", instrument.PriceSemantics,
		"maker_order_id", candidate.Maker.OrderID,
		"taker_order_id", candidate.Taker.OrderID,
		"fill_price", logPrice,
		"fill_price_ticks", fillPrice,
		"amount", fillAmount,
		"tx_hash", executorResp.TxHash,
	)
}

func remainingAmount(order orders.Order) string {
	remaining, err := subtractDecimalString(order.DesiredAmount, order.FilledAmount)
	if err != nil {
		return "0"
	}
	return remaining
}

func crosses(taker orders.Order, maker orders.Order) (bool, error) {
	takerPrice, ok := new(big.Int).SetString(taker.LimitPriceTicks, 10)
	if !ok {
		return false, slogError("invalid taker price")
	}
	makerPrice, ok := new(big.Int).SetString(maker.LimitPriceTicks, 10)
	if !ok {
		return false, slogError("invalid maker price")
	}

	switch taker.Side {
	case orders.SideBuy:
		return takerPrice.Cmp(makerPrice) >= 0, nil
	case orders.SideSell:
		return takerPrice.Cmp(makerPrice) <= 0, nil
	default:
		return false, fmt.Errorf("unsupported taker side %q", taker.Side)
	}
}

func minDecimalString(a string, b string) (string, error) {
	left, ok := new(big.Int).SetString(a, 10)
	if !ok {
		return "", slogError("invalid decimal value")
	}
	right, ok := new(big.Int).SetString(b, 10)
	if !ok {
		return "", slogError("invalid decimal value")
	}
	if left.Cmp(right) <= 0 {
		return left.String(), nil
	}
	return right.String(), nil
}

func subtractDecimalString(a string, b string) (string, error) {
	left, ok := new(big.Int).SetString(a, 10)
	if !ok {
		return "", slogError("invalid decimal value")
	}
	right, ok := new(big.Int).SetString(b, 10)
	if !ok {
		return "", slogError("invalid decimal value")
	}
	if left.Cmp(right) < 0 {
		return "", slogError("filled amount exceeds desired amount")
	}
	return new(big.Int).Sub(left, right).String(), nil
}

func slogError(message string) error {
	return &matcherError{message: message}
}

func detachedContext(parent context.Context, timeout time.Duration) (context.Context, context.CancelFunc) {
	if deadline, ok := parent.Deadline(); ok {
		if remaining := time.Until(deadline); remaining > 0 && remaining < timeout {
			timeout = remaining
		}
	}
	return context.WithTimeout(context.Background(), timeout)
}

func shouldFinalizeAfterExecutorError(err error) bool {
	if err == nil {
		return false
	}

	message := err.Error()
	return strings.Contains(message, "TM_FillLimitCrossed") || strings.Contains(message, "0xfea8fa6f")
}

type matcherError struct {
	message string
}

func (e *matcherError) Error() string {
	return e.message
}
