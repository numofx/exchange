create table if not exists active_orders (
  order_id text primary key,
  owner_address text not null,
  signer_address text not null,
  subaccount_id numeric not null,
  recipient_id numeric not null,
  nonce numeric not null,
  side text not null check (side in ('buy', 'sell')),
  asset_address text not null,
  sub_id numeric not null,
  desired_amount text not null,
  filled_amount text not null default '0',
  limit_price text not null,
  worst_fee text not null,
  expiry numeric not null,
  action_json jsonb not null,
  signature text not null,
  status text not null check (status in ('active', 'filled', 'cancelled', 'expired')),
  created_at timestamptz not null default now()
);

create unique index if not exists active_orders_owner_nonce_idx
  on active_orders (owner_address, nonce);

create index if not exists active_orders_book_idx
  on active_orders (asset_address, sub_id, side, status, limit_price, created_at);
