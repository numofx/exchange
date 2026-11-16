-- Fills from risk-core's OnchainBook (spec Part B): a taker walks makers' oracle-pegged splines on chain, with no
-- order and no matcher. They trade the same series as the venue, so they go on the same tape: /trades, candles, the
-- 24h stats and the public 'trades' stream read trade_fills, and a series whose volume is split across two tapes
-- reports half of it.
--
-- source: 'matching' (the matcher's fills, every row before this column) or 'book'.
-- A book row has no orders: taker_order_id and maker_order_id are '' and it never joins active_orders, so it is in
-- no owner's /fills (those are signed-order history). It carries the two subaccounts instead, the transaction and the
-- Fill log's index, which together are its identity: the indexer re-reading a block range writes nothing twice.
-- created_at is the block's time, not the time it was indexed.
--
-- Idempotent: the test suites re-apply every migration file.
alter table trade_fills add column if not exists source text not null default 'matching';
alter table trade_fills drop constraint if exists trade_fills_source_check;
alter table trade_fills add constraint trade_fills_source_check check (source in ('matching', 'book'));
alter table trade_fills add column if not exists log_index integer;
alter table trade_fills add column if not exists taker_subaccount_id numeric(78, 0);
alter table trade_fills add column if not exists maker_subaccount_id numeric(78, 0);
alter table trade_fills drop constraint if exists trade_fills_book_identity_check;
alter table trade_fills add constraint trade_fills_book_identity_check check (
  source <> 'book' or (tx_hash is not null and log_index is not null
                       and taker_subaccount_id is not null and maker_subaccount_id is not null)
);
create unique index if not exists trade_fills_book_log_idx on trade_fills (tx_hash, log_index) where source = 'book';

-- One row per TakeExecuted: what the taker asked the book for and got, the fills above summed (fee includes the
-- priority tax, which no Fill carries). filled 0 is a take that found nothing to fill.
create table if not exists book_takes (
  tx_hash            text        not null,
  log_index          integer     not null,
  book_address       text        not null,
  market_id          numeric(78, 0) not null,
  asset_address      text        not null,
  sub_id             numeric     not null,
  taker_subaccount_id numeric(78, 0) not null,
  side               text        not null check (side in ('buy', 'sell')),
  -- in the series' order units (desired_amount), like trade_fills.size
  filled             text        not null,
  -- quote per base, '' when nothing filled
  avg_price          text        not null,
  -- the quote asset, decimal
  fee                text        not null,
  fill_count         integer     not null,
  block_number       bigint      not null,
  block_time         timestamptz not null,
  primary key (tx_hash, log_index)
);
create index if not exists book_takes_taker_idx on book_takes (taker_subaccount_id, block_time desc);

-- How far the book indexer has read, per book contract.
create table if not exists book_index_cursor (
  book_address text primary key,
  block_number bigint not null,
  updated_at   timestamptz not null default now()
);

-- The public 'trades' event says which tape a fill came from. Same body as 000017 plus source.
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
      'created_at',     new.created_at,
      'tx_hash',        new.tx_hash,
      'source',         new.source
    )
  );
  return new;
end;
$$;
