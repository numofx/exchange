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
select order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
       desired_amount, filled_amount, limit_price, coalesce(limit_price_ticks, ''), worst_fee, expiry, action_json,
       signature, status, created_at, post_only, coalesce(cancel_reason, ''), cancelled_at
from active_orders
where owner_address = $1
  and ($2::timestamptz is null or (created_at, order_id) < ($2::timestamptz, $3::text))
order by created_at desc, order_id desc
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
