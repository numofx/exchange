-- A reduce-only order may only shrink the account's perp position: never open one, never flip
-- one. The venue clamps its fills to the position it tracks and cancels what is left once the
-- position is flat. Defaulting to false keeps every existing order and client unchanged.
alter table active_orders
  add column if not exists reduce_only boolean not null default false;

-- The venue's own view of each perp account's position in CHAIN units (18dp, signed; positive is
-- long the base, i.e. long naira), seeded from SubAccounts when a reduce-only order is submitted
-- and moved by every fill the venue finalizes, in the fill's own transaction. Reduce-only orders
-- are clamped against this, not against a poll, so two closes in one tick cannot both pass.
create table if not exists perp_positions (
  subaccount_id numeric(78, 0) not null,
  asset_address text not null,
  position numeric(78, 0) not null,
  updated_at timestamptz not null default now(),
  primary key (subaccount_id, asset_address)
);
