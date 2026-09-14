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

// The integration endpoints exist because the native ones report USDCcNGN-SPOT in engine terms
// (cNGN priced in USDC) while /v1/markets advertises USDC/cNGN. Every expected value below is
// written in the advertised orientation and worked out by hand from the engine rows seeded, so a
// handler that passes engine values through, or inverts only some of them, fails here.
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
		// Engine sells of cNGN are orders buying USDC: the advertised bids.
		{"sell", "0.0003", "3000", "0", "active"},    // bid 3333.333333… rounds down; 0.9 USDC
		{"sell", "0.0004", "2500", "0", "active"},    // bid 2500; 1 USDC
		{"sell", "0.0005", "2000", "0", "active"},    // bid 2000; 1 USDC …
		{"sell", "0.0005", "1000", "0", "active"},    // … same level, +0.5 USDC
		{"sell", "0.0002", "9000", "0", "cancelled"}, // not resting: must not appear
		// Engine buys of cNGN are orders selling USDC: the advertised asks.
		{"buy", "0.00025", "4000", "1000", "active"}, // ask 4000; remaining 3000 cNGN = 0.75 USDC
		{"buy", "0.0002", "5000", "0", "active"},     // ask 5000; 1 USDC
		{"buy", "0.00015", "6000", "0", "active"},    // ask 6666.666666… rounds up; 0.9 USDC
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

	// Fills, oldest first. Engine sell aggressor = taker bought USDC.
	now := time.Now()
	for i, fill := range []struct{ price, size, aggressor string }{
		{"0.0005", "2000", "sell"}, // price 2000, 1 USDC, 2000 cNGN, type buy
		{"0.0004", "2500", "buy"},  // price 2500, 1 USDC, 2500 cNGN, type sell
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

	t.Run("orderbook bids buy USDC and asks sell it, aggregated and rounded away from the touch", func(t *testing.T) {
		rec := get(server.handleIntegrationOrderbook, "/v1/integrations/orderbook?ticker_id=USDCcNGN-SPOT")
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var got integrationOrderbookResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		wantBids := []integrationLevel{{"3333.333333", "0.9"}, {"2500", "1"}, {"2000", "1.5"}}
		wantAsks := []integrationLevel{{"4000", "0.75"}, {"5000", "1"}, {"6666.666667", "0.9"}}
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
		// Level 2000 holds two orders; depth 3 would include it whole, depth 2 must stop before it.
		wantBids := []integrationLevel{{"3333.333333", "0.9"}, {"2500", "1"}}
		if !reflect.DeepEqual(got.Bids, wantBids) {
			t.Errorf("bids = %v, want %v", got.Bids, wantBids)
		}
		if len(got.Asks) != 2 {
			t.Errorf("asks = %v, want 2 levels", got.Asks)
		}
	})

	t.Run("tickers report USDC base volume and match the orderbook touch", func(t *testing.T) {
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
			{"base_currency", ticker.BaseCurrency, "USDC"},
			{"target_currency", ticker.TargetCurrency, "cNGN"},
			// 1 + 1 USDC. The native stats_24h.volume for the same fills is 4500.
			{"base_volume", ticker.BaseVolume, "2"},
			{"target_volume", ticker.TargetVolume, "4500"},
			{"last_price", str(ticker.LastPrice), "2500"},
			// Engine high 0.0005 is the advertised low, and engine low 0.0004 the high.
			{"high", str(ticker.High), "2500"},
			{"low", str(ticker.Low), "2000"},
			{"bid", str(ticker.Bid), "3333.333333"},
			{"ask", str(ticker.Ask), "4000"},
		}
		for _, c := range checks {
			if c.got != c.want {
				t.Errorf("%s = %s, want %s", c.field, c.got, c.want)
			}
		}
	})

	t.Run("trades are priced in cNGN per USDC with the taker's USDC side", func(t *testing.T) {
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
		want := []view{{"2500", "1", "2500", "sell"}, {"2000", "1", "2000", "buy"}}
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
