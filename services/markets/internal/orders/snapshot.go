package orders

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

// Snapshot* read the data AND the market_events seq cursor inside ONE repeatable-read,
// read-only transaction, so a WebSocket subscriber gets a state and a boundary seq that are
// mutually consistent: every event with seq <= boundarySeq is already reflected in the
// returned rows; every event with seq > boundarySeq is not. The WS handler then drops live
// deltas with seq <= boundarySeq, giving exactly-once handoff from snapshot to live stream.

const snapshotCols = `order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
	desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at`

// SnapshotBook returns the resting book (active orders) per side plus the consistent boundary.
func (r *Repository) SnapshotBook(ctx context.Context, assetAddress, subID string, limit int32) (bids, asks []Order, boundarySeq int64, err error) {
	asset := strings.ToLower(assetAddress)
	err = r.inRRSnapshot(ctx, func(tx pgx.Tx) error {
		var e error
		if bids, e = queryBookSide(ctx, tx, asset, subID, SideBuy, limit); e != nil {
			return e
		}
		if asks, e = queryBookSide(ctx, tx, asset, subID, SideSell, limit); e != nil {
			return e
		}
		boundarySeq, e = queryMaxSeq(ctx, tx)
		return e
	})
	return bids, asks, boundarySeq, err
}

// SnapshotTrades returns the most recent fills plus the consistent boundary.
func (r *Repository) SnapshotTrades(ctx context.Context, assetAddress, subID string, limit int32) ([]TradeFill, int64, error) {
	asset := strings.ToLower(assetAddress)
	var (
		trades   []TradeFill
		boundary int64
	)
	err := r.inRRSnapshot(ctx, func(tx pgx.Tx) error {
		rows, e := tx.Query(ctx, `
select trade_id, asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at
from trade_fills where asset_address = $1 and sub_id = $2
order by created_at desc, trade_id desc limit $3`, asset, subID, limit)
		if e != nil {
			return mapPGError(e)
		}
		defer rows.Close()
		for rows.Next() {
			var t TradeFill
			if e := rows.Scan(&t.TradeID, &t.AssetAddress, &t.SubID, &t.Price, &t.Size,
				&t.AggressorSide, &t.TakerOrderID, &t.MakerOrderID, &t.CreatedAt); e != nil {
				return mapPGError(e)
			}
			trades = append(trades, t)
		}
		if e := rows.Err(); e != nil {
			return mapPGError(e)
		}
		boundary, e = queryMaxSeq(ctx, tx)
		return e
	})
	return trades, boundary, err
}

// SnapshotOpenOrdersByOwner returns an owner's still-open (active/matching) orders plus the
// consistent boundary. Owner is lowercased to match the trigger's routing key.
func (r *Repository) SnapshotOpenOrdersByOwner(ctx context.Context, owner string, limit int32) ([]Order, int64, error) {
	own := strings.ToLower(strings.TrimSpace(owner))
	var (
		result   []Order
		boundary int64
	)
	err := r.inRRSnapshot(ctx, func(tx pgx.Tx) error {
		rows, e := tx.Query(ctx, fmt.Sprintf(`select %s from active_orders
where owner_address = $1 and status in ('active','matching')
order by created_at desc limit $2`, snapshotCols), own, limit)
		if e != nil {
			return mapPGError(e)
		}
		defer rows.Close()
		for rows.Next() {
			o, e := scanOrder(rows)
			if e != nil {
				return e
			}
			result = append(result, o)
		}
		if e := rows.Err(); e != nil {
			return mapPGError(e)
		}
		boundary, e = queryMaxSeq(ctx, tx)
		return e
	})
	return result, boundary, err
}

func (r *Repository) inRRSnapshot(ctx context.Context, fn func(pgx.Tx) error) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return mapPGError(err)
	}
	defer tx.Rollback(ctx)
	if err := fn(tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func queryBookSide(ctx context.Context, tx pgx.Tx, asset, subID string, side Side, limit int32) ([]Order, error) {
	orderBy := "limit_price_ticks::numeric desc, created_at asc"
	if side == SideSell {
		orderBy = "limit_price_ticks::numeric asc, created_at asc"
	}
	rows, err := tx.Query(ctx, fmt.Sprintf(`select %s from active_orders
where asset_address = $1 and sub_id = $2 and side = $3 and status = 'active'
order by %s limit $4`, snapshotCols, orderBy), asset, subID, side, limit)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()
	var result []Order
	for rows.Next() {
		o, err := scanOrder(rows)
		if err != nil {
			return nil, err
		}
		result = append(result, o)
	}
	if err := rows.Err(); err != nil {
		return nil, mapPGError(err)
	}
	return result, nil
}

func queryMaxSeq(ctx context.Context, tx pgx.Tx) (int64, error) {
	var seq int64
	if err := tx.QueryRow(ctx, `select coalesce(max(seq), 0) from market_events`).Scan(&seq); err != nil {
		return 0, mapPGError(err)
	}
	return seq, nil
}
