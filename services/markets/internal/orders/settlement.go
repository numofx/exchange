package orders

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// PendingSettlement is a matcher fill recorded on its broadcast, not yet seen mined.
type PendingSettlement struct {
	TradeID      int64
	TxHash       string
	CreatedAt    time.Time
	AssetAddress string
	SubID        string
	Price        string
	Size         string
	TakerOrderID string
	MakerOrderID string
}

// PendingSettlements are the oldest fills still 'pending', at most limit.
func (r *Repository) PendingSettlements(ctx context.Context, limit int32) ([]PendingSettlement, error) {
	rows, err := r.pool.Query(ctx, `
select trade_id, tx_hash, created_at, asset_address, sub_id::text, price, size, taker_order_id, maker_order_id
from trade_fills where settlement = 'pending' order by trade_id limit $1`, limit)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()
	var out []PendingSettlement
	for rows.Next() {
		var p PendingSettlement
		if err := rows.Scan(&p.TradeID, &p.TxHash, &p.CreatedAt, &p.AssetAddress, &p.SubID, &p.Price, &p.Size,
			&p.TakerOrderID, &p.MakerOrderID); err != nil {
			return nil, mapPGError(err)
		}
		out = append(out, p)
	}
	return out, mapPGError(rows.Err())
}

// ConfirmSettlement marks a pending fill as mined.
func (r *Repository) ConfirmSettlement(ctx context.Context, tradeID int64) error {
	_, err := r.pool.Exec(ctx, `update trade_fills set settlement = 'confirmed' where trade_id = $1 and settlement = 'pending'`, tradeID)
	return mapPGError(err)
}

// VoidLedger is how a voided future fill moves the reduce-only ledger back: ChainPerUnit chain units a unit of size.
type VoidLedger struct {
	AssetAddress string
	SubID        string
	ChainPerUnit *big.Int
}

var (
	// ErrVoidDeferred: an order of the fill is reserved by a match in flight; void it on a later pass.
	ErrVoidDeferred = errors.New("an order of the fill is mid-match")
	// ErrNotPending: the fill is not (or no longer) pending.
	ErrNotPending = errors.New("the fill is not pending")
)

// VoidFill undoes a fill that did not settle, in one transaction: each order's filled amount goes back down (an order
// the fill had completed is cancelled, not reopened: it must not trade long after it was placed), a future's
// reduce-only ledger moves back, and the fill row goes to trade_fills_voided with its public 'trades' event removed.
func (r *Repository) VoidFill(ctx context.Context, tradeID int64, reason string, ledger *VoidLedger) error {
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var size, takerID, makerID string
	err = tx.QueryRow(ctx, `select size, taker_order_id, maker_order_id from trade_fills
where trade_id = $1 and settlement = 'pending' for update`, tradeID).Scan(&size, &takerID, &makerID)
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotPending
	}
	if err != nil {
		return mapPGError(err)
	}
	fillSize, ok := new(big.Int).SetString(size, 10)
	if !ok || fillSize.Sign() <= 0 {
		return fmt.Errorf("fill %d: size %q is not a positive integer", tradeID, size)
	}
	for _, id := range []string{takerID, makerID} {
		var status, filled, side, subaccount string
		err := tx.QueryRow(ctx, `select status, filled_amount, side, subaccount_id::text from active_orders where order_id = $1 for update`, id).
			Scan(&status, &filled, &side, &subaccount)
		if err != nil {
			return fmt.Errorf("fill %d: order %s: %w", tradeID, id, mapPGError(err))
		}
		if Status(status) == StatusMatching {
			return ErrVoidDeferred
		}
		was, ok := new(big.Int).SetString(filled, 10)
		if !ok || was.Cmp(fillSize) < 0 {
			return fmt.Errorf("fill %d: order %s has filled %q, under the fill's %s", tradeID, id, filled, size)
		}
		now := new(big.Int).Sub(was, fillSize).String()
		if Status(status) == StatusFilled {
			_, err = tx.Exec(ctx, `update active_orders set filled_amount = $2, status = 'cancelled', cancelled_at = now(),
cancel_reason = 'settlement_voided', cancelled_by = 'matcher' where order_id = $1`, id, now)
		} else {
			_, err = tx.Exec(ctx, `update active_orders set filled_amount = $2 where order_id = $1`, id, now)
		}
		if err != nil {
			return mapPGError(err)
		}
		if ledger != nil && ledger.ChainPerUnit != nil && ledger.ChainPerUnit.Sign() > 0 {
			// The fill moved a buyer's position up and a seller's down (applyPerpLedger); move it back.
			delta := new(big.Int).Mul(fillSize, ledger.ChainPerUnit)
			if Side(side) == SideBuy {
				delta.Neg(delta)
			}
			if _, err := tx.Exec(ctx, `update perp_positions set position = position + $4::numeric, updated_at = now()
where subaccount_id = $1 and asset_address = $2 and sub_id = $3::numeric`,
				subaccount, strings.ToLower(ledger.AssetAddress), ledger.SubID, delta.String()); err != nil {
				return mapPGError(err)
			}
		}
	}
	if _, err := tx.Exec(ctx, `insert into trade_fills_voided select tf.*, now(), $2 from trade_fills tf where trade_id = $1`, tradeID, reason); err != nil {
		return mapPGError(err)
	}
	if _, err := tx.Exec(ctx, `delete from trade_fills where trade_id = $1`, tradeID); err != nil {
		return mapPGError(err)
	}
	if _, err := tx.Exec(ctx, `delete from market_events where channel = 'trades' and payload->>'trade_id' = $1`, fmt.Sprint(tradeID)); err != nil {
		return mapPGError(err)
	}
	return tx.Commit(ctx)
}
