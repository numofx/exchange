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
