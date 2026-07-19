package events

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/numofx/matching-backend/internal/config"
)

// drainBatch bounds one SELECT of the log so a large backlog can't build an unbounded slice.
const drainBatch = 1000

// Sub is a live subscription. The reader ranges over Events(); a closed Done() means the Hub
// dropped it (slow consumer or shutdown) and the client should reconnect and resume via since_seq.
type Sub struct {
	filter  Filter
	ch      chan Event
	done    chan struct{}
	dropped sync.Once
}

// Events is the live delivery stream. Every Event carries its Seq so the reader can dedup
// against a snapshot boundary and detect gaps.
func (s *Sub) Events() <-chan Event { return s.ch }

// Done is closed when the Hub drops this subscription.
func (s *Sub) Done() <-chan struct{} { return s.done }

func (s *Sub) drop() { s.dropped.Do(func() { close(s.done) }) }

// Hub tails market_events and fans out to Subs. One Hub per cmd/api process holds a single
// LISTEN connection; multiple processes each hold their own, so fan-out scales horizontally
// with Postgres as the only shared state.
type Hub struct {
	pool         *pgxpool.Pool
	log          *slog.Logger
	bufSize      int
	pruneHorizon time.Duration
	pruneEvery   time.Duration
	reconcile    time.Duration

	mu      sync.RWMutex
	subs    map[*Sub]struct{}
	lastSeq int64 // highest seq dispatched; advanced only forward
}

// NewHub builds a Hub from config. Call Run to start it.
func NewHub(pool *pgxpool.Pool, cfg config.Config, log *slog.Logger) *Hub {
	if log == nil {
		log = slog.Default()
	}
	buf := cfg.EventsSubBuffer
	if buf <= 0 {
		buf = 256
	}
	return &Hub{
		pool:         pool,
		log:          log,
		bufSize:      buf,
		pruneHorizon: cfg.EventsPruneHorizon,
		pruneEvery:   cfg.EventsPruneInterval,
		reconcile:    cfg.EventsReconcileInterval,
		subs:         make(map[*Sub]struct{}),
	}
}

// Subscribe registers a live subscriber. Register BEFORE reading a snapshot: the Hub buffers
// every subsequent event, so nothing committed between subscribe and snapshot is lost (the
// reader drops the overlap by seq). Always pair with Unsubscribe.
func (h *Hub) Subscribe(f Filter) (*Sub, bool) {
	if !f.valid() {
		return nil, false
	}
	s := &Sub{filter: f, ch: make(chan Event, h.bufSize), done: make(chan struct{})}
	h.mu.Lock()
	h.subs[s] = struct{}{}
	h.mu.Unlock()
	return s, true
}

// Unsubscribe removes a subscriber and signals Done.
func (h *Hub) Unsubscribe(s *Sub) {
	h.remove(s)
	s.drop()
}

func (h *Hub) remove(s *Sub) {
	h.mu.Lock()
	delete(h.subs, s)
	h.mu.Unlock()
}

// SubscriberCount is for health/metrics.
func (h *Hub) SubscriberCount() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subs)
}

// Run owns the LISTEN loop, catch-up drains, the reconcile backstop, and the prune job until
// ctx is cancelled. It reconnects on connection loss without losing events (drain resumes
// from lastSeq).
func (h *Hub) Run(ctx context.Context) error {
	if err := h.initSeq(ctx); err != nil {
		return err
	}
	go h.pruneLoop(ctx)

	for ctx.Err() == nil {
		if err := h.listen(ctx); err != nil && ctx.Err() == nil {
			h.log.Warn("events listen connection lost; reconnecting", "error", err)
			select {
			case <-ctx.Done():
			case <-time.After(time.Second):
			}
		}
	}
	return ctx.Err()
}

// initSeq starts the Hub live at the current tail so a fresh process doesn't replay all
// history to zero subscribers. Reconnects keep lastSeq so the gap is caught up instead.
func (h *Hub) initSeq(ctx context.Context) error {
	var seq int64
	if err := h.pool.QueryRow(ctx, `select coalesce(max(seq), 0) from market_events`).Scan(&seq); err != nil {
		return err
	}
	h.mu.Lock()
	h.lastSeq = seq
	h.mu.Unlock()
	return nil
}

func (h *Hub) listen(ctx context.Context) error {
	conn, err := h.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()

	if _, err := conn.Exec(ctx, "listen "+pgChannel); err != nil {
		return err
	}
	// Catch up anything appended while we were not listening (covers a missed NOTIFY across
	// a reconnect) before going live.
	if err := h.drain(ctx); err != nil {
		return err
	}

	// WaitForNotification blocks the dedicated conn, so run it in a goroutine and coalesce
	// wakeups into a 1-deep channel; the select below also fires a periodic reconcile drain.
	notifs := make(chan struct{}, 1)
	errc := make(chan error, 1)
	go func() {
		for {
			if _, werr := conn.Conn().WaitForNotification(ctx); werr != nil {
				errc <- werr
				return
			}
			select {
			case notifs <- struct{}{}:
			default:
			}
		}
	}()

	ticker := time.NewTicker(h.reconcile)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-errc:
			return err
		case <-ticker.C:
			if err := h.drain(ctx); err != nil {
				h.log.Warn("events reconcile drain", "error", err)
			}
		case <-notifs:
			if err := h.drain(ctx); err != nil {
				h.log.Warn("events notify drain", "error", err)
			}
		}
	}
}

// drain reads every event past lastSeq in seq order and dispatches it, looping until the log
// is exhausted. Idempotent and safe to call from both the notify and reconcile paths.
func (h *Hub) drain(ctx context.Context) error {
	for {
		h.mu.RLock()
		last := h.lastSeq
		h.mu.RUnlock()

		rows, err := h.pool.Query(ctx,
			`select seq, market_key, channel, event_type, coalesce(owner_address, ''), payload, created_at
			   from market_events where seq > $1 order by seq asc limit $2`, last, drainBatch)
		if err != nil {
			return err
		}
		batch, maxSeq, err := scanEvents(rows)
		if err != nil {
			return err
		}
		if len(batch) == 0 {
			return nil
		}
		h.dispatch(batch)

		h.mu.Lock()
		if maxSeq > h.lastSeq {
			h.lastSeq = maxSeq
		}
		h.mu.Unlock()

		if len(batch) < drainBatch {
			return nil
		}
	}
}

// dispatch delivers a batch to matching subscribers, non-blocking. A full buffer means a slow
// consumer: drop it (client reconnects and resumes) rather than stall the whole fan-out.
func (h *Hub) dispatch(batch []Event) {
	h.mu.RLock()
	subs := make([]*Sub, 0, len(h.subs))
	for s := range h.subs {
		subs = append(subs, s)
	}
	h.mu.RUnlock()

	for _, e := range batch {
		for _, s := range subs {
			select {
			case <-s.done:
				continue
			default:
			}
			if !s.filter.matches(e) {
				continue
			}
			select {
			case s.ch <- e:
			default:
				h.log.Warn("events slow consumer dropped", "channel", s.filter.Channel, "market", s.filter.Market)
				h.remove(s)
				s.drop()
			}
		}
	}
}

// Since returns log rows after afterSeq matching f, in seq order, for reconnect replay. It
// filters in SQL to hit the (market,channel,seq) / (owner,seq) indexes.
func (h *Hub) Since(ctx context.Context, f Filter, afterSeq int64, limit int) ([]Event, error) {
	if !f.valid() {
		return nil, nil
	}
	if limit <= 0 || limit > drainBatch {
		limit = drainBatch
	}
	var (
		rows pgx.Rows
		err  error
	)
	if f.Channel == ChannelOrders {
		rows, err = h.pool.Query(ctx,
			`select seq, market_key, channel, event_type, coalesce(owner_address, ''), payload, created_at
			   from market_events
			  where channel = 'orders' and owner_address = $1 and seq > $2
			    and ($3 = '' or market_key = $3)
			  order by seq asc limit $4`, f.Owner, afterSeq, f.Market, limit)
	} else {
		rows, err = h.pool.Query(ctx,
			`select seq, market_key, channel, event_type, coalesce(owner_address, ''), payload, created_at
			   from market_events
			  where channel = $1 and market_key = $2 and seq > $3
			  order by seq asc limit $4`, f.Channel, f.Market, afterSeq, limit)
	}
	if err != nil {
		return nil, err
	}
	batch, _, err := scanEvents(rows)
	return batch, err
}

// LatestSeq is the current tail; use it as a snapshot boundary.
func (h *Hub) LatestSeq(ctx context.Context) (int64, error) {
	var seq int64
	err := h.pool.QueryRow(ctx, `select coalesce(max(seq), 0) from market_events`).Scan(&seq)
	return seq, err
}

// OldestSeq is the earliest still-retained seq; a since_seq below it can't be fully replayed,
// so the reader must fall back to a fresh snapshot.
func (h *Hub) OldestSeq(ctx context.Context) (int64, error) {
	var seq int64
	err := h.pool.QueryRow(ctx, `select coalesce(min(seq), 0) from market_events`).Scan(&seq)
	return seq, err
}

func (h *Hub) pruneLoop(ctx context.Context) {
	if h.pruneEvery <= 0 || h.pruneHorizon <= 0 {
		return
	}
	ticker := time.NewTicker(h.pruneEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			tag, err := h.pool.Exec(ctx,
				`delete from market_events where created_at < now() - make_interval(secs => $1)`,
				h.pruneHorizon.Seconds())
			if err != nil {
				h.log.Warn("events prune", "error", err)
				continue
			}
			if n := tag.RowsAffected(); n > 0 {
				h.log.Info("events pruned", "rows", n, "horizon", h.pruneHorizon.String())
			}
		}
	}
}

func scanEvents(rows pgx.Rows) ([]Event, int64, error) {
	defer rows.Close()
	var (
		out    []Event
		maxSeq int64
	)
	for rows.Next() {
		var (
			e       Event
			payload []byte
		)
		if err := rows.Scan(&e.Seq, &e.MarketKey, &e.Channel, &e.EventType, &e.OwnerAddress, &payload, &e.CreatedAt); err != nil {
			return nil, 0, err
		}
		e.Payload = json.RawMessage(payload)
		out = append(out, e)
		if e.Seq > maxSeq {
			maxSeq = e.Seq
		}
	}
	return out, maxSeq, rows.Err()
}
