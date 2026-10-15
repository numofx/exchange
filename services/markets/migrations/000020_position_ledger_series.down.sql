-- Back to one position per (account, asset): the futures rows go, the perp's (sub id 0) stay.
delete from perp_positions where sub_id <> 0;
alter table perp_positions drop constraint if exists perp_positions_pkey;
alter table perp_positions add primary key (subaccount_id, asset_address);
alter table perp_positions drop column if exists sub_id;
