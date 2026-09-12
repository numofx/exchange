drop index if exists active_orders_cross_check_idx;
alter table active_orders
  drop column if exists post_only;
