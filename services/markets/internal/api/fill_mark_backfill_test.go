package api

import (
	"context"
	"io/fs"
	"testing"

	projectmigrations "github.com/numofx/matching-backend/migrations"
)

// 000022 sets the chain's mark on the future fills recorded before 000021, and only on the fill it
// names: same trade id, same transaction, same series, no mark yet. Run in a transaction that is
// rolled back, since it needs the production trade ids.
func TestFutureFillMarkBackfillTouchesOnlyTheFillsItNames(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	wsApplyMigrations(ctx, t, pool)

	migration, err := fs.ReadFile(projectmigrations.Files, "000022_backfill_future_fill_marks.up.sql")
	if err != nil {
		t.Fatal(err)
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	const future = "0xdcfa4ee0772647abd24e8592596b5fe4f001bc19"
	if _, err := tx.Exec(ctx, "delete from trade_fills where trade_id in (440, 441, 442)"); err != nil {
		t.Fatal(err)
	}
	for _, row := range []struct {
		id      int
		tx, sub string
		mark    any
	}{
		{442, "0x9905DD7EA2C992E9F034D81A5BEBB248528B68171E4A2EE0FD2F40C0CCC761AB", "1796047200", nil}, // named: set
		{441, "0xfeed", "1796047200", nil}, // another transaction
		{440, "0xc38f1314395728baa9d5e623d52049e7755dd3526004943c93d413d3dfa728c0", "1796047200", "1"}, // already recorded
	} {
		if _, err := tx.Exec(ctx, `
insert into trade_fills (trade_id, asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, tx_hash, mark_price)
values ($1, $2, $3, '1380', '1', 'buy', 'backfill-t', 'backfill-m', $4, $5)`, row.id, future, row.sub, row.tx, row.mark); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(ctx, string(migration)); err != nil {
		t.Fatal(err)
	}
	want := map[int]*string{442: ptr("1381.41718156044809072"), 441: nil, 440: ptr("1")}
	for id, expected := range want {
		var mark *string
		if err := tx.QueryRow(ctx, "select mark_price from trade_fills where trade_id = $1", id).Scan(&mark); err != nil {
			t.Fatal(err)
		}
		if (mark == nil) != (expected == nil) || (mark != nil && *mark != *expected) {
			t.Fatalf("trade %d mark %v, want %v", id, deref(mark), deref(expected))
		}
	}
}

func ptr(s string) *string { return &s }

func deref(s *string) string {
	if s == nil {
		return "NULL"
	}
	return *s
}
