package orders

import (
	"context"
	"strings"
	"time"
)

// OrderHistoryEntry is one of an owner's orders in any status, with the cancel audit a history row
// needs and the book never does.
type OrderHistoryEntry struct {
	Order
	CancelReason string
	CancelledAt  *time.Time
	// FilledQuote is what actually traded, in the quote asset: the sum of price × size over the
	// order's fills, taker or maker. Empty when the order has no fills. It is the one reliable size
	// for an order that filled: the order's own amount is valued at its signed limit, which for a
	// marketable order includes slippage room the fill never used.
	FilledQuote string
}

// OrderHistoryCursor is the last row of the previous page. Paging on (created_at, order_id) rather
// than created_at alone keeps two orders created in the same microsecond from being skipped or
// repeated at a page boundary.
type OrderHistoryCursor struct {
	CreatedAt time.Time
	OrderID   string
}

// ListOrdersByOwner returns an owner's orders in every status, newest first.
//
// How far back it reaches follows retention, not the order: 'filled' rows are kept forever, while
// 'cancelled' and 'expired' rows are pruned after ORDERS_PRUNE_HORIZON. limit_price_ticks is
// coalesced because rows written before that column existed hold NULL, and a history — unlike the
// book, which only ever reads live rows — reaches back to them.
func (r *Repository) ListOrdersByOwner(ctx context.Context, owner string, before *OrderHistoryCursor, limit int32) ([]OrderHistoryEntry, error) {
	const query = `
select o.order_id, o.owner_address, o.signer_address, o.subaccount_id, o.recipient_id, o.nonce, o.side,
       o.asset_address, o.sub_id, o.desired_amount, o.filled_amount, o.limit_price,
       coalesce(o.limit_price_ticks, ''), o.worst_fee, o.expiry, o.action_json, o.signature, o.status,
       o.created_at, o.post_only, coalesce(o.cancel_reason, ''), o.cancelled_at,
       coalesce((
         select sum(tf.price::numeric * tf.size::numeric)::text
         from trade_fills tf
         where tf.taker_order_id = o.order_id or tf.maker_order_id = o.order_id
       ), '')
from active_orders o
where o.owner_address = $1
  and ($2::timestamptz is null or (o.created_at, o.order_id) < ($2::timestamptz, $3::text))
order by o.created_at desc, o.order_id desc
limit $4
`

	var beforeCreatedAt *time.Time
	beforeOrderID := ""
	if before != nil {
		createdAt := before.CreatedAt
		beforeCreatedAt = &createdAt
		beforeOrderID = before.OrderID
	}

	rows, err := r.pool.Query(ctx, query, strings.ToLower(strings.TrimSpace(owner)), beforeCreatedAt, beforeOrderID, limit)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()

	results := []OrderHistoryEntry{}
	for rows.Next() {
		var entry OrderHistoryEntry
		if err := rows.Scan(
			&entry.OrderID,
			&entry.OwnerAddress,
			&entry.SignerAddress,
			&entry.SubaccountID,
			&entry.RecipientID,
			&entry.Nonce,
			&entry.Side,
			&entry.AssetAddress,
			&entry.SubID,
			&entry.DesiredAmount,
			&entry.FilledAmount,
			&entry.LimitPrice,
			&entry.LimitPriceTicks,
			&entry.WorstFee,
			&entry.Expiry,
			&entry.ActionJSON,
			&entry.Signature,
			&entry.Status,
			&entry.CreatedAt,
			&entry.PostOnly,
			&entry.CancelReason,
			&entry.CancelledAt,
			&entry.FilledQuote,
		); err != nil {
			return nil, mapPGError(err)
		}
		results = append(results, entry)
	}
	if err := rows.Err(); err != nil {
		return nil, mapPGError(err)
	}

	return results, nil
}
