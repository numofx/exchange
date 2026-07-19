-- Reset previously backfilled decimal display prices so startup can recompute
-- canonical ticks with instrument-aware conversion.
alter table active_orders
  alter column limit_price_ticks drop not null;

update active_orders
set limit_price_ticks = null
where position('.' in limit_price) > 0;
