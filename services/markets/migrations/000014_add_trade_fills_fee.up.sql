-- What each fill charged and which transaction settled it. The matcher computed the fee and the
-- executor returned the hash at match time, but neither was stored, so a fill's fee could not be
-- read back and GET /v1/fills could not report it.
--
-- taker_fee: what the taker paid, in the quote asset (USDC), as an exact decimal. Makers are never
-- charged. NULL means unknown, never zero.
-- tx_hash: the settling transaction. NULL for fills recorded before this column.
alter table trade_fills add column if not exists taker_fee text;
alter table trade_fills add column if not exists tx_hash text;

-- Backfill the fee wherever it is exactly known. Both statements only fill NULLs, so re-applying this
-- file is a no-op.
--
-- Until numofx/exchange#41 the matcher charged a constant zero. The first matcher image carrying it
-- (c05c124) was registered on ECS at 2026-09-10 20:23:23Z; the venue's fills either side of that are
-- at 11:53:56Z and 20:32:54Z, so the boundary falls cleanly between them.
update trade_fills
set taker_fee = '0'
where taker_fee is null
  and created_at < '2026-09-10 20:23:23+00';

-- Since then USDCcNGN-SPOT (this production asset) has charged 25 bps taker on the fill notional,
-- truncated to wei exactly as takerFillFee does: floor(floor(price * size * 1e18) * 25 / 10000).
-- Checked on 2026-09-13: those fees on fills 340-345 sum to 12502259541326603 wei, the exact balance
-- of fee subaccount 17. Any other market after the boundary is left unknown.
update trade_fills
set taker_fee = (div(trunc(price::numeric * size::numeric * 1000000000000000000) * 25, 10000)
                 * 0.000000000000000001)::text
where taker_fee is null
  and created_at >= '2026-09-10 20:23:23+00'
  and asset_address = '0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493';
