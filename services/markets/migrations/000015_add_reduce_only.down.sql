drop table if exists perp_position_cursor;
drop table if exists perp_positions;
alter table active_orders drop column if exists reduce_only;
