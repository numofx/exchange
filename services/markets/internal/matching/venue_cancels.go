package matching

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// A parked pair (a settlement revert that can never succeed as signed) is skipped, not cancelled, so
// the book walks past it. But the order at fault stays live at the top of the book as depth nothing
// can fill, and every new counterparty crosses it once and parks against it. The order every such
// failure shares is the one at fault: parked against parkCancelAfter distinct counterparty accounts,
// it is cancelled. Counting accounts rather than orders means wiping a resting quote takes that many
// funded accounts, and the alert below says when anyone tries.
const (
	parkCancelAfter = 3
	parkTrackTTL    = 25 * time.Hour

	CancelReasonRepeatedPermanentRevert = "repeated_permanent_revert"
)

type parkedOrder struct {
	counterparties map[string]struct{}
	lastSeen       time.Time
}

// parkTracker counts, per order, the distinct counterparty accounts it has been parked against.
type parkTracker struct {
	mu     sync.Mutex
	orders map[string]*parkedOrder
	now    func() time.Time
}

func newParkTracker() *parkTracker {
	return &parkTracker{orders: make(map[string]*parkedOrder), now: time.Now}
}

// record notes a parked pair and returns the legs ("taker", "maker") whose count reached the limit.
func (p *parkTracker) record(candidate orders.MatchCandidate) []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	for id, entry := range p.orders {
		if now.Sub(entry.lastSeen) > parkTrackTTL {
			delete(p.orders, id)
		}
	}
	var due []string
	for _, leg := range []struct {
		role         string
		order, other orders.Order
	}{{"taker", candidate.Taker, candidate.Maker}, {"maker", candidate.Maker, candidate.Taker}} {
		entry, ok := p.orders[leg.order.OrderID]
		if !ok {
			entry = &parkedOrder{counterparties: make(map[string]struct{})}
			p.orders[leg.order.OrderID] = entry
		}
		entry.lastSeen = now
		entry.counterparties[counterpartyKey(leg.other)] = struct{}{}
		if len(entry.counterparties) >= parkCancelAfter {
			due = append(due, leg.role)
		}
	}
	return due
}

func (p *parkTracker) forget(orderID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	delete(p.orders, orderID)
}

// counterpartyKey is the account behind an order, or the order itself when it names none.
func counterpartyKey(order orders.Order) string {
	if account := strings.TrimSpace(order.SubaccountID); account != "" {
		return "account:" + account
	}
	return "order:" + order.OrderID
}

func legOrder(candidate orders.MatchCandidate, role string) orders.Order {
	if role == "maker" {
		return candidate.Maker
	}
	return candidate.Taker
}

// cancelForVenue cancels each named leg with the reason, logs it and counts it for the alert. A leg
// already done is not an error; one that cannot be cancelled is left to the next tick, which finds the
// same fault again.
func (e *Engine) cancelForVenue(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, legs []string, reason string, cause error) {
	reconcileCtx, cancel := detachedContext(ctx, reconciliationTimeout)
	defer cancel()
	for _, role := range legs {
		order := legOrder(candidate, role)
		err := e.orders.CancelByVenue(reconcileCtx, order.OrderID, reason)
		if err != nil && !errors.Is(err, orders.ErrNotFound) {
			slog.Error("venue_cancel_failed", "market", instrument.Symbol, "reason", reason, "role", role,
				"order_id", order.OrderID, "error", err)
			continue
		}
		if e.parks != nil {
			e.parks.forget(order.OrderID)
		}
		slog.Warn("venue_order_cancelled",
			"market", instrument.Symbol,
			"reason", reason,
			"role", role,
			"order_id", order.OrderID,
			"subaccount_id", order.SubaccountID,
			"taker_order_id", candidate.Taker.OrderID,
			"maker_order_id", candidate.Maker.OrderID,
			"error", short(cause),
		)
		e.cancelAlerts.Cancelled(instrument.Symbol, reason)
	}
}

// venueCancelAlerter posts when the venue's own cancels of unsettleable orders become a stream. A
// handful is expected (the switch to a market's fixed unit cancels the orders still at the old one);
// cancelAlertThreshold within cancelAlertWindow means a bug or someone probing. At most one post per
// window, with the counts by market and reason.
const (
	cancelAlertThreshold = 10
	cancelAlertWindow    = time.Hour
)

type venueCancel struct {
	at     time.Time
	market string
	reason string
}

type venueCancelAlerter struct {
	url  string
	now  func() time.Time
	post func(ctx context.Context, url, text string) error

	mu          sync.Mutex
	recent      []venueCancel
	lastAlertAt time.Time
}

func newVenueCancelAlerter(url string) *venueCancelAlerter {
	return &venueCancelAlerter{url: strings.TrimSpace(url), now: time.Now, post: postAlert}
}

// Cancelled records one venue cancel and posts if the window has reached the threshold.
func (a *venueCancelAlerter) Cancelled(market, reason string) {
	if a == nil {
		return
	}
	a.mu.Lock()
	now := a.now()
	a.recent = append(a.recent, venueCancel{at: now, market: market, reason: reason})
	kept := a.recent[:0]
	for _, c := range a.recent {
		if now.Sub(c.at) < cancelAlertWindow {
			kept = append(kept, c)
		}
	}
	a.recent = kept
	var text string
	if len(a.recent) >= cancelAlertThreshold && (a.lastAlertAt.IsZero() || now.Sub(a.lastAlertAt) >= cancelAlertWindow) {
		a.lastAlertAt = now
		text = a.summaryLocked()
	}
	a.mu.Unlock()
	if text == "" || a.url == "" {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := a.post(ctx, a.url, text); err != nil {
			slog.Error("venue_cancel_alert_failed", "error", err)
		}
	}()
}

func (a *venueCancelAlerter) summaryLocked() string {
	counts := map[string]int{}
	for _, c := range a.recent {
		counts[c.market+" "+c.reason]++
	}
	keys := make([]string, 0, len(counts))
	for key := range counts {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	lines := make([]string, 0, len(keys))
	for _, key := range keys {
		lines = append(lines, fmt.Sprintf("%s: %d", key, counts[key]))
	}
	return fmt.Sprintf("NUMO VENUE CANCELLING UNSETTLEABLE ORDERS\n%d orders cancelled by the matcher in the last hour (unmatchable signatures or repeated permanent reverts):\n%s\nA bug in a client's signing, or someone probing the book. Check venue_order_cancelled in the matcher log.",
		len(a.recent), strings.Join(lines, "\n"))
}
