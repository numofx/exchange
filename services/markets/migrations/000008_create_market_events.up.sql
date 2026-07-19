-- Real-time event pipeline (see docs/realtime-api-design.md).
-- Append-only log written by DB triggers on active_orders / trade_fills, so ANY writer
-- (cmd/api, cmd/matcher, admin tooling) produces events without app-code coupling. NOTIFY
-- carries only the seq (dodging the 8KB cap + NOTIFY's non-durability); the Hub reads the row.
--
-- IMPORTANT: this file is re-Exec'd on every service startup (the runner has no version
-- guard), so every statement here MUST be idempotent.

create table if not exists market_events (
  seq           bigserial primary key,
  market_key    text        not null,                       -- lower(asset_address) || ':' || sub_id
  channel       text        not null check (channel in ('book', 'trades', 'orders')),
  event_type    text        not null,
  owner_address text,                                        -- set for channel='orders' (private routing)
  payload       jsonb       not null,
  created_at    timestamptz not null default now()
);

-- (market, channel) range-scan by seq: powers snapshot-tail replay for a subscriber.
create index if not exists market_events_market_seq_idx
  on market_events (market_key, channel, seq);

-- private 'orders' routing by authenticated owner.
create index if not exists market_events_owner_seq_idx
  on market_events (owner_address, seq)
  where owner_address is not null;

-- supports the Hub's periodic prune: DELETE FROM market_events WHERE created_at < now() - <horizon>.
create index if not exists market_events_prune_idx
  on market_events (created_at);

-- One doorbell per appended event: NOTIFY carries the seq only. Duplicate (channel,payload)
-- notifications coalesce, but distinct seqs never do, so none are lost; the Hub reads
-- everything > last_processed_seq regardless, so a missed NOTIFY self-heals on the next one.
create or replace function markets_notify_seq() returns trigger
language plpgsql as $$
begin
  perform pg_notify('market_events', new.seq::text);
  return new;
end;
$$;

drop trigger if exists market_events_notify on market_events;
create trigger market_events_notify
  after insert on market_events
  for each row execute function markets_notify_seq();

-- active_orders INSERT/UPDATE -> a 'book' level delta (when resting size at this price
-- changed) and an owner-scoped 'orders' update (on create or any status/fill change).
-- Resting ("open") size = desired-filled while status is active/matching, else 0; the book
-- delta is new_open-old_open, so create/cancel/expire/partial-fill all fall out of one rule.
create or replace function markets_order_event() returns trigger
language plpgsql as $$
declare
  v_market   text    := lower(new.asset_address) || ':' || new.sub_id::text;
  v_new_open numeric := 0;
  v_old_open numeric := 0;
begin
  if new.status in ('active', 'matching') then
    v_new_open := new.desired_amount::numeric - new.filled_amount::numeric;
  end if;
  if tg_op = 'UPDATE' and old.status in ('active', 'matching') then
    v_old_open := old.desired_amount::numeric - old.filled_amount::numeric;
  end if;

  if v_new_open is distinct from v_old_open then
    insert into market_events (market_key, channel, event_type, owner_address, payload)
    values (
      v_market, 'book', 'level_delta', null,
      jsonb_build_object(
        'side',        new.side,
        'price_ticks', new.limit_price_ticks,
        'limit_price', new.limit_price,
        'size_delta',  (v_new_open - v_old_open)::text,
        'order_open',  v_new_open::text,
        'order_id',    new.order_id
      )
    );
  end if;

  -- OLD is NULL on INSERT; IS DISTINCT FROM is null-safe, so this is exception-free there.
  if tg_op = 'INSERT'
     or new.status is distinct from old.status
     or new.filled_amount is distinct from old.filled_amount then
    insert into market_events (market_key, channel, event_type, owner_address, payload)
    values (
      v_market, 'orders', 'order_update', lower(new.owner_address),
      jsonb_build_object(
        'order_id',       new.order_id,
        'status',         new.status,
        'side',           new.side,
        'filled_amount',  new.filled_amount,
        'desired_amount', new.desired_amount,
        'limit_price',    new.limit_price,
        'price_ticks',    new.limit_price_ticks
      )
    );
  end if;

  return new;
end;
$$;

drop trigger if exists active_orders_event on active_orders;
create trigger active_orders_event
  after insert or update on active_orders
  for each row execute function markets_order_event();

-- trade_fills INSERT -> a public 'trades' event. Routed through market_events (not just the
-- fills table) so all channels share one monotonic seq space.
create or replace function markets_trade_event() returns trigger
language plpgsql as $$
begin
  insert into market_events (market_key, channel, event_type, owner_address, payload)
  values (
    lower(new.asset_address) || ':' || new.sub_id::text,
    'trades', 'fill', null,
    jsonb_build_object(
      'trade_id',       new.trade_id,
      'price',          new.price,
      'size',           new.size,
      'aggressor_side', new.aggressor_side,
      'taker_order_id', new.taker_order_id,
      'maker_order_id', new.maker_order_id,
      'created_at',     new.created_at
    )
  );
  return new;
end;
$$;

drop trigger if exists trade_fills_event on trade_fills;
create trigger trade_fills_event
  after insert on trade_fills
  for each row execute function markets_trade_event();
