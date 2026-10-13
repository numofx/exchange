package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
)

// CNGN_PERP_CLOSE_ONLY at intake, through handleCreateOrder: a perp order that does not say reduce_only is
// taken as one, so it is admitted (and stored reduce-only) only if it reduces the account's position.
func TestPerpCloseOnlyTakesOnlyOrdersThatReduce(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	suffix := fmt.Sprintf("perp-close-only-%d", time.Now().UnixNano())
	subaccount := fmt.Sprint(930000000 + time.Now().UnixNano()%1000000)
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from perp_positions where subaccount_id = $1", subaccount)
	})

	submit := func(closeOnly bool, position *big.Int, id, side string) *httptest.ResponseRecorder {
		rpc := stubPerpRPC(t, position)
		t.Cleanup(rpc.Close)
		base := perpServer(t, rpc.URL)
		cfg := base.cfg
		cfg.CNGNPerpCloseOnly = closeOnly
		server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
		server.custody = fakeCustodyChecker{allow: map[string]bool{subaccount: true}}
		action := map[string]any{"subaccount_id": subaccount, "nonce": id, "module": cfg.CNGNPerpTradeModuleAddress,
			"data":   mustTradeDataHex(testPerpAsset, "0", "720000000000000", "1000000000000000000000", side == "buy"),
			"expiry": fmt.Sprint(time.Now().Add(time.Hour).Unix()), "owner": "0xabc", "signer": "0xabc"}
		// no reduce_only: the switch must supply it
		body, _ := json.Marshal(map[string]any{
			"order_id": suffix + "-" + id, "owner_address": "0xabc", "signer_address": "0xabc", "subaccount_id": subaccount,
			"recipient_id": subaccount, "nonce": id, "side": side, "asset_address": testPerpAsset, "sub_id": "0",
			"desired_amount": "1000", "filled_amount": "0", "limit_price": "0.00072", "worst_fee": "1000000000000000",
			"expiry": time.Now().Add(time.Hour).Unix(), "action_json": action, "signature": "0xsig",
		})
		rec := httptest.NewRecorder()
		server.handleCreateOrder(rec, httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body)))
		return rec
	}
	stored := func(id string) (bool, bool) {
		var reduceOnly bool
		err := pool.QueryRow(ctx, "select reduce_only from active_orders where order_id = $1", suffix+"-"+id).Scan(&reduceOnly)
		return err == nil, reduceOnly
	}
	short := new(big.Int).Neg(e18Int(1_352))

	if rec := submit(true, big.NewInt(0), "1", "buy"); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "no position") {
		t.Fatalf("flat account opening under close-only: %d %s", rec.Code, rec.Body.String())
	}
	if ok, _ := stored("1"); ok {
		t.Fatal("the opening order was stored")
	}
	if rec := submit(true, short, "2", "sell"); rec.Code != http.StatusUnprocessableEntity || !strings.Contains(rec.Body.String(), "same side") {
		t.Fatalf("a short adding to itself under close-only: %d %s", rec.Code, rec.Body.String())
	}
	if rec := submit(true, short, "3", "buy"); rec.Code >= 300 {
		t.Fatalf("a short buying back under close-only: %d %s", rec.Code, rec.Body.String())
	}
	if ok, reduceOnly := stored("3"); !ok || !reduceOnly {
		t.Fatalf("the reducing order: stored %v reduce_only %v, want stored and reduce_only", ok, reduceOnly)
	}

	// Off: the same opening order is taken as it was sent.
	if rec := submit(false, big.NewInt(0), "4", "buy"); rec.Code >= 300 {
		t.Fatalf("close-only off, a flat account opening: %d %s", rec.Code, rec.Body.String())
	}
	if ok, reduceOnly := stored("4"); !ok || reduceOnly {
		t.Fatalf("close-only off: stored %v reduce_only %v, want stored and not reduce_only", ok, reduceOnly)
	}
}

// /v1/markets says so: the perp block carries close_only.
func TestMarketsShowsThePerpCloseOnly(t *testing.T) {
	for _, on := range []bool{true, false} {
		rpc := stubPerpRPC(t, big.NewInt(0))
		server := perpServer(t, rpc.URL)
		server.cfg.CNGNPerpCloseOnly = on
		rec := httptest.NewRecorder()
		server.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
		rpc.Close()
		var markets []struct {
			Perp *struct {
				CloseOnly *bool `json:"close_only"`
			} `json:"perp"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &markets); err != nil {
			t.Fatal(err)
		}
		var seen bool
		for _, m := range markets {
			if m.Perp != nil {
				seen = true
				if m.Perp.CloseOnly == nil || *m.Perp.CloseOnly != on {
					t.Fatalf("close_only %v: listing says %v", on, m.Perp.CloseOnly)
				}
			}
		}
		if !seen {
			t.Fatal("no perp block in the listing")
		}
	}
}
