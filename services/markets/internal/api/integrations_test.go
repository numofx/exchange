package api

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

// The integration endpoints restate USDCcNGN-SPOT in the orientation /v1/markets advertises, which
// since cngn_usdc_spot_v1 is the engine's own: cNGN priced in USDC. Every expected value below is
// worked out by hand from the engine rows seeded, at the UI's scales, so a handler that inverts
// anything, or shows the engine's 18 places, fails here.
func TestIntegrationEndpointsRestateSpotInAdvertisedOrientation(t *testing.T) {
	pool := openTestPool(t)
	// Not t.Context(): it is cancelled before t.Cleanup runs.
	ctx := context.Background()

	stamp := time.Now().UnixNano()
	asset := fmt.Sprintf("0x%040x", stamp)
	subID := "0"

	t.Cleanup(func() {
		if _, err := pool.Exec(ctx, "delete from active_orders where asset_address = $1", asset); err != nil {
			t.Errorf("cleanup active_orders: %v", err)
		}
		if _, err := pool.Exec(ctx, "delete from trade_fills where asset_address = $1", asset); err != nil {
			t.Errorf("cleanup trade_fills: %v", err)
		}
	})

	// Engine rows: side, limit price (USDC per cNGN), desired and filled cNGN, status.
	type engineOrder struct {
		side, price, desired, filled, status string
	}
	seeded := []engineOrder{
		// Engine sells of cNGN: the asks, lowest first.
		{"sell", "0.0003", "3000", "0", "active"},    // ask 0.0003; 3000 cNGN
		{"sell", "0.0004", "2500", "0", "active"},    // ask 0.0004; 2500 cNGN
		{"sell", "0.0005", "2000", "0", "active"},    // ask 0.0005; 2000 cNGN …
		{"sell", "0.0005", "1000", "0", "active"},    // … same level, +1000 cNGN
		{"sell", "0.0002", "9000", "0", "cancelled"}, // not resting: must not appear
		// Engine buys of cNGN: the bids, highest first.
		{"buy", "0.00025", "4000", "1000", "active"}, // bid 0.00025; remaining 3000 cNGN
		{"buy", "0.0002", "5000", "0", "active"},     // bid 0.0002; 5000 cNGN
		{"buy", "0.00015", "6000", "0", "active"},    // bid 0.00015; 6000 cNGN
	}
	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, '0xowner', '0xowner', 6, 6, $2, $3, $4, $5, $6, $7, $8, $9, '0', $10, '{}'::jsonb, '0xsig', $11)
`
	expiry := time.Now().Add(time.Hour).Unix()
	for i, o := range seeded {
		price, _ := new(big.Rat).SetString(o.price)
		ticks := new(big.Rat).Mul(price, new(big.Rat).SetInt(pow10(18)))
		if _, err := pool.Exec(ctx, insertOrder,
			fmt.Sprintf("integrations-%d-%d", stamp, i), fmt.Sprintf("%d%02d", stamp, i), o.side, asset, subID,
			o.desired, o.filled, o.price, ticks.Num().String(), expiry, o.status,
		); err != nil {
			t.Fatalf("insert order %d: %v", i, err)
		}
	}

	// Fills, oldest first. The aggressor side is the taker's side in cNGN.
	now := time.Now()
	for i, fill := range []struct{ price, size, aggressor string }{
		{"0.0005", "2000", "sell"}, // 2000 cNGN for 1 USDC, type sell
		{"0.0004", "2500", "buy"},  // 2500 cNGN for 1 USDC, type buy
	} {
		if _, err := pool.Exec(ctx, `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id, created_at)
values ($1, $2, $3, $4, $5, $6, $7, $8)`,
			asset, subID, fill.price, fill.size, fill.aggressor,
			fmt.Sprintf("integrations-taker-%d-%d", stamp, i), fmt.Sprintf("integrations-maker-%d-%d", stamp, i),
			now.Add(time.Duration(i-2)*time.Minute),
		); err != nil {
			t.Fatalf("insert fill %d: %v", i, err)
		}
	}

	cfg := config.Config{CNGNSpotAssetAddress: asset}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	get := func(handler http.HandlerFunc, target string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		handler(rec, httptest.NewRequest(http.MethodGet, target, nil))
		return rec
	}

	t.Run("orderbook bids buy cNGN and asks sell it, aggregated and rounded away from the touch", func(t *testing.T) {
		rec := get(server.handleIntegrationOrderbook, "/v1/integrations/orderbook?ticker_id=USDCcNGN-SPOT")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got integrationOrderbookResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		wantBids := []integrationLevel{{"0.00025", "3000"}, {"0.0002", "5000"}, {"0.00015", "6000"}}
		wantAsks := []integrationLevel{{"0.0003", "3000"}, {"0.0004", "2500"}, {"0.0005", "3000"}}
		if !reflect.DeepEqual(got.Bids, wantBids) {
			t.Errorf("bids = %v, want %v", got.Bids, wantBids)
		}
		if !reflect.DeepEqual(got.Asks, wantAsks) {
			t.Errorf("asks = %v, want %v", got.Asks, wantAsks)
		}
		if got.TickerID != "USDCcNGN-SPOT" || got.Timestamp == 0 {
			t.Errorf("ticker_id/timestamp = %q/%d", got.TickerID, got.Timestamp)
		}
	})

	t.Run("orderbook depth counts levels, not orders", func(t *testing.T) {
		rec := get(server.handleIntegrationOrderbook, "/v1/integrations/orderbook?ticker_id=USDCcNGN-SPOT&depth=2")
		var got integrationOrderbookResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v body=%s", err, rec.Body.String())
		}
		// Ask 0.0005 holds two orders; depth 3 would include it whole, depth 2 must stop before it.
		wantAsks := []integrationLevel{{"0.0003", "3000"}, {"0.0004", "2500"}}
		if !reflect.DeepEqual(got.Asks, wantAsks) {
			t.Errorf("asks = %v, want %v", got.Asks, wantAsks)
		}
		if len(got.Bids) != 2 {
			t.Errorf("bids = %v, want 2 levels", got.Bids)
		}
	})

	t.Run("tickers report cNGN base volume and match the orderbook touch", func(t *testing.T) {
		rec := get(server.handleIntegrationTickers, "/v1/integrations/tickers")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got []integrationTicker
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if len(got) != 1 {
			t.Fatalf("got %d tickers, want 1: %s", len(got), rec.Body.String())
		}
		ticker := got[0]
		str := func(p *string) string {
			if p == nil {
				return "<nil>"
			}
			return *p
		}
		checks := []struct{ field, got, want string }{
			{"ticker_id", ticker.TickerID, "USDCcNGN-SPOT"},
			{"base_currency", ticker.BaseCurrency, "cNGN"},
			{"target_currency", ticker.TargetCurrency, "USDC"},
			// 2000 + 2500 cNGN, for 1 + 1 USDC.
			{"base_volume", ticker.BaseVolume, "4500"},
			{"target_volume", ticker.TargetVolume, "2"},
			{"last_price", str(ticker.LastPrice), "0.0004"},
			{"high", str(ticker.High), "0.0005"},
			{"low", str(ticker.Low), "0.0004"},
			{"bid", str(ticker.Bid), "0.00025"},
			{"ask", str(ticker.Ask), "0.0003"},
		}
		for _, c := range checks {
			if c.got != c.want {
				t.Errorf("%s = %s, want %s", c.field, c.got, c.want)
			}
		}
	})

	t.Run("trades are priced in USDC per cNGN with the taker's cNGN side", func(t *testing.T) {
		rec := get(server.handleIntegrationTrades, "/v1/integrations/trades?ticker_id=USDCcNGN-SPOT")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got integrationTradesResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if len(got.Trades) != 2 {
			t.Fatalf("got %d trades, want 2: %s", len(got.Trades), rec.Body.String())
		}
		type view struct{ price, base, target, side string }
		gotViews := []view{}
		for _, trade := range got.Trades {
			gotViews = append(gotViews, view{trade.Price, trade.BaseVolume, trade.TargetVolume, string(trade.Type)})
		}
		// Newest first.
		want := []view{{"0.0004", "2500", "1", "buy"}, {"0.0005", "2000", "1", "sell"}}
		if !reflect.DeepEqual(gotViews, want) {
			t.Errorf("trades = %v, want %v", gotViews, want)
		}
	})

	t.Run("rejects missing or unknown tickers instead of falling back to a default", func(t *testing.T) {
		for _, target := range []string{
			"/v1/integrations/orderbook",
			"/v1/integrations/orderbook?ticker_id=BTC-PERP",
			"/v1/integrations/orderbook?ticker_id=USDCcNGN-SPOT&depth=0",
			"/v1/integrations/orderbook?ticker_id=USDCcNGN-SPOT&depth=501",
			"/v1/integrations/trades?ticker_id=nope",
			"/v1/integrations/trades?ticker_id=USDCcNGN-SPOT&limit=501",
			"/v1/integrations/trades?ticker_id=USDCcNGN-SPOT&before_trade_id=-1",
		} {
			handler := server.handleIntegrationOrderbook
			if strings.HasPrefix(target, "/v1/integrations/trades") {
				handler = server.handleIntegrationTrades
			}
			if rec := get(handler, target); rec.Code != http.StatusBadRequest {
				t.Errorf("%s -> status %d, want 400", target, rec.Code)
			}
		}
	})
}

func TestFormatDecimalDirectedRoundsTowardTheRequestedSide(t *testing.T) {
	third, _ := new(big.Rat).SetString("10/3")
	if got := formatDecimalDirected(third, 6, false); got != "3.333333" {
		t.Errorf("down = %s", got)
	}
	if got := formatDecimalDirected(third, 6, true); got != "3.333334" {
		t.Errorf("up = %s", got)
	}
	exact, _ := new(big.Rat).SetString("2500")
	if got := formatDecimalDirected(exact, 6, true); got != "2500" {
		t.Errorf("an exact value must not be rounded up: %s", got)
	}
}
