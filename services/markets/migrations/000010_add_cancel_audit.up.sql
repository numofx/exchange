-- A cancel used to leave no trace on the row: status flipped to 'cancelled', but nothing recorded
-- when, why, or at whose request. Read back through GetOrderStatusSnapshot the fields were faked
-- ('' and created_at), so /v1/orders/{id} could never tell a cancel apart from an expiry after the
-- fact — the two look identical once the order is off the book. These columns give the cancel an
-- auditable record, which is also the only way to detect a cancel that should not have happened.
alter table active_orders
  add column if not exists cancelled_at  timestamptz,
  add column if not exists cancel_reason text,
  add column if not exists cancelled_by  text;
