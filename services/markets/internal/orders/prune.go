package orders

import (
	"context"
	"log/slog"
	"time"
)

// defaultPruneBatch bounds how many rows one DELETE statement removes when the
// caller does not specify a batch size.
const defaultPruneBatch = 5000

// PruneTerminalOrders deletes 'cancelled' and 'expired' orders older than horizon
// and returns how many rows went away.
//
// 'filled' is never pruned: those rows are real trade history, and they are tiny
// next to the churn (market-maker requoting leaves a cancelled row per replaced
// quote — thousands a day — against a handful of fills).
//
// The delete is batched on purpose. A single unbounded DELETE over a large backlog
// writes all of its WAL in one transaction, and on a nearly-full disk that is the
// difference between a failed statement and a PANIC that takes the server down.
// Batching also keeps each statement's locks short enough not to stall order traffic.
//
// DELETE does not fire active_orders_event (that trigger is AFTER INSERT OR UPDATE),
// so pruning writes no market_events rows.
func (r *Repository) PruneTerminalOrders(ctx context.Context, horizon time.Duration, batch int) (int64, error) {
	if horizon <= 0 {
		return 0, nil
	}
	if batch <= 0 {
		batch = defaultPruneBatch
	}

	const query = `
delete from active_orders
where order_id = any (
  select order_id
  from active_orders
  where status in ('cancelled', 'expired')
    and created_at < now() - make_interval(secs => $1)
  limit $2
)
`

	var total int64
	for {
		tag, err := r.pool.Exec(ctx, query, horizon.Seconds(), batch)
		if err != nil {
			return total, mapPGError(err)
		}
		removed := tag.RowsAffected()
		total += removed
		if removed < int64(batch) {
			return total, nil
		}
		// A short pause between batches leaves room for live order traffic and lets
		// autovacuum keep up rather than letting dead tuples pile into bloat.
		select {
		case <-ctx.Done():
			return total, ctx.Err()
		case <-time.After(time.Second):
		}
	}
}

// pruneStartupDelay is how long after boot the first prune runs: short enough
// that a frequently-redeployed service still prunes, long enough to stay out of
// the way of startup work. A var so tests need not wait a real minute.
var pruneStartupDelay = time.Minute

// RunPruneLoop prunes terminal orders shortly after startup and then on a ticker
// until ctx is cancelled. A zero interval or horizon disables it. Run this in
// exactly one process — the API service — so the matcher does not compete for the
// same rows.
//
// The startup run is not optional: a ticker alone means a service redeployed more
// often than `every` never prunes at all, and deploys can easily be more frequent
// than the default hour.
func (r *Repository) RunPruneLoop(ctx context.Context, horizon time.Duration, every time.Duration, batch int, log *slog.Logger) {
	if every <= 0 || horizon <= 0 {
		return
	}
	if log == nil {
		log = slog.Default()
	}

	runOnce := func() bool {
		removed, err := r.PruneTerminalOrders(ctx, horizon, batch)
		if err != nil {
			if ctx.Err() != nil {
				return false
			}
			log.Warn("orders prune", "error", err, "rows_removed_before_error", removed)
			return true
		}
		if removed > 0 {
			log.Info("orders pruned", "rows", removed, "horizon", horizon.String())
		}
		return true
	}

	startup := time.NewTimer(pruneStartupDelay)
	defer startup.Stop()
	select {
	case <-ctx.Done():
		return
	case <-startup.C:
		if !runOnce() {
			return
		}
	}

	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if !runOnce() {
				return
			}
		}
	}
}
