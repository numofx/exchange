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
)

type matchFailure struct {
	failures    int
	nextAttempt time.Time
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

	entry, ok := b.state[pairKey(taker, maker)]
	if !ok {
		return false
	}
	return b.now().Before(entry.nextAttempt)
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
		if now.Sub(entry.nextAttempt) > matchBackoffTTL {
			delete(b.state, key)
		}
	}
}
