-- A post-only order must never be the aggressor. Without a flag on the row there is no way to
-- express that intent: an order that would cross is simply matched, and the submitter finds out by
-- being charged the taker fee on a fill they wanted to rest.
--
-- Defaulting to false keeps every existing order and client unchanged -- absent means "ordinary
-- order", which is what they all are today.
alter table active_orders
  add column if not exists post_only boolean not null default false;

-- The rejection check asks "is there a resting order on the opposite side this would cross?",
-- which is a top-of-book lookup per side. The existing indexes order by price for the book and the
-- matcher; this one serves the same shape for the single best opposing price, restricted to the
-- active rows the check cares about.
create index if not exists active_orders_cross_check_idx
  on active_orders (asset_address, sub_id, side, (limit_price_ticks::numeric))
  where status = 'active';
