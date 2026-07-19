create table if not exists trade_fills (
  trade_id bigserial primary key,
  asset_address text not null,
  sub_id numeric not null,
  price text not null,
  size text not null,
  aggressor_side text not null check (aggressor_side in ('buy', 'sell')),
  taker_order_id text not null,
  maker_order_id text not null,
  created_at timestamptz not null default now()
);

create index if not exists trade_fills_market_time_idx
  on trade_fills (asset_address, sub_id, created_at desc, trade_id desc);
