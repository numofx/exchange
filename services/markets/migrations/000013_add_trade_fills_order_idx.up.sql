-- Serves the per-order fill total GET /v1/orders reports (filled_quote): the sum of a order's fills,
-- whichever side of the trade it was on. trade_fills is otherwise indexed only by market and time,
-- so each history row would scan the table.
create index if not exists trade_fills_taker_order_idx on trade_fills (taker_order_id);
create index if not exists trade_fills_maker_order_idx on trade_fills (maker_order_id);
