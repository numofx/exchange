# Real-time market data: event pipeline + WebSocket protocol

Design for the matcher → API event transport and the client-facing WebSocket API.
Status: proposal. Scope: `services/markets` (`cmd/api`, `cmd/matcher`, Postgres).

## Problem

`cmd/api` (REST, chi) and `cmd/matcher` (matching engine) are **separate processes**
sharing one Postgres pool. State changes that clients want in real time originate in
**both**:

| Event | Producer | Today's storage |
|-------|----------|-----------------|
| order placed | `cmd/api` `POST /v1/orders` | `active_orders` INSERT |
| order cancelled | `cmd/api` `POST /v1/orders/cancel` | `active_orders` UPDATE status |
| order matched / filled | `cmd/matcher` finalize | `active_orders` UPDATE + `trade_fills` INSERT |
| order expired | sweep | `active_orders` UPDATE status |

A WS server living in `cmd/api` cannot see the matcher's in-memory state, so it needs a
**stream of events out of Postgres** that is (a) producer-agnostic, (b) ordered per market,
and (c) replayable so a reconnecting client can catch up without a gap.

## Decision: trigger → append-only log → `NOTIFY(seq)` → in-process fan-out

```
 active_orders / trade_fills  --AFTER INSERT/UPDATE trigger-->  market_events (append-only, bigserial seq)
                                                                     |  pg_notify('market_events', seq)
                                                                     v
 cmd/api:  single LISTEN conn --> Hub --> per-connection subscriptions --> WS clients
                                   ^                                         (snapshot + deltas)
                                   +-- on notify: SELECT * FROM market_events WHERE seq > last_seq
```

Three properties, three reasons:

1. **DB triggers emit the events, not app code.** Any writer (`cmd/api` OR `cmd/matcher`,
   or a future admin tool) produces events for free — no risk of one code path forgetting
   to publish. The matcher stays unaware the WS layer exists.
2. **An append-only `market_events` table is the source of truth, `NOTIFY` is just a
   doorbell.** `NOTIFY` payloads are capped at 8000 bytes and are **not** durable — a
   client (or the API's own LISTEN connection) that misses a notification has no replay.
   So the notification carries **only the sequence number**; the hub reads the actual row
   from the table. This sidesteps the size cap and makes every event durable + replayable.
3. **Fan-out is in-process.** One `LISTEN` connection per `cmd/api` instance feeds an
   in-memory `Hub` that dispatches to subscribers. No Redis/NATS needed at current scale.
   (Scale-out path noted at the end.)

### Why not the alternatives

- **`LISTEN`/`NOTIFY` with the full payload in the notification** — hits the 8KB cap on
  snapshots and drops events silently on any connection blip. No catch-up.
- **Clients poll REST** — no push, and hammers the DB; defeats the point.
- **Redis pub/sub now** — extra infra to run and secure for zero benefit until we run
  multiple `cmd/api` replicas. Postgres is already in the hot path.
- **Debezium/logical replication** — heavyweight; overkill for one service's tables.

## Schema

```sql
-- migrations/000008_create_market_events.up.sql
create table if not exists market_events (
  seq          bigserial primary key,
  market_key   text        not null,             -- lower(asset_address) || ':' || sub_id
  channel      text        not null check (channel in ('book','trades','orders')),
  event_type   text        not null,             -- see catalog below
  owner_address text,                            -- set for channel='orders' (private routing)
  payload      jsonb       not null,
  created_at   timestamptz not null default now()
);
create index market_events_seq_idx        on market_events (seq);
create index market_events_market_seq_idx on market_events (market_key, seq);
create index market_events_owner_seq_idx  on market_events (owner_address, seq)
  where owner_address is not null;
```

Retention: `market_events` is a rolling log, not history of record (that's `trade_fills` /
`active_orders`). Prune with a periodic `DELETE FROM market_events WHERE created_at < now() -
interval '2 hours'`. The prune horizon defines the maximum reconnect gap a client can replay;
older reconnects get a fresh snapshot instead (see resume).

### Trigger emit points

```sql
-- fires on active_orders INSERT/UPDATE -> emits a 'book' event, and an 'orders' event
-- (owner-scoped). Emits 'trades' from a separate trigger on trade_fills INSERT.
-- Payload is a compact delta, NOT the whole book:
--   book:   {side, price_ticks, size_delta, order_count_delta, resulting_size}
--   orders: {order_id, status, filled_amount, ...}
--   trades: {trade_id, price, size, aggressor_side, taker_order_id, maker_order_id}
```

Emit the `book` delta from the order row's before/after so the hub never recomputes the book
from scratch on a hot path. `trade_fills.trade_id` doubles as a natural per-trade cursor, but
route it through `market_events` too so all channels share one monotonic `seq` space.

## Client-facing WebSocket protocol

Endpoint: `GET /v1/ws` (chi route, upgraded via **`coder/websocket`**). JSON text frames.

### Channels

| Channel | Access | Snapshot | Deltas |
|---------|--------|----------|--------|
| `book` | public | top-N bids/asks (matches `GET /v1/book`) | price-level size changes |
| `trades` | public | last N fills (matches `GET /v1/trades`) | one per new fill |
| `orders` | **private** (auth) | caller's open orders | status/fill changes for caller |
| `ticker` | public (phase 2) | mark/last/24h | on mark update — *depends on the setMarkPrice cadence job* |

### Messages

Client → server:
```jsonc
{"op":"subscribe","channel":"book","market":"cNGN-SEP16","since_seq":10423}  // since_seq optional
{"op":"unsubscribe","channel":"book","market":"cNGN-SEP16"}
{"op":"auth","token":"<signed>"}   // required before subscribing to 'orders'
{"op":"ping"}
```

Server → client:
```jsonc
{"channel":"book","market":"cNGN-SEP16","type":"snapshot","seq":10440,"data":{...}}
{"channel":"book","market":"cNGN-SEP16","type":"update","seq":10441,"data":{...}}
{"type":"pong"}
{"type":"error","code":"resume_too_old","message":"resubscribe for a fresh snapshot"}
```

Every server message on a market carries the `seq` it reflects. **`snapshot` is taken at a
specific `seq`; every following `update` is strictly `seq+1…`**, so the client always knows
its position and can detect a gap.

### Subscribe / snapshot consistency

The classic race is "snapshot vs. live deltas." Resolve it in the hub, not the client:

1. On `subscribe`, register the connection for `(channel, market)` and start **buffering**
   live deltas.
2. Read the snapshot **inside the same read** that captures `snapshot_seq = max(seq)` for
   that market (single DB round-trip / transaction).
3. Send `snapshot@snapshot_seq`, then flush buffered deltas **dropping any with
   `seq <= snapshot_seq`**, then go live.

### Resume after reconnect

- Client reconnects and sends `subscribe` with `since_seq = <last seq it saw>`.
- Hub: if `since_seq >= min(seq)` still in `market_events`, replay `seq > since_seq` then go
  live — **no snapshot needed, no gap**.
- If `since_seq` is older than the prune horizon (or unknown), reply
  `error: resume_too_old` and send a fresh `snapshot`. Client discards local state.

This is why `NOTIFY` carrying only the seq matters: durability + replay live in the table,
not the notification.

### Auth (private `orders` channel)

Public channels need no auth. `orders` is per-owner: the client proves control of
`owner_address` via a short-lived signed token (EIP-712 "login" or an issued API key —
decide alongside the REST auth work). The hub routes `orders` events by
`market_events.owner_address`; a connection only receives rows matching its authenticated
address. Never broadcast one owner's order events to another.

### Backpressure & liveness

- Per-connection bounded send buffer. On overflow (slow consumer): drop the connection with
  `error: slow_consumer`; client reconnects and resumes via `since_seq`. Never block the Hub
  fan-out on one slow socket.
- Heartbeat: server ping every 15s; drop after two missed pongs. `coder/websocket` has
  read/write deadlines — use them.
- The Hub's single `LISTEN` connection is itself a failure point: on its drop, reconnect and
  **catch up** with `SELECT … WHERE seq > last_processed_seq` before resuming live, so a
  blip in the API's own DB connection can't lose events. A low-frequency reconcile poll
  (e.g. every 5s, `max(seq)`) backstops missed `NOTIFY`s.

## Sequencing / correctness invariants

1. `seq` is globally monotonic (single `bigserial`); per-market ordering is the subsequence
   filtered by `market_key`. Clients track `seq` **per (channel, market)**.
2. Snapshot at `S` ⇒ first live delta the client keeps is `> S`; a received `seq` that skips
   a value ⇒ client must resume/resnapshot.
3. A fill emits, atomically from the matcher's finalize txn, all of: `trades` (new fill),
   `book` (maker/taker size decrements), `orders` (both parties' status/fill) — one DB
   transaction ⇒ one contiguous `seq` block ⇒ no client sees a trade without the matching
   book/order deltas.

## Build order (once this is approved)

1. Migration `000008_create_market_events` + triggers on `active_orders` / `trade_fills`.
2. `internal/events`: `Hub` (LISTEN loop, catch-up, per-conn subscriptions, prune job).
3. `internal/api`: `GET /v1/ws` handler (`coder/websocket`), subscribe/auth/resume, snapshot
   readers reusing the existing `ListBook` / trades queries.
4. Wire heartbeats, backpressure, metrics (subscribers/channel, events/s, replay count,
   dropped-slow-consumers).
5. `ticker` channel after the `setMarkPrice` cadence job exists.

## Scale-out (later, not now)

Multiple `cmd/api` replicas each hold their own `LISTEN` + Hub — `NOTIFY` fan-outs to all
listeners, so this already works horizontally for **fan-out**. The only shared state is
Postgres. Swap `market_events`+`NOTIFY` for Redis Streams / NATS JetStream only if
`NOTIFY` throughput or prune churn becomes a bottleneck; the client protocol above is
transport-agnostic and would not change.
