package matching

import (
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

// A crossed pair that cannot settle fails identically on every tick. Without a
// backoff the engine retries it at the full poll rate until one side expires:
// observed in production at ~980 market_events rows per minute (against a ~2/min
// baseline) for the nine minutes one such pair rested, plus an executor call and
// an on-chain simulation per attempt. Market-maker orders live about an hour, so
// the same pair between two resting quotes would repeat that for far longer.
//
// The backoff is deliberately non-destructive: it delays retries, it never
// cancels an order. A failure may well be transient (an RPC blip, a momentary
// margin shortfall), and cancelling someone's order over that would be worse
// than retrying slowly.
const (
	matchBackoffBase = 2 * time.Second
	matchBackoffCap  = 5 * time.Minute
	// Stale entries are dropped once they are this far past their retry time, so
	// the map cannot grow without bound as orders come and go.
	matchBackoffTTL = 30 * time.Minute

	// After this many consecutive failures a pair whose failure might still clear — a balance that
	// could be topped up, or an error that was not recognised — is retried only every
	// matchSlowRetryInterval rather than every matchBackoffCap until one side expires (#50).
	//
	// Past the point the doubling reaches the cap (failure 9: 2s << 8 > 5m), so a transient failure
	// still gets the whole fast schedule plus a few attempts at the cap — about 23 minutes — first.
	matchSlowRetryAfter    = 12
	matchSlowRetryInterval = 30 * time.Minute

	// A parked pair is forgotten after this. The venue signs orders for a day, so both have expired
	// by then; the entry only has to outlive them.
	matchParkTTL = 25 * time.Hour
)

type matchFailure struct {
	failures    int
	nextAttempt time.Time
	// parked: the pair can never settle as signed, so it is skipped until either order changes.
	parked      bool
	parkedAt    time.Time
	fingerprint string
}

// pairFingerprint identifies the state a parked pair was parked in. A fill on either order changes
// it, and so does anything else that re-signs or replaces an order, since the order id is part of it.
func pairFingerprint(taker orders.Order, maker orders.Order) string {
	first, second := taker, maker
	if second.OrderID < first.OrderID {
		first, second = second, first
	}
	return first.OrderID + ":" + first.FilledAmount + "|" + second.OrderID + ":" + second.FilledAmount
}

// matchBackoff tracks consecutive failures per order pair.
type matchBackoff struct {
	mu    sync.Mutex
	state map[string]*matchFailure
	now   func() time.Time
}

func newMatchBackoff() *matchBackoff {
	return &matchBackoff{state: make(map[string]*matchFailure), now: time.Now}
}

// pairKey identifies a pair independently of which side is currently the taker,
// since taker/maker can swap between ticks as orders are re-timestamped.
func pairKey(taker orders.Order, maker orders.Order) string {
	if taker.OrderID <= maker.OrderID {
		return taker.OrderID + "|" + maker.OrderID
	}
	return maker.OrderID + "|" + taker.OrderID
}

// shouldSkip reports whether this pair is still inside its backoff window.
func (b *matchBackoff) shouldSkip(taker orders.Order, maker orders.Order) bool {
	b.mu.Lock()
	defer b.mu.Unlock()

	key := pairKey(taker, maker)
	entry, ok := b.state[key]
	if !ok {
		return false
	}
	if entry.parked {
		if entry.fingerprint == pairFingerprint(taker, maker) {
			return true
		}
		// One side filled or changed since the pair was parked, so the reason may no longer hold.
		delete(b.state, key)
		return false
	}
	return b.now().Before(entry.nextAttempt)
}

// park stops retrying a pair whose settlement can never succeed as signed, until either order
// changes. It never cancels anything: both orders stay on the book and can still trade with others.
func (b *matchBackoff) park(taker orders.Order, maker orders.Order) (attempts int) {
	b.mu.Lock()
	defer b.mu.Unlock()

	now := b.now()
	key := pairKey(taker, maker)
	entry, ok := b.state[key]
	if !ok {
		entry = &matchFailure{}
		b.state[key] = entry
	}
	entry.failures++
	entry.parked = true
	entry.parkedAt = now
	entry.fingerprint = pairFingerprint(taker, maker)

	b.pruneLocked(now)
	return entry.failures
}

// recordFailure grows the pair's backoff window. Delay doubles per consecutive
// failure from matchBackoffBase up to matchBackoffCap.
func (b *matchBackoff) recordFailure(taker orders.Order, maker orders.Order) (attempts int, retryIn time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()

	now := b.now()
	key := pairKey(taker, maker)
	entry, ok := b.state[key]
	if !ok {
		entry = &matchFailure{}
		b.state[key] = entry
	}
	entry.failures++

	delay := matchBackoffBase << (entry.failures - 1)
	// Guard against the shift overflowing on a long-lived failure.
	if delay <= 0 || delay > matchBackoffCap {
		delay = matchBackoffCap
	}
	if entry.failures >= matchSlowRetryAfter {
		delay = matchSlowRetryInterval
	}
	entry.nextAttempt = now.Add(delay)

	b.pruneLocked(now)
	return entry.failures, delay
}

// clear forgets a pair, so a later failure starts from the shortest delay again.
func (b *matchBackoff) clear(taker orders.Order, maker orders.Order) {
	b.mu.Lock()
	defer b.mu.Unlock()
	delete(b.state, pairKey(taker, maker))
}

func (b *matchBackoff) pruneLocked(now time.Time) {
	for key, entry := range b.state {
		if entry.parked {
			if now.Sub(entry.parkedAt) > matchParkTTL {
				delete(b.state, key)
			}
			continue
		}
		if now.Sub(entry.nextAttempt) > matchBackoffTTL {
			delete(b.state, key)
		}
	}
}
