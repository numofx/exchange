drop table if exists trade_fills_voided;
drop index if exists trade_fills_settlement_pending_idx;
alter table trade_fills drop constraint if exists trade_fills_settlement_check;
alter table trade_fills drop column if exists settlement;
