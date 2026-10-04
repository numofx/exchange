package orders

import (
	"context"
	"fmt"
	"math/big"
	"testing"
	"time"
)

// The ledger scenario behind the reduce-only flag: an account long 1,352 units closes with a
// reduce-only sell of 2,000. The fill is clamped by the engine to 1,352 (not exercised here); when
// that fill is finalized the ledger lands on zero and the order's 648 remainder is cancelled in the
// same transaction with reduce_only_done, before anything else can match it.
func TestFinalizeMatchMovesTheLedgerAndCancelsAFlattenedReduceOnlyRemainder(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	suffix := fmt.Sprintf("it-reduce-only-%d", time.Now().UnixNano())
	perp := fmt.Sprintf("0xfeed00000000000000000000000000000000%04x", time.Now().UnixNano()%0xffff)
	// Subaccount ids are numeric; pick two no fixture uses.
	base := 900_000_000 + time.Now().UnixNano()%1_000_000
	closer, counterparty := fmt.Sprint(base), fmt.Sprint(base+1)
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	long := new(big.Int).Mul(big.NewInt(1352), scale)

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from perp_positions where subaccount_id in ($1, $2)", closer, counterparty)
	})

	// Seeded from a chain read; the counterparty is seeded flat so both legs move.
	if got, err := repo.SyncPerpPosition(ctx, closer, perp, long); err != nil || got.Cmp(long) != 0 {
		t.Fatalf("seed closer: %v %v", got, err)
	}
	if _, err := repo.SyncPerpPosition(ctx, counterparty, perp, big.NewInt(0)); err != nil {
		t.Fatalf("seed counterparty: %v", err)
	}

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, reduce_only
) values ($1, $2, $2, $3, $3, $4, $5, $6, '0', $7, '0', '0.00074', '740000000000000', '0', $8, '{}'::jsonb, '0xsig', 'matching', $9)
`
	expiry := time.Now().Add(time.Hour).Unix()
	takerID, makerID := suffix+"-taker", suffix+"-maker"
	if _, err := pool.Exec(ctx, insertOrder, takerID, "0xowner"+suffix, closer, "1", SideSell, perp, "2000", expiry, true); err != nil {
		t.Fatalf("insert reduce-only taker: %v", err)
	}
	if _, err := pool.Exec(ctx, insertOrder, makerID, "0xother"+suffix, counterparty, "2", SideBuy, perp, "5000", expiry, false); err != nil {
		t.Fatalf("insert maker: %v", err)
	}

	// With the taker's order in flight, a stale chain read must not overwrite the ledger.
	if got, err := repo.SyncPerpPosition(ctx, closer, perp, big.NewInt(0)); err != nil || got.Cmp(long) != 0 {
		t.Fatalf("ledger overwritten while an order was matching: %v %v", got, err)
	}

	ledger := &PerpFillLedger{AssetAddress: perp, ChainAmount: long, AmountScale: scale}
	if err := repo.FinalizeMatchWithPrice(ctx, takerID, makerID, "0.00074", "1352", FillSettlement{TakerFee: "0.5", Perp: ledger}); err != nil {
		t.Fatalf("finalize: %v", err)
	}

	for account, want := range map[string]*big.Int{closer: big.NewInt(0), counterparty: long} {
		got, ok, err := repo.PerpPosition(ctx, account, perp)
		if err != nil || !ok || got.Cmp(want) != 0 {
			t.Fatalf("ledger of %s = %v (ok %v, err %v), want %s", account, got, ok, err, want)
		}
	}

	var status, reason, by, filled string
	if err := pool.QueryRow(ctx, "select status, coalesce(cancel_reason, ''), coalesce(cancelled_by, ''), filled_amount from active_orders where order_id = $1", takerID).
		Scan(&status, &reason, &by, &filled); err != nil {
		t.Fatalf("load taker: %v", err)
	}
	if status != string(StatusCancelled) || reason != CancelReasonReduceOnlyDone || by != CancelledByVenue || filled != "1352" {
		t.Fatalf("reduce-only remainder: status %s reason %q by %q filled %s", status, reason, by, filled)
	}
	if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", makerID).Scan(&status); err != nil || status != string(StatusActive) {
		t.Fatalf("the ordinary maker keeps resting: %s %v", status, err)
	}

	// Flat and idle: the next chain read is believed again.
	if got, err := repo.SyncPerpPosition(ctx, closer, perp, big.NewInt(-7)); err != nil || got.Cmp(big.NewInt(-7)) != 0 {
		t.Fatalf("resync when idle: %v %v", got, err)
	}
}

func TestCancelByVenueTakesAReservedOrderOffTheBook(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	orderID := fmt.Sprintf("it-venue-cancel-%d", time.Now().UnixNano())
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", orderID) })

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, reduce_only
) values ($1, '0xowner', '0xowner', 9, 9, $2, 'buy', '0xfeed00000000000000000000000000000000beef', '0', '10', '0', '0.00074', '740000000000000', '0', $3, '{}'::jsonb, '0xsig', 'matching', true)
`
	if _, err := pool.Exec(ctx, insertOrder, orderID, fmt.Sprint(time.Now().UnixNano()), time.Now().Add(time.Hour).Unix()); err != nil {
		t.Fatalf("insert: %v", err)
	}
	if err := repo.CancelByVenue(ctx, orderID, CancelReasonReduceOnlyNoPosition); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	var status, reason string
	if err := pool.QueryRow(ctx, "select status, cancel_reason from active_orders where order_id = $1", orderID).Scan(&status, &reason); err != nil {
		t.Fatalf("load: %v", err)
	}
	if status != string(StatusCancelled) || reason != CancelReasonReduceOnlyNoPosition {
		t.Fatalf("status %s reason %s", status, reason)
	}
	// Releasing the pair afterwards must not resurrect it.
	if err := repo.ReleaseMatch(ctx, orderID); err != nil {
		t.Fatalf("release: %v", err)
	}
	if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", orderID).Scan(&status); err != nil || status != string(StatusCancelled) {
		t.Fatalf("release resurrected a cancelled order: %s %v", status, err)
	}
	if err := repo.CancelByVenue(ctx, orderID, CancelReasonReduceOnlyNoPosition); err != ErrNotFound {
		t.Fatalf("second cancel: %v", err)
	}
}
