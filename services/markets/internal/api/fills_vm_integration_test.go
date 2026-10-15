package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

// A future fill recorded with its mark is served with the mark and the VM it settled; one recorded
// before the venue kept the mark carries neither.
func TestFillsServeTheFutureFillsMarkAndVM(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	wsApplyMigrations(ctx, t, pool)

	cfg := config.Config{
		WSAuthDomain:           historyTestDomain,
		CNGNFutureAssetAddress: fmt.Sprintf("0x%040x", time.Now().UnixNano()),
		CNGNFutureExpiry:       1796047200,
	}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))

	suffix := fmt.Sprintf("it-fills-vm-%d", time.Now().UnixNano())
	key := historyKeccak([]byte(suffix))
	owner := historyTestAddress(key)
	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "delete from trade_fills where taker_order_id like $1 or maker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(context.Background(), "delete from active_orders where order_id like $1", suffix+"%")
	})

	for i, id := range []string{suffix + "-old", suffix + "-new"} {
		if _, err := pool.Exec(ctx, `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $2, 35, 35, $3, 'buy', $4, $5, '10', '10', '1400', '1400000000000000000000', '0', $6, '{}'::jsonb, '0xsig', 'filled')`,
			id, owner, time.Now().UnixNano()+int64(i), cfg.CNGNFutureAssetAddress, cfg.FutureSubID(), time.Now().Add(time.Hour).Unix()); err != nil {
			t.Fatal(err)
		}
	}
	// Ten units, 10 USDC, bought at 1,400 against a mark of 1,390: the buyer pays 10 x 10 cNGN.
	for _, fill := range []struct{ taker, mark any }{{suffix + "-old", nil}, {suffix + "-new", "1390"}} {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, mark_price)
values ($1, $2, '1400', '10', 'buy', $3, $4, $5)`, cfg.CNGNFutureAssetAddress, cfg.FutureSubID(), fill.taker, suffix+"-maker", fill.mark); err != nil {
			t.Fatal(err)
		}
	}

	now := time.Now()
	rec := getFills(server, signedHistoryHeader(t, key, server.orderHistoryAuth, now, now.Add(time.Hour)), "")
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body=%s", rec.Code, rec.Body.String())
	}
	var body struct {
		Fills []map[string]any `json:"fills"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Fills) != 2 {
		t.Fatalf("fills %v, want two", body.Fills)
	}
	recorded, old := body.Fills[0], body.Fills[1]
	if recorded["mark_price"] != "1390" || recorded["vm_cngn"] != "-100" {
		t.Fatalf("recorded fill mark %v vm %v, want 1390 and -100", recorded["mark_price"], recorded["vm_cngn"])
	}
	if _, ok := old["vm_cngn"]; ok {
		t.Fatalf("a fill with no recorded mark must carry no vm_cngn: %v", old)
	}
	if _, ok := old["mark_price"]; ok {
		t.Fatalf("a fill with no recorded mark must carry no mark_price: %v", old)
	}
}
