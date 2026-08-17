alter table active_orders
  drop column if exists cancelled_at,
  drop column if exists cancel_reason,
  drop column if exists cancelled_by;
