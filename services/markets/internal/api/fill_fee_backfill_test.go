package api

import (
	"context"
	"fmt"
	"io/fs"
	"testing"
	"time"

	projectmigrations "github.com/numofx/matching-backend/migrations"
)

// 000014 backfills the fee on fills recorded before fees were stored, only where it is exactly known:
// zero before #41's matcher, and 25 bps of notional on the production spot market after it. Trade
// #343's value is one of the six fees whose sum matches fee subaccount 17's balance on chain.
func TestTradeFillFeeBackfillIsExactAndOnlyWhereKnown(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	wsApplyMigrations(ctx, t, pool)

	migration, err := fs.ReadFile(projectmigrations.Files, "000014_add_trade_fills_fee.up.sql")
	if err != nil {
		t.Fatalf("read migration: %v", err)
	}

	suffix := fmt.Sprintf("it-fee-backfill-%d", time.Now().UnixNano())
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "delete from trade_fills where taker_order_id like $1", suffix+"%")
	})

	const spot = "0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493"
	zero, trade343, recorded := "0", "0.002475414442967443", "0.1"
	cases := []struct {
		id, asset, price, size, createdAt string
		stored                            any
		want                              *string
	}{
		// The venue's last fill before #41's matcher: charged nothing.
		{id: "-before-41", asset: spot, price: "0.00078125", size: "1", createdAt: "2026-09-10T11:53:56Z", want: &zero},
		// Trade #343: floor(floor(0.000747294926178851 * 1325 * 1e18) * 25 / 10000) wei.
		{id: "-trade-343", asset: spot, price: "0.000747294926178851", size: "1325", createdAt: "2026-09-13T18:24:36Z", want: &trade343},
		// Another market after the boundary: its schedule is not known here, so it stays unknown.
		{id: "-other-market", asset: "0xfeed00000000000000000000000000000000abcd", price: "0.00075", size: "100", createdAt: "2026-09-13T18:24:36Z"},
		// A fee the matcher recorded is never overwritten.
		{id: "-recorded", asset: spot, price: "0.00075", size: "100", createdAt: "2026-09-13T18:24:36Z", stored: recorded, want: &recorded},
	}
	for _, c := range cases {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at, taker_fee)
values ($1, '0', $2, $3, 'sell', $4, $5, $6::timestamptz, $7)`,
			c.asset, c.price, c.size, suffix+c.id, suffix+c.id+"-maker", c.createdAt, c.stored); err != nil {
			t.Fatalf("insert %s: %v", c.id, err)
		}
	}

	if _, err := pool.Exec(ctx, string(migration)); err != nil {
		t.Fatalf("re-apply 000014: %v", err)
	}

	for _, c := range cases {
		var got *string
		if err := pool.QueryRow(ctx, "select taker_fee from trade_fills where taker_order_id = $1", suffix+c.id).Scan(&got); err != nil {
			t.Fatalf("load %s: %v", c.id, err)
		}
		shown := "NULL"
		if got != nil {
			shown = *got
		}
		switch {
		case c.want == nil && got != nil:
			t.Fatalf("%s: taker_fee = %q, want unknown (NULL)", c.id, shown)
		case c.want != nil && (got == nil || *got != *c.want):
			t.Fatalf("%s: taker_fee = %s, want %s", c.id, shown, *c.want)
		}
	}
}
