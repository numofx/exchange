package matching

import (
	"context"
	"log/slog"
	"math/big"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// An order whose own account cannot carry the fill is held back for futureMarginRetry against every
// counterparty, not only the one it failed with, so it cannot absorb each new taker at the top of the
// book. Refused futureMarginCancelAfter times in a row, at least futureMarginCancelMinSpan apart from
// the first, it is cancelled: by then a deposit already on its way has had time to land.
const (
	futureMarginRetry         = 30 * time.Second
	futureMarginCancelAfter   = 3
	futureMarginCancelMinSpan = time.Minute
	futureMarginStateTTL      = 25 * time.Hour

	CancelReasonInsufficientMargin = "insufficient_margin"
)

// futureSide is one account's half of a prospective fill, in chain units (18dp).
type futureSide struct {
	Surplus  *big.Int // engine.getMargin(account, true), USD
	Position *big.Int // contracts, signed, before the fill
	Delta    *big.Int // contracts, signed: +amount for the buyer, -amount for the seller
	Fee      *big.Int // USDC cash the account pays (the taker's fee; 0 for the maker)
}

// futureFillShortfall estimates the account's IM surplus after the fill and reports whether it is
// below zero, the engine's own test for a trade that adds risk (SRM_PortfolioBelowMargin otherwise).
//
// Futures margin is gross (|position| x contractSize x imReq, no offsets against the perp or spot), so
// the fill's effect is separable from the rest of the portfolio, which getMargin already prices. The
// estimate is deliberately optimistic, so a refusal is one the engine would also make:
//   - the IM rate without the engine's depeg penalty;
//   - VM the fill realises against the mark counted at par if it is a gain (the engine discounts it
//     by the base margin factor), and not at all if it is a loss;
//   - the fee, which is certain.
//
// Only a fill the engine treats as adding risk is checked: one that leaves a position on the side the
// fill traded (MarginEngine.handleAdjustment: delta x position > 0). A reduction or a close-out is held
// to maintenance margin there, so an account can always deleverage, and the chain decides. A flip adds
// risk, with IM added only for the contracts beyond the old |position|.
func futureFillShortfall(side futureSide, contractSize, imRate, fillPrice, mark, index *big.Int) (short bool, post *big.Int) {
	resulting := new(big.Int).Add(side.Position, side.Delta)
	if resulting.Sign() == 0 || resulting.Sign() != side.Delta.Sign() {
		return false, nil
	}
	added := new(big.Int).Sub(new(big.Int).Abs(resulting), new(big.Int).Abs(side.Position))
	if added.Sign() < 0 {
		added.SetInt64(0)
	}
	// added contracts x contract size (USDC) x imRate, each 18dp
	addedIM := new(big.Int).Mul(added, contractSize)
	addedIM.Div(addedIM, feeQuoteScale)
	addedIM.Mul(addedIM, imRate)
	addedIM.Div(addedIM, feeQuoteScale)

	post = new(big.Int).Sub(side.Surplus, addedIM)
	post.Sub(post, side.Fee)

	// VM at the fill, in cNGN: delta x contractSize x (mark - fill). A buyer below the mark gains.
	vm := new(big.Int).Mul(side.Delta, contractSize)
	vm.Mul(vm, new(big.Int).Sub(mark, fillPrice))
	vm.Quo(vm, feeQuoteScale)
	vm.Quo(vm, feeQuoteScale)
	if vm.Sign() > 0 && index.Sign() > 0 {
		// cNGN to USD at the index (cNGN per USDC)
		post.Add(post, new(big.Int).Quo(new(big.Int).Mul(vm, feeQuoteScale), index))
	}
	return post.Sign() < 0, post
}

// futureMarginRefusals counts consecutive margin refusals per order.
type futureMarginRefusals struct {
	mu    sync.Mutex
	state map[string]*marginRefusal
	now   func() time.Time
}

type marginRefusal struct {
	count  int
	first  time.Time
	next   time.Time
	filled string
}

func newFutureMarginRefusals() *futureMarginRefusals {
	return &futureMarginRefusals{state: map[string]*marginRefusal{}, now: time.Now}
}

// blocked reports whether the order is inside its hold-back window. A fill on it since it was refused
// (its filled amount changed) clears the hold: its account's position, and so its margin, has moved.
func (r *futureMarginRefusals) blocked(order orders.Order) bool {
	if r == nil {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	entry, ok := r.state[order.OrderID]
	if !ok {
		return false
	}
	if entry.filled != order.FilledAmount {
		delete(r.state, order.OrderID)
		return false
	}
	return r.now().Before(entry.next)
}

// refuse records a refusal and reports whether the order has now earned cancellation.
func (r *futureMarginRefusals) refuse(order orders.Order) (count int, cancel bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.now()
	entry, ok := r.state[order.OrderID]
	if !ok || entry.filled != order.FilledAmount {
		entry = &marginRefusal{first: now, filled: order.FilledAmount}
		r.state[order.OrderID] = entry
	}
	entry.count++
	entry.next = now.Add(futureMarginRetry)
	for id, e := range r.state {
		if now.Sub(e.first) > futureMarginStateTTL {
			delete(r.state, id)
		}
	}
	return entry.count, entry.count >= futureMarginCancelAfter && now.Sub(entry.first) >= futureMarginCancelMinSpan
}

// clear forgets an order whose account carried the fill: refusals must be consecutive.
func (r *futureMarginRefusals) clear(order orders.Order) {
	r.mu.Lock()
	delete(r.state, order.OrderID)
	r.mu.Unlock()
}

// matchGate is what AcquireMatchCandidate skips: a pair in backoff, or an order held back for its own
// account's margin. The walk moves on to the next pair, so a held order blocks nothing behind it.
func (e *Engine) matchGate(taker, maker orders.Order) bool {
	return e.backoff.shouldSkip(taker, maker) || e.marginRefusals.blocked(taker) || e.marginRefusals.blocked(maker)
}

// futureMarginAllows pre-checks both accounts of a futures fill against the engine. An account that
// cannot carry it has its order held back from every counterparty and, refused often enough, cancelled;
// the other order is untouched. Unreadable is allowed through: the engine is the authority, and an
// unattributed SRM_PortfolioBelowMargin backs the pair off as before, with the next attempt pre-checked
// against fresh reads.
func (e *Engine) futureMarginAllows(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillPrice, fillAmount, takerFee string) bool {
	if e.future == nil {
		return true
	}
	price, okPrice := new(big.Int).SetString(fillPrice, 10)
	amount, okAmount := new(big.Int).SetString(fillAmount, 10)
	fee, okFee := new(big.Int).SetString(takerFee, 10)
	if !okPrice || !okAmount || !okFee {
		return true
	}
	engine := instrument.MarginManagerAddress
	size, err := e.future.ContractSize(ctx)
	if err == nil {
		var rate *big.Int
		if rate, err = e.future.FutureIMRate(ctx, engine); err == nil {
			var contract futures.Contract
			if contract, err = e.future.Contract(ctx); err == nil {
				var band futures.Band
				if band, err = e.future.Band(ctx); err == nil {
					return e.futureSidesAllow(ctx, instrument, candidate, engine, size, rate, price, amount, fee, contract.MarkPrice, band.Index)
				}
			}
		}
	}
	slog.Warn("future_margin_precheck_unreadable", "market", instrument.Symbol, "error", err.Error(),
		"taker_order_id", candidate.Taker.OrderID, "maker_order_id", candidate.Maker.OrderID)
	return true
}

func (e *Engine) futureSidesAllow(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, engine string, size, rate, price, amount, fee, mark, index *big.Int) bool {
	allowed := true
	for _, leg := range []struct {
		order orders.Order
		role  string
	}{{candidate.Taker, "taker"}, {candidate.Maker, "maker"}} {
		account, ok := new(big.Int).SetString(strings.TrimSpace(leg.order.SubaccountID), 10)
		if !ok {
			continue
		}
		surplus, err := e.future.IMSurplus(ctx, engine, account)
		if err != nil {
			slog.Warn("future_margin_precheck_unreadable", "market", instrument.Symbol, "order_id", leg.order.OrderID, "error", err.Error())
			continue
		}
		position, err := e.future.Position(ctx, account)
		if err != nil {
			slog.Warn("future_margin_precheck_unreadable", "market", instrument.Symbol, "order_id", leg.order.OrderID, "error", err.Error())
			continue
		}
		side := futureSide{Surplus: surplus, Position: position, Delta: new(big.Int).Set(amount), Fee: big.NewInt(0)}
		if leg.order.Side == orders.SideSell {
			side.Delta.Neg(side.Delta)
		}
		if leg.role == "taker" {
			side.Fee = fee
		}
		short, post := futureFillShortfall(side, size, rate, price, mark, index)
		if !short {
			e.marginRefusals.clear(leg.order)
			continue
		}
		allowed = false
		count, cancel := e.marginRefusals.refuse(leg.order)
		slog.Warn("future_fill_refused", "market", instrument.Symbol, "reason", "insufficient_margin", "role", leg.role,
			"order_id", leg.order.OrderID, "subaccount_id", leg.order.SubaccountID, "im_surplus_after", futures.Decimal(post),
			"consecutive_refusals", count)
		if !cancel {
			continue
		}
		reconcileCtx, done := detachedContext(ctx, reconciliationTimeout)
		if err := e.orders.CancelByVenue(reconcileCtx, leg.order.OrderID, CancelReasonInsufficientMargin); err != nil {
			slog.Error("future_margin_cancel_failed", "market", instrument.Symbol, "order_id", leg.order.OrderID, "error", err)
		} else {
			slog.Warn("future_order_cancelled", "market", instrument.Symbol, "reason", CancelReasonInsufficientMargin,
				"order_id", leg.order.OrderID, "subaccount_id", leg.order.SubaccountID, "refusals", count)
			e.marginRefusals.clear(leg.order)
		}
		done()
	}
	return allowed
}
