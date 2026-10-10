-- Deposits of more than one asset (cNGN as well as USDC cash). Rows from before this name none: every one of them is
-- a deposit of the USDC cash asset, the only one accepted then, and markets-service reads an empty asset that way.
alter table deposits add column if not exists asset text;
