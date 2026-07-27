-- Supports the periodic prune of terminal orders:
--   DELETE FROM active_orders WHERE status IN ('cancelled','expired') AND created_at < now() - <horizon>
--
-- 'filled' is deliberately NOT covered: filled orders are real trade history and
-- are never pruned (they are also a rounding error by volume — market-maker
-- requoting produces thousands of cancellations per day but only a handful of fills).
create index if not exists active_orders_prune_idx
  on active_orders (created_at)
  where status in ('cancelled', 'expired');
