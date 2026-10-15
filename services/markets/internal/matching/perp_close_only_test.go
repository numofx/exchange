package matching

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// positionsOnly is a marginChecker that answers Position from a map and nothing else.
type positionsOnly map[string]*big.Int

func (p positionsOnly) CheckPerpFill(context.Context, instruments.Metadata, orders.MatchCandidate, string, string, string) (marginVerdict, error) {
	return marginVerdict{OK: true}, nil
}

func (p positionsOnly) Position(_ context.Context, _ string, subaccountID string) (*big.Int, error) {
	if v, ok := p[subaccountID]; ok {
		return new(big.Int).Set(v), nil
	}
	return big.NewInt(0), nil
}

// CNGN_PERP_CLOSE_ONLY: the matcher holds every perp leg to reducing its position, flagged or not, so an
// order resting from before the switch cannot open one. Against the venue database, through the real
// clampReduceOnly.
func TestPerpCloseOnlyHoldsUnflaggedLegsToTheirPositions(t *testing.T) {
	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()

	// A perp asset of its own per run, so no other test's ledger rows or orders are in play.
	asset := fmt.Sprintf("0x%040x", time.Now().UnixNano())
	cfg := config.Config{
		CNGNPerpAssetAddress: asset, CNGNPerpTradeModuleAddress: "0x00000000000000000000000000000000000000a1",
		CNGNPerpCashAddress: "0x00000000000000000000000000000000000000c1", CNGNPerpSRMAddress: "0x00000000000000000000000000000000000000d1",
		CNGNPerpCloseOnly: true,
	}
	instrument, ok := instruments.DefaultRegistry(cfg).ByAssetAndSubID(asset, "0")
	if !ok || !instrument.IsPerpetual() {
		t.Fatal("no perp instrument")
	}
	repo := orders.NewRepository(pool)
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) // a whole cNGN per order unit
	ledger := &orders.PerpFillLedger{AssetAddress: strings.ToLower(asset), ChainAmount: new(big.Int).Mul(big.NewInt(3), scale), AmountScale: scale}

	suffix := time.Now().UnixNano()
	long, flat, short := fmt.Sprint(920000000+suffix%1000000), fmt.Sprint(921000000+suffix%1000000), fmt.Sprint(922000000+suffix%1000000)
	var ids []string
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = any($1)", ids)
		_, _ = pool.Exec(ctx, "delete from perp_positions where asset_address = $1", strings.ToLower(asset))
	})
	seed := func(name, subaccount string, side orders.Side) orders.Order {
		id := fmt.Sprintf("close-only-%s-%d", name, suffix)
		ids = append(ids, id)
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status, created_at
) values ($1, '0x1111111111111111111111111111111111111111', '0x1111111111111111111111111111111111111111', $2, $2, $3, $4, $5, '0',
  '10', '0', '1', '1', '1', $6, '{}', '0x01', 'active', now())`,
			id, subaccount, fmt.Sprint(time.Now().UnixNano()), side, strings.ToLower(asset), time.Now().Add(time.Hour).Unix()); err != nil {
			t.Fatalf("seed %s: %v", name, err)
		}
		// neither carries reduce_only: they rested before the switch
		return orders.Order{OrderID: id, SubaccountID: subaccount, Side: side}
	}
	chain := positionsOnly{long: new(big.Int).Mul(big.NewInt(5), scale), short: new(big.Int).Mul(big.NewInt(-5), scale)}
	for sub, pos := range chain {
		if err := repo.SetPerpPosition(ctx, sub, strings.ToLower(asset), "0", pos); err != nil {
			t.Fatal(err)
		}
	}
	e := &Engine{orders: repo, margin: chain, perpCloseOnly: true}
	status := func(id string) string {
		var s string
		if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", id).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}

	// Long 5 sells 3 to short 5: both reduce, the fill stands.
	sell, buy := seed("long-sells", long, orders.SideSell), seed("short-buys", short, orders.SideBuy)
	got, err := e.clampReduceOnly(ctx, instrument, orders.MatchCandidate{Taker: buy, Maker: sell}, "3", ledger)
	if err != nil || got != "3" {
		t.Fatalf("two reducing legs: %q %v, want 3", got, err)
	}

	// A flat account buying against the long's sell would open a position: its order is cancelled by the
	// venue and the match is off; the long's order stays on the book.
	opener := seed("flat-buys", flat, orders.SideBuy)
	sell2 := seed("long-sells-2", long, orders.SideSell)
	if _, err := e.clampReduceOnly(ctx, instrument, orders.MatchCandidate{Taker: opener, Maker: sell2}, "3", ledger); !errors.Is(err, errReduceOnlyCancelled) {
		t.Fatalf("an opening leg under close-only: %v, want errReduceOnlyCancelled", err)
	}
	if s := status(opener.OrderID); s != "cancelled" {
		t.Fatalf("the opening order is %q, want cancelled", s)
	}
	if s := status(sell2.OrderID); s != "active" {
		t.Fatalf("the reducing maker is %q, want back on the book (active)", s)
	}

	// The same pair with the switch off: nothing is read or clamped.
	off := &Engine{orders: repo, margin: chain}
	opener2 := seed("flat-buys-off", flat, orders.SideBuy)
	if got, err := off.clampReduceOnly(ctx, instrument, orders.MatchCandidate{Taker: opener2, Maker: sell2}, "3", ledger); err != nil || got != "3" {
		t.Fatalf("close-only off: %q %v, want 3 untouched", got, err)
	}

	// And NewEngine takes the switch from config.
	if !NewEngine(cfg, pool).perpCloseOnly {
		t.Fatal("NewEngine does not read CNGN_PERP_CLOSE_ONLY")
	}
}
