package orders

import (
	"context"
	"fmt"
	"math/big"
	"testing"
	"time"
)

// A trader-facing ticker shows 24h volume in USDC, but stats_24h carried only the summed size, in
// cNGN. quote_volume is price × size over the same trailing 24 hours as the rest of the stats — a
// real window, not the UTC day, so it does not blank at midnight while the day's trades are still
// within it.
func TestTradeStats24hReportsQuoteVolumeOverTheTrailingDay(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	asset := fmt.Sprintf("0xfeed%036x", time.Now().UnixNano())
	empty := fmt.Sprintf("0xfeed%036x", time.Now().UnixNano()+1)

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where asset_address in ($1, $2)", asset, empty)
	})

	for _, fill := range []struct{ price, size, age string }{
		{price: "0.001", size: "1000", age: "25 hours"}, // outside the window: neither its price nor its 1 USDC counts
		{price: "0.00075", size: "1000", age: "20 hours"},
		{price: "0.0008", size: "500", age: "1 hour"},
	} {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at)
values ($1, '0', $2, $3, 'buy', 'it-stats-taker', 'it-stats-maker', now() - $4::interval)`,
			asset, fill.price, fill.size, fill.age); err != nil {
			t.Fatalf("insert fill: %v", err)
		}
	}

	stats, err := repo.GetTradeStats24h(ctx, asset, "0")
	if err != nil {
		t.Fatalf("stats: %v", err)
	}
	for name, got := range map[string][2]string{
		"volume":       {stats.Volume, "1500"},
		"quote_volume": {stats.QuoteVolume, "1.15"}, // 0.00075 * 1000 + 0.0008 * 500
		"high":         {stats.High, "0.0008"},
		"low":          {stats.Low, "0.00075"},
		"last":         {stats.Last, "0.0008"},
		"change":       {stats.Change, "0.00005"},
	} {
		if !sameDecimal(got[0], got[1]) {
			t.Fatalf("%s = %q, want %s", name, got[0], got[1])
		}
	}

	quiet, err := repo.GetTradeStats24h(ctx, empty, "0")
	if err != nil {
		t.Fatalf("stats for a quiet market: %v", err)
	}
	if quiet != (TradeStats24h{}) {
		t.Fatalf("a market with no fills in the window reports %+v, want every field empty", quiet)
	}
}

func sameDecimal(got string, want string) bool {
	g, ok := new(big.Rat).SetString(got)
	if !ok {
		return false
	}
	w, _ := new(big.Rat).SetString(want)
	return g.Cmp(w) == 0
}
