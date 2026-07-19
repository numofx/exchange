alter table active_orders
  add column if not exists limit_price_ticks text;

-- Seed only already-canonical integer prices in SQL. Decimal prices are
-- instrument-aware and must be converted using the app registry/tick size.
update active_orders
set limit_price_ticks = limit_price
where limit_price_ticks is null
  and limit_price ~ '^[0-9]+$';

create index if not exists active_orders_book_ticks_idx
  on active_orders (asset_address, sub_id, side, status, ((limit_price_ticks::numeric)), created_at);
