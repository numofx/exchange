package api

import (
	"context"
	"math/big"
	"net/http"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// admitReduceOnly against the chain stub and the venue database: the account's chain position is
// written to the ledger, and only an order on the opposite side of a non-zero position is admitted.
func TestAdmitReduceOnlySeedsTheLedgerAndRefusesTheWrongSide(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	subaccount := "910000042"
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from perp_positions where subaccount_id = $1", subaccount) })

	for _, tc := range []struct {
		name     string
		position *big.Int
		side     orders.Side
		status   int
		want     string
	}{
		{"short reduced by a buy", new(big.Int).Neg(e18Int(1_352)), orders.SideBuy, 0, ""},
		{"short increased by a sell", new(big.Int).Neg(e18Int(1_352)), orders.SideSell, http.StatusUnprocessableEntity, "same side"},
		{"long reduced by a sell", e18Int(1_352), orders.SideSell, 0, ""},
		{"flat", big.NewInt(0), orders.SideBuy, http.StatusUnprocessableEntity, "no position"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rpc := stubPerpRPC(t, tc.position)
			defer rpc.Close()
			server := perpServer(t, rpc.URL)
			server.orders = orders.NewRepository(pool)
			params := orders.CreateOrderParams{OrderID: "ro-" + tc.name, SubaccountID: subaccount, Side: tc.side, AssetAddress: testPerpAsset, SubID: "0", ReduceOnly: true}
			status, msg := server.admitReduceOnly(ctx, params)
			if status != tc.status || !strings.Contains(msg, tc.want) {
				t.Fatalf("got %d %q, want %d containing %q", status, msg, tc.status, tc.want)
			}
			ledger, ok, err := server.orders.PerpPosition(ctx, subaccount, testPerpAsset)
			if err != nil || !ok || ledger.Cmp(tc.position) != 0 {
				t.Fatalf("ledger = %v ok %v err %v, want the chain's %s", ledger, ok, err, tc.position)
			}
		})
	}

	// Spot never carries the flag, whatever the chain says.
	rpc := stubPerpRPC(t, e18Int(5))
	defer rpc.Close()
	server := perpServer(t, rpc.URL)
	server.orders = orders.NewRepository(pool)
	server.cfg.CNGNSpotAssetAddress = "0x5555555555555555555555555555555555555555"
	server.instruments = instruments.DefaultRegistry(server.cfg)
	status, msg := server.admitReduceOnly(ctx, orders.CreateOrderParams{SubaccountID: subaccount, Side: orders.SideSell, AssetAddress: server.cfg.CNGNSpotAssetAddress, SubID: "0", ReduceOnly: true})
	if status != http.StatusBadRequest || !strings.Contains(msg, "perpetual") {
		t.Fatalf("spot reduce-only: %d %q", status, msg)
	}
}
