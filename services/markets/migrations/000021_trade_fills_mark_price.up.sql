-- The mark a future fill settled against, so GET /v1/fills can report the variation margin the fill
-- settled at once: side x size x (mark - price), in cNGN. The chain emits no per-fill VM (an opening
-- fill folds the gap into the account's VM checkpoint, and VMSettled mixes it with VM accrued since),
-- so the matcher reads the mark the fill's transaction saw (FutureAsset.futureContracts at its block,
-- or the old mark of a MarkSet later in that block) and records it here.
--
-- mark_price: cNGN per USDC, an exact decimal. NULL for spot and the perp, for fills recorded before
-- this column, and when the read failed; NULL means unknown, never zero.
alter table trade_fills add column if not exists mark_price text;
