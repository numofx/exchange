alter table active_orders
  drop constraint if exists active_orders_status_check;

alter table active_orders
  add constraint active_orders_status_check
  check (status in ('active', 'matching', 'filled', 'cancelled', 'expired'));
