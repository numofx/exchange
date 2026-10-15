package api

import (
	"context"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/orders"
)

// A future series takes reduce_only like the perp: the account's position in that series (the
// FutureAsset at its expiry) is read from the chain into the ledger under the series' sub id, and only
// an order on the opposite side of a non-zero position is admitted.
func TestAdmitReduceOnlyOnAFutureReadsTheSeriesPosition(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	subaccount := "910000077"
	series := strconv.FormatInt(testFutureExpiry, 10)
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from perp_positions where subaccount_id = $1", subaccount) })

	oneContract := new(big.Int).Set(testWad)
	for _, tc := range []struct {
		name     string
		position *big.Int
		side     orders.Side
		status   int
		want     string
	}{
		{"long reduced by a sell", oneContract, orders.SideSell, 0, ""},
		{"long increased by a buy", oneContract, orders.SideBuy, http.StatusUnprocessableEntity, "same side"},
		{"short reduced by a buy", new(big.Int).Neg(oneContract), orders.SideBuy, 0, ""},
		{"flat", big.NewInt(0), orders.SideSell, http.StatusUnprocessableEntity, "no position"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stub := newFutureRPC()
			stub.positions = map[string]*big.Int{subaccount: tc.position}
			rpc := stub.server(t)
			defer rpc.Close()
			server := futureServer(t, rpc.URL)
			server.orders = orders.NewRepository(pool)
			params := orders.CreateOrderParams{OrderID: "fro-" + tc.name, SubaccountID: subaccount, Side: tc.side, AssetAddress: testFuture, SubID: series, ReduceOnly: true}
			status, msg := server.admitReduceOnly(ctx, params)
			if status != tc.status || !strings.Contains(msg, tc.want) {
				t.Fatalf("got %d %q, want %d containing %q", status, msg, tc.status, tc.want)
			}
			ledger, ok, err := server.orders.PerpPosition(ctx, subaccount, testFuture, series)
			if err != nil || !ok || ledger.Cmp(tc.position) != 0 {
				t.Fatalf("ledger = %v ok %v err %v, want the chain's %s", ledger, ok, err, tc.position)
			}
			// The series' row is its own: nothing is written under the perp's sub id.
			if _, ok, _ := server.orders.PerpPosition(ctx, subaccount, testFuture, "0"); ok {
				t.Fatal("the future's position was written under sub id 0")
			}
		})
	}
}
