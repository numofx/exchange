drop trigger if exists trade_fills_event on trade_fills;
drop trigger if exists active_orders_event on active_orders;
drop trigger if exists market_events_notify on market_events;

drop function if exists markets_trade_event();
drop function if exists markets_order_event();
drop function if exists markets_notify_seq();

drop index if exists market_events_prune_idx;
drop index if exists market_events_owner_seq_idx;
drop index if exists market_events_market_seq_idx;
drop table if exists market_events;
