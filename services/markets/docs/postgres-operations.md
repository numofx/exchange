# Postgres operations: disk, WAL, retention

Operational notes for the `markets-prod` Postgres that backs `services/markets`.
Status: current. Scope: the Railway `Postgres` service and its volume.

## Non-default server settings (NOT in this repo)

These were applied with `ALTER SYSTEM` and live in `postgresql.auto.conf` **on the
volume**, not in version control. They survive restarts and redeploys, but a volume
recreated from the Railway template comes back with the stock values:

| Setting | Stock | Ours | Why |
|---------|-------|------|-----|
| `max_wal_size` | 1024MB | 128MB | Stock exceeded the entire 500MB volume, so WAL could fill the disk on its own. |
| `min_wal_size` | 80MB | 32MB | Retains less preallocated WAL. |

Both are SIGHUP-reloadable, so restoring them needs no restart:

```sql
ALTER SYSTEM SET max_wal_size = '128MB';
ALTER SYSTEM SET min_wal_size = '32MB';
SELECT pg_reload_conf();
SELECT name, setting FROM pg_settings WHERE name IN ('max_wal_size','min_wal_size');
```

**Keep `max_wal_size` below the volume size.** When the disk fills, Postgres PANICs on
its next WAL write rather than failing the statement, and it then cannot complete crash
recovery until the volume grows — see the incident note below.

## Volume

Grown from **500MB to 5000MB** on 2026-07-27. Railway bills on used, not provisioned.
Resizing redeploys the service (brief downtime), so it is not a live-incident quick fix —
grow it *before* the disk is full, not after.

```
railway volume list                      # size + usage (may lag; cross-check with metrics)
```

## Retention

Two prunes run automatically. Both only DELETE — **the table files never shrink on their
own**, so a one-off `VACUUM FULL` is needed after any large backlog is cleared.

| Table | Horizon | Interval | Env |
|-------|---------|----------|-----|
| `market_events` | 2h | 5m | `EVENTS_PRUNE_HORIZON`, `EVENTS_PRUNE_INTERVAL` |
| `active_orders` (`cancelled`/`expired` only) | 30d | 1h | `ORDERS_PRUNE_HORIZON`, `ORDERS_PRUNE_INTERVAL`, `ORDERS_PRUNE_BATCH` |

Notes:

- `market_events`' horizon **is the WS reconnect-replay window** (`Hub.Since`). Shortening
  it to save disk directly degrades reconnect behaviour — don't, unless disk demands it.
- `filled` orders are never pruned: real trade history, and tiny next to the churn.
- The orders prune deletes in batches (`ORDERS_PRUNE_BATCH`, default 5000) so one
  statement can't write a month of WAL in a single transaction.
- Both prunes run in `cmd/api` only, so exactly one process prunes.
- `DELETE` on `active_orders` does not fire `active_orders_event` (that trigger is
  AFTER INSERT OR UPDATE), so pruning writes no `market_events` rows.

## Reclaiming space

`VACUUM FULL` rewrites the table, so it needs free space roughly equal to the *new* size
and takes an `AccessExclusiveLock`. Delete first, then compact, and always bound the lock:

```sh
PGOPTIONS='-c lock_timeout=20s' psql "$DATABASE_URL" -c "vacuum full market_events;"
```

Do this when write volume is low. On a nearly-full disk, `VACUUM FULL` on a *large* table
can fail for lack of space — delete the bulk of the rows first so the rewrite is small.

## Diagnosing disk growth

```sql
-- biggest relations, with dead-tuple counts
SELECT c.relname,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total,
       s.n_live_tup, s.n_dead_tup, s.n_tup_upd
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind = 'r' AND n.nspname = 'public'
ORDER BY pg_total_relation_size(c.oid) DESC;

-- WAL on disk
SELECT count(*) AS files, pg_size_pretty(sum(size)) FROM pg_ls_waldir();

-- write-amplification check: order_update should NOT dwarf level_delta
SELECT channel, event_type, count(*)
FROM market_events WHERE created_at > now() - interval '1 minute'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

That last query is the canary. A healthy quiet book writes single-digit events per
minute. If `orders/order_update` is in the thousands per minute while `book/level_delta`
stays near zero, something is churning order rows without trading — the 2026-07-22..27
failure mode below.

## Incident: 2026-07-27 disk-full PANIC

`n_tup_upd` on `active_orders` had reached 14.9M against 332 lifetime trades. Cause:
`AcquireMatchCandidate` reserved the best bid/ask (status → `matching`, committed) *before*
checking whether they crossed, and the engine then released them — ~4 writes per poll tick
per market, each amplified into a `market_events` row by the trigger. Roughly 1,920
events/minute on a book that never traded.

Two aggravating factors: `active_orders` had no retention at all (37k stale `cancelled`
rows), and `max_wal_size` (1024MB) exceeded the volume (500MB).

At 100% full, a bulk `DELETE` PANICked the server and it could not finish crash recovery
until the volume was grown — about 30 minutes of downtime.

Fixes: cross-check moved before the reserve (`orders.Crosses`, commit `e9834b1`), terminal
orders now pruned (commit `617fe45`), volume at 5GB, WAL capped. Measured after: ~2
events/minute.

### Matcher liveness is now quiet by design

The per-tick `acquire_match_candidate_*` / `lock_best_by_side_*` logs were demoted to
`Debug`, so a healthy matcher on a quiet book logs **nothing**. Silence is not death.
To confirm it's ticking, look for a non-self connection `idle in transaction` running
`lockBestBySide`'s scan — it flickers at the poll rate, so sample a few times:

```sql
SELECT pid, state, query FROM pg_stat_activity
WHERE datname = 'railway' AND pid <> pg_backend_pid()
  AND query ILIKE '%for update%' AND query ILIKE '%active_orders%';
```
