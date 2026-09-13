package orders

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// Guards the defect where RunPruneLoop only fired on its ticker: a service
// redeployed more often than the interval would then never prune at all.
func TestRunPruneLoopPrunesAtStartupWithoutWaitingAnInterval(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()

	suffix := fmt.Sprintf("it-loop-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000000f1"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
	})

	if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, '0xsigner', 1, 1, 991001, 'buy', $3, '0', '100', '0', '1380', '1380', '0', 9999999999, '{}'::jsonb, '0xsig', 'cancelled', now() - interval '90 days')`,
		suffix+"-stale", "0xowner"+suffix, asset,
	); err != nil {
		t.Fatalf("insert stale order: %v", err)
	}

	original := pruneStartupDelay
	pruneStartupDelay = 10 * time.Millisecond
	t.Cleanup(func() { pruneStartupDelay = original })

	loopCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	// A deliberately huge interval: if the startup run were missing, nothing would
	// ever be deleted and this test would time out on the poll below.
	go repo.RunPruneLoop(loopCtx, 30*24*time.Hour, time.Hour, 100, nil)

	deadline := time.Now().Add(5 * time.Second)
	for {
		var remaining int
		if err := pool.QueryRow(ctx, "select count(*) from active_orders where order_id = $1", suffix+"-stale").Scan(&remaining); err != nil {
			t.Fatalf("count: %v", err)
		}
		if remaining == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("stale order was not pruned at startup")
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// An order that traded and was then cancelled or expired is the only record of who owned its fills.
// Pruning it would drop those fills from the owner's GET /v1/fills and from its filled_quote.
func TestPruneKeepsTerminalOrdersThatTraded(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()

	suffix := fmt.Sprintf("it-prune-traded-%d", time.Now().UnixNano())
	asset := "0xfeed0000000000000000000000000000000000f2"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1 or maker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
	})

	for i, row := range []struct{ id, status string }{
		{id: suffix + "-untraded", status: "cancelled"},
		{id: suffix + "-took", status: "cancelled"},
		{id: suffix + "-was-hit", status: "expired"},
	} {
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, $2, '0xsigner', 1, 1, $3, 'buy', $4, '0', '100', '0', '1380', '1380', '0', 9999999999, '{}'::jsonb, '0xsig', $5, now() - interval '90 days')`,
			row.id, "0xowner"+suffix, 992001+i, asset, row.status,
		); err != nil {
			t.Fatalf("insert %s: %v", row.id, err)
		}
	}
	if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id)
values ($1, '0', '0.00075', '21', 'buy', $2, $3), ($1, '0', '0.00075', '13', 'sell', $4, $5)`,
		asset, suffix+"-took", suffix+"-counterparty-1", suffix+"-counterparty-2", suffix+"-was-hit",
	); err != nil {
		t.Fatalf("insert fills: %v", err)
	}

	if _, err := repo.PruneTerminalOrders(ctx, 30*24*time.Hour, 100); err != nil {
		t.Fatalf("prune: %v", err)
	}

	for id, wantKept := range map[string]bool{
		suffix + "-untraded": false,
		suffix + "-took":     true,
		suffix + "-was-hit":  true,
	} {
		var remaining int
		if err := pool.QueryRow(ctx, "select count(*) from active_orders where order_id = $1", id).Scan(&remaining); err != nil {
			t.Fatalf("count %s: %v", id, err)
		}
		if kept := remaining == 1; kept != wantKept {
			t.Fatalf("%s kept = %v, want %v", id, kept, wantKept)
		}
	}
}
