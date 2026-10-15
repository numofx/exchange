-- The reduce-only position ledger keys a position by its series as well as its asset: a dated
-- future's positions are SubAccounts balances of (FutureAsset, expiry), and two series of one
-- FutureAsset are different positions. The perp's balances are sub id 0, which every existing row
-- takes, so the perp ledger is unchanged.
alter table perp_positions add column if not exists sub_id numeric(78, 0) not null default 0;
alter table perp_positions drop constraint if exists perp_positions_pkey;
alter table perp_positions add primary key (subaccount_id, asset_address, sub_id);
