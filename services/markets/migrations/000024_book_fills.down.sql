-- Restores the 000017 payload without source. Book rows are deleted: without source they would read as the
-- matcher's fills.
create or replace function markets_trade_event() returns trigger
language plpgsql as $$
begin
  insert into market_events (market_key, channel, event_type, owner_address, payload)
  values (
    lower(new.asset_address) || ':' || new.sub_id::text,
    'trades', 'fill', null,
    jsonb_build_object(
      'trade_id',       new.trade_id,
      'price',          new.price,
      'size',           new.size,
      'aggressor_side', new.aggressor_side,
      'taker_order_id', new.taker_order_id,
      'maker_order_id', new.maker_order_id,
      'created_at',     new.created_at,
      'tx_hash',        new.tx_hash
    )
  );
  return new;
end;
$$;

drop table if exists book_index_cursor;
drop table if exists book_takes;
delete from trade_fills where source = 'book';
drop index if exists trade_fills_book_log_idx;
alter table trade_fills drop constraint if exists trade_fills_book_identity_check;
alter table trade_fills drop column if exists maker_subaccount_id;
alter table trade_fills drop column if exists taker_subaccount_id;
alter table trade_fills drop column if exists log_index;
alter table trade_fills drop constraint if exists trade_fills_source_check;
alter table trade_fills drop column if exists source;
