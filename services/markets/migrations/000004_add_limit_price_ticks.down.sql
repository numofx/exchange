drop index if exists active_orders_book_ticks_idx;

alter table active_orders
  drop column if exists limit_price_ticks;
