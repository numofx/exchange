package orders

import (
	"context"
	"strings"
)

// Liquidity is which side of a trade an order was on.
type Liquidity string

const (
	LiquidityTaker Liquidity = "taker"
	LiquidityMaker Liquidity = "maker"
)

// OwnerFill is one fill on one of an owner's orders. A trade between two of the same owner's orders
// (on different subaccounts) is two fills, one per order, since each moved that account's balances.
type OwnerFill struct {
	TradeFill
	// OrderID is the owner's order this fill belongs to — the taker or the maker order of the trade.
	OrderID string
	// OrderSide is that order's engine side, which is the owner's side of the trade. The trade's
	// AggressorSide is the taker's, so it is the owner's only when Liquidity is taker.
	OrderSide Side
	Liquidity Liquidity
	// TakerFee is what the trade's taker paid, in the quote asset; nil when it was not recorded.
	TakerFee *string
	// TxHash is the settling transaction; nil when it was not recorded.
	TxHash *string
}

// FillCursor is the last row of the previous page. A trade can appear twice for one owner — once as
// taker, once as maker — so the trade id alone cannot mark a page boundary.
type FillCursor struct {
	TradeID   int64
	Liquidity Liquidity
}

// ListFillsByOwner returns the fills on an owner's orders, newest first.
//
// Ownership comes from active_orders, so a fill is listed only while its order row exists. Rows that
// traded are never pruned (PruneTerminalOrders), which keeps an owner's fills listed indefinitely.
// trade_id is the order: it is assigned as fills are recorded, so it follows execution time without
// the ties created_at can have.
func (r *Repository) ListFillsByOwner(ctx context.Context, owner string, before *FillCursor, limit int32) ([]OwnerFill, error) {
	// One branch per side rather than a join on (taker or maker), so each can use its order-id index.
	const query = `
select trade_id, asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at,
       order_id, side, liquidity, taker_fee, tx_hash
from (
  select tf.trade_id, tf.asset_address, tf.sub_id, tf.price, tf.size, tf.aggressor_side, tf.taker_order_id,
         tf.maker_order_id, tf.created_at, o.order_id, o.side, 'taker'::text as liquidity,
         tf.taker_fee, tf.tx_hash
  from active_orders o
  join trade_fills tf on tf.taker_order_id = o.order_id
  where o.owner_address = $1
  union all
  select tf.trade_id, tf.asset_address, tf.sub_id, tf.price, tf.size, tf.aggressor_side, tf.taker_order_id,
         tf.maker_order_id, tf.created_at, o.order_id, o.side, 'maker'::text as liquidity,
         tf.taker_fee, tf.tx_hash
  from active_orders o
  join trade_fills tf on tf.maker_order_id = o.order_id
  where o.owner_address = $1
) fills
where $2::bigint is null or (trade_id, liquidity) < ($2::bigint, $3::text)
order by trade_id desc, liquidity desc
limit $4
`

	var beforeTradeID *int64
	beforeLiquidity := ""
	if before != nil {
		tradeID := before.TradeID
		beforeTradeID = &tradeID
		beforeLiquidity = string(before.Liquidity)
	}

	rows, err := r.pool.Query(ctx, query, strings.ToLower(strings.TrimSpace(owner)), beforeTradeID, beforeLiquidity, limit)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()

	results := []OwnerFill{}
	for rows.Next() {
		var fill OwnerFill
		if err := rows.Scan(
			&fill.TradeID,
			&fill.AssetAddress,
			&fill.SubID,
			&fill.Price,
			&fill.Size,
			&fill.AggressorSide,
			&fill.TakerOrderID,
			&fill.MakerOrderID,
			&fill.CreatedAt,
			&fill.OrderID,
			&fill.OrderSide,
			&fill.Liquidity,
			&fill.TakerFee,
			&fill.TxHash,
		); err != nil {
			return nil, mapPGError(err)
		}
		results = append(results, fill)
	}
	if err := rows.Err(); err != nil {
		return nil, mapPGError(err)
	}

	return results, nil
}

// FillSettlement is what the chain was asked to do for a fill, recorded with it. An empty field is
// stored as NULL, which reads as unknown, never as zero.
type FillSettlement struct {
	// TakerFee is the fee the taker paid, in the quote asset, as an exact decimal.
	TakerFee string
	// TxHash is the transaction that settled the fill, when the executor reported one.
	TxHash string
}
