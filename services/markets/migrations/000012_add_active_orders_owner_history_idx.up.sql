-- Serves GET /v1/orders: one owner's orders in every status, newest first, paged on
-- (created_at, order_id).
--
-- The unique (owner_address, nonce) index narrows to the owner but not in time order, so an owner
-- with a long history would be sorted in full for every page. owner_address is lowercased by the
-- API before insert, so the raw column is the lookup key.
create index if not exists active_orders_owner_history_idx
  on active_orders (owner_address, created_at desc, order_id desc);
