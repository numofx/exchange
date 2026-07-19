update active_orders
set limit_price_ticks = limit_price
where limit_price_ticks is null;
