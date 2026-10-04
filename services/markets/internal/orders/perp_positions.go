package orders

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/jackc/pgx/v5"
)

// The perp_positions ledger is the venue's own view of each account's perp position, in chain units
// (18dp, signed; the engine buyer gains). It is seeded from the chain when an account first submits a
// reduce-only order and moved by every fill the venue finalizes, inside the fill's own transaction,
// so a reduce-only order is always clamped against a position that already counts the fills a few
// milliseconds old -- the ones a poll of the chain has not seen yet.

// CancelledByVenue marks a cancel the venue decided on its own, such as the unfillable remainder of a
// reduce-only order; it is what cancelled_by records for those rows.
const CancelledByVenue = "venue"

const (
	// CancelReasonReduceOnlyDone: the position the order was reducing reached zero (or dust below one
	// order unit), so what was left of the order could only have opened a position.
	CancelReasonReduceOnlyDone = "reduce_only_done"
	// CancelReasonReduceOnlyNoPosition: at match time the account had no position on the side the
	// order would reduce, so the order could only have opened or flipped one.
	CancelReasonReduceOnlyNoPosition = "reduce_only_no_position"
)

// PerpFillLedger tells FinalizeMatchWithPrice how the fill moves the two accounts' positions.
type PerpFillLedger struct {
	// AssetAddress is the perp asset the positions are in.
	AssetAddress string
	// ChainAmount is the fill in chain units (18dp), unsigned; the buyer gains it, the seller loses it.
	ChainAmount *big.Int
	// AmountScale is chain units per order unit; a position below it cannot be reduced by any order.
	AmountScale *big.Int
}

// SyncPerpPosition seeds or refreshes the ledger row from a chain read and returns the ledger's
// position. A row is refreshed only when the account has no order in flight on that asset: a fill
// being finalized moves the ledger in its own transaction, and the chain read may predate it. With an
// order in flight the ledger is the fresher of the two and is kept.
func (r *Repository) SyncPerpPosition(ctx context.Context, subaccountID, assetAddress string, chainPosition *big.Int) (*big.Int, error) {
	assetAddress = strings.ToLower(strings.TrimSpace(assetAddress))
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var current string
	err = tx.QueryRow(ctx, `select position::text from perp_positions where subaccount_id = $1 and asset_address = $2 for update`,
		subaccountID, assetAddress).Scan(&current)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		if _, err := tx.Exec(ctx, `insert into perp_positions (subaccount_id, asset_address, position) values ($1, $2, $3::numeric)`,
			subaccountID, assetAddress, chainPosition.String()); err != nil {
			return nil, mapPGError(err)
		}
		current = chainPosition.String()
	case err != nil:
		return nil, mapPGError(err)
	default:
		var inFlight int
		if err := tx.QueryRow(ctx, `select count(*) from active_orders where subaccount_id = $1 and asset_address = $2 and status = 'matching'`,
			subaccountID, assetAddress).Scan(&inFlight); err != nil {
			return nil, mapPGError(err)
		}
		if inFlight == 0 && current != chainPosition.String() {
			if _, err := tx.Exec(ctx, `update perp_positions set position = $3::numeric, updated_at = now() where subaccount_id = $1 and asset_address = $2`,
				subaccountID, assetAddress, chainPosition.String()); err != nil {
				return nil, mapPGError(err)
			}
			current = chainPosition.String()
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	position, ok := new(big.Int).SetString(current, 10)
	if !ok {
		return nil, fmt.Errorf("perp_positions holds a non-integer position %q", current)
	}
	return position, nil
}

// PerpPosition reads the ledger. ok is false when the account was never seeded.
func (r *Repository) PerpPosition(ctx context.Context, subaccountID, assetAddress string) (position *big.Int, ok bool, err error) {
	var current string
	err = r.pool.QueryRow(ctx, `select position::text from perp_positions where subaccount_id = $1 and asset_address = $2`,
		subaccountID, strings.ToLower(strings.TrimSpace(assetAddress))).Scan(&current)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, mapPGError(err)
	}
	position, parsed := new(big.Int).SetString(current, 10)
	if !parsed {
		return nil, false, fmt.Errorf("perp_positions holds a non-integer position %q", current)
	}
	return position, true, nil
}

// CancelByVenue cancels an order the venue itself has decided can no longer be filled, whether it is
// resting or reserved for a match that will not happen. ErrNotFound when it is already done.
func (r *Repository) CancelByVenue(ctx context.Context, orderID, reason string) error {
	tag, err := r.pool.Exec(ctx, `
update active_orders
set status = $2, cancelled_at = now(), cancel_reason = $3, cancelled_by = $4
where order_id = $1 and status in ('active', 'matching')`,
		orderID, StatusCancelled, reason, CancelledByVenue)
	if err != nil {
		return mapPGError(err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// applyPerpLedger moves one leg's position by the fill and cancels what is left of a reduce-only
// order once there is nothing left to reduce. Accounts never seeded are left alone: their ledger
// starts at the chain read their first reduce-only order makes.
func applyPerpLedger(ctx context.Context, tx pgx.Tx, order Order, ledger *PerpFillLedger) error {
	if ledger == nil || ledger.ChainAmount == nil || ledger.ChainAmount.Sign() <= 0 {
		return nil
	}
	delta := new(big.Int).Set(ledger.ChainAmount)
	if order.Side == SideSell {
		delta.Neg(delta)
	}
	var after string
	err := tx.QueryRow(ctx, `
update perp_positions set position = position + $3::numeric, updated_at = now()
where subaccount_id = $1 and asset_address = $2
returning position::text`,
		order.SubaccountID, strings.ToLower(ledger.AssetAddress), delta.String()).Scan(&after)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return mapPGError(err)
	}
	if !order.ReduceOnly || order.Status != StatusActive {
		return nil
	}
	position, ok := new(big.Int).SetString(after, 10)
	if !ok {
		return fmt.Errorf("perp_positions holds a non-integer position %q", after)
	}
	remaining := new(big.Int).Abs(position)
	if ledger.AmountScale != nil && ledger.AmountScale.Sign() > 0 && remaining.Cmp(ledger.AmountScale) >= 0 {
		return nil
	}
	_, err = tx.Exec(ctx, `
update active_orders set status = $2, cancelled_at = now(), cancel_reason = $3, cancelled_by = $4
where order_id = $1 and status = 'active'`,
		order.OrderID, StatusCancelled, CancelReasonReduceOnlyDone, CancelledByVenue)
	return mapPGError(err)
}

// SetPerpPosition writes the chain's position over the ledger row, whatever the row said: the
// match-time resync, when the chain read disagrees with the ledger.
func (r *Repository) SetPerpPosition(ctx context.Context, subaccountID, assetAddress string, position *big.Int) error {
	_, err := r.pool.Exec(ctx, `
insert into perp_positions (subaccount_id, asset_address, position) values ($1, $2, $3::numeric)
on conflict (subaccount_id, asset_address) do update set position = excluded.position, updated_at = now()`,
		subaccountID, strings.ToLower(strings.TrimSpace(assetAddress)), position.String())
	return mapPGError(err)
}

// ChainPositionAdjustment is one SubAccounts.BalanceAdjusted event for the perp asset.
type ChainPositionAdjustment struct {
	SubaccountID string
	// PostBalance is the account's position after the adjustment, in chain units.
	PostBalance *big.Int
	TxHash      string
	BlockNumber uint64
}

// ApplyChainAdjustments brings the ledger up to the chain through block `through`, in one
// transaction with the cursor. An adjustment made by one of the venue's own fills (its transaction
// is in trade_fills) is skipped: FinalizeMatchWithPrice already moved the ledger for it, or is about
// to, and setting the post-balance here as well would count the fill twice. Every other adjustment
// (a liquidation, settlement, a transfer) sets the position to what the chain says it is afterwards.
func (r *Repository) ApplyChainAdjustments(ctx context.Context, assetAddress string, adjustments []ChainPositionAdjustment, through uint64) (applied int, skipped int, err error) {
	assetAddress = strings.ToLower(strings.TrimSpace(assetAddress))
	tx, err := r.pool.BeginTx(ctx, pgx.TxOptions{})
	if err != nil {
		return 0, 0, err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	for _, adjustment := range adjustments {
		var venueFill bool
		if err := tx.QueryRow(ctx, `select exists (select 1 from trade_fills where lower(tx_hash) = lower($1))`, adjustment.TxHash).Scan(&venueFill); err != nil {
			return 0, 0, mapPGError(err)
		}
		if venueFill {
			skipped++
			continue
		}
		if _, err := tx.Exec(ctx, `
insert into perp_positions (subaccount_id, asset_address, position) values ($1, $2, $3::numeric)
on conflict (subaccount_id, asset_address) do update set position = excluded.position, updated_at = now()`,
			adjustment.SubaccountID, assetAddress, adjustment.PostBalance.String()); err != nil {
			return 0, 0, mapPGError(err)
		}
		applied++
	}
	if _, err := tx.Exec(ctx, `
insert into perp_position_cursor (asset_address, block_number) values ($1, $2)
on conflict (asset_address) do update set block_number = excluded.block_number, updated_at = now()`,
		assetAddress, int64(through)); err != nil {
		return 0, 0, mapPGError(err)
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, 0, err
	}
	return applied, skipped, nil
}

// PerpPositionCursor is the last block the indexer has applied for the asset; ok false before the
// first run.
func (r *Repository) PerpPositionCursor(ctx context.Context, assetAddress string) (block uint64, ok bool, err error) {
	var stored int64
	err = r.pool.QueryRow(ctx, `select block_number from perp_position_cursor where asset_address = $1`,
		strings.ToLower(strings.TrimSpace(assetAddress))).Scan(&stored)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, mapPGError(err)
	}
	return uint64(stored), true, nil
}

// SetPerpPositionCursor starts (or moves) the indexer's cursor without applying anything.
func (r *Repository) SetPerpPositionCursor(ctx context.Context, assetAddress string, block uint64) error {
	_, err := r.pool.Exec(ctx, `
insert into perp_position_cursor (asset_address, block_number) values ($1, $2)
on conflict (asset_address) do update set block_number = excluded.block_number, updated_at = now()`,
		strings.ToLower(strings.TrimSpace(assetAddress)), int64(block))
	return mapPGError(err)
}
