-- Restores the 000008 payload without tx_hash.
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
      'created_at',     new.created_at
    )
  );
  return new;
end;
$$;
