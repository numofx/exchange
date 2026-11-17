-- Each matcher fill is checked on chain after the fact. execution-service answers before the transaction is mined
-- (WAIT_FOR_RECEIPT=false), so a fill is recorded on a broadcast; a transaction that then reverts, is replaced, or is
-- never mined left a fill that never happened (2026-11-16 23:57, trade 547, voided by hand).
--
-- settlement: 'pending' for a matcher fill recorded with its transaction, 'confirmed' once its receipt succeeded. NULL
-- for book fills (read from mined logs), fills recorded without a transaction, and every fill before this column.
-- A fill proven not to have settled is moved to trade_fills_voided (the row as it was, when and why) and its orders
-- put back (matching/settlement_verifier.go).
--
-- Idempotent: the test suites re-apply every migration file.
alter table trade_fills add column if not exists settlement text;
alter table trade_fills drop constraint if exists trade_fills_settlement_check;
alter table trade_fills add constraint trade_fills_settlement_check check (settlement is null or settlement in ('pending', 'confirmed'));
create index if not exists trade_fills_settlement_pending_idx on trade_fills (trade_id) where settlement = 'pending';

create table if not exists trade_fills_voided (like trade_fills);
alter table trade_fills_voided add column if not exists voided_at timestamptz not null default now();
alter table trade_fills_voided add column if not exists void_reason text not null default '';
