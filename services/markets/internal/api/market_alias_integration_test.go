package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

// The market-data endpoints answer the canonical identifier and its deprecated alias with the same
// data, name the market canonically either way, and flag only the alias as deprecated. Spot and the
// perp each resolve to their own book: the two never cross.
func TestMarketDataEndpointsAnswerAliasesLikeCanonicalNames(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	stamp := time.Now().UnixNano()
	spotAsset := fmt.Sprintf("0x%040x", stamp)
	perpAsset := fmt.Sprintf("0x%040x", stamp+1)

	t.Cleanup(func() {
		for _, asset := range []string{spotAsset, perpAsset} {
			if _, err := pool.Exec(ctx, "delete from active_orders where asset_address = $1", asset); err != nil {
				t.Errorf("cleanup active_orders: %v", err)
			}
		}
	})

	// One resting engine order per market, at distinguishable sizes.
	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, '0xowner', '0xowner', 6, 6, $2, 'buy', $3, '0', $4, '0', '0.0007', '700000000000000', '0', $5, '{}'::jsonb, '0xsig', 'active')
`
	expiry := time.Now().Add(time.Hour).Unix()
	for i, seed := range []struct{ asset, size string }{{spotAsset, "1111"}, {perpAsset, "2222"}} {
		if _, err := pool.Exec(ctx, insertOrder, fmt.Sprintf("alias-%d-%d", stamp, i), fmt.Sprintf("%d%02d", stamp, i), seed.asset, seed.size, expiry); err != nil {
			t.Fatalf("seed order: %v", err)
		}
	}

	cfg := config.Config{CNGNSpotAssetAddress: spotAsset, CNGNPerpAssetAddress: perpAsset}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	get := func(handler http.HandlerFunc, target string) *httptest.ResponseRecorder {
		t.Helper()
		rec := httptest.NewRecorder()
		handler(rec, httptest.NewRequest(http.MethodGet, target, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("GET %s: status=%d body=%s", target, rec.Code, rec.Body.String())
		}
		return rec
	}

	markets := []struct {
		canonical, alias, asset, size string
	}{
		{"cNGN-USDC", "USDCcNGN-SPOT", spotAsset, "1111"},
		{"cNGN-PERP", "USDCcNGN-PERP", perpAsset, "2222"},
	}
	endpoints := []struct {
		path    string
		handler http.HandlerFunc
	}{
		{"/v1/book", server.handleBook},
		{"/v1/trades", server.handleTrades},
		{"/v1/candles", server.handleCandles},
	}
	for _, market := range markets {
		for _, endpoint := range endpoints {
			canonical := get(endpoint.handler, endpoint.path+"?symbol="+market.canonical)
			alias := get(endpoint.handler, endpoint.path+"?symbol="+market.alias)
			byAsset := get(endpoint.handler, endpoint.path+"?asset_address="+market.asset+"&sub_id=0")

			if canonical.Body.String() != alias.Body.String() || canonical.Body.String() != byAsset.Body.String() {
				t.Errorf("%s %s: bodies differ by identifier\ncanonical=%s\nalias=%s\nasset=%s",
					endpoint.path, market.canonical, canonical.Body.String(), alias.Body.String(), byAsset.Body.String())
			}
			var named struct {
				MarketPresentation marketPresentation `json:"market_presentation"`
			}
			if err := json.Unmarshal(alias.Body.Bytes(), &named); err != nil {
				t.Fatalf("%s: decode: %v", endpoint.path, err)
			}
			if named.MarketPresentation.Market != market.canonical {
				t.Errorf("%s asked as %s: market = %q, want %q", endpoint.path, market.alias, named.MarketPresentation.Market, market.canonical)
			}
			if canonical.Header().Get("Deprecation") != "" || byAsset.Header().Get("Deprecation") != "" {
				t.Errorf("%s %s: a non-deprecated identifier was flagged", endpoint.path, market.canonical)
			}
			if alias.Header().Get("Deprecation") != "true" || alias.Header().Get("X-Canonical-Market") != market.canonical {
				t.Errorf("%s %s: alias headers = %v", endpoint.path, market.alias, alias.Header())
			}
		}

		// The book served under either name is this market's own: its seeded size, not the other's.
		book := get(server.handleBook, "/v1/book?symbol="+market.alias).Body.String()
		if !strings.Contains(book, `"`+market.size+`"`) {
			t.Errorf("book for %s lacks its own order (%s): %s", market.alias, market.size, book)
		}
		for _, other := range markets {
			if other.canonical != market.canonical && strings.Contains(book, `"`+other.size+`"`) {
				t.Errorf("book for %s carries %s's order: %s", market.alias, other.canonical, book)
			}
		}
	}

	// /v1/markets lists the canonical names only.
	rec := get(server.handleMarkets, "/v1/markets")
	var listed []marketPresentation
	if err := json.Unmarshal(rec.Body.Bytes(), &listed); err != nil {
		t.Fatalf("decode markets: %v", err)
	}
	var names []string
	for _, m := range listed {
		names = append(names, m.Market)
	}
	if strings.Join(names, ",") != "cNGN-PERP,cNGN-USDC" {
		t.Fatalf("/v1/markets lists %v", names)
	}
}

// A websocket subscription by deprecated alias delivers the market's stream with every frame named
// canonically, and the same subscription can be dropped by its canonical name.
func TestWebsocketFramesCarryCanonicalMarketForAliasSubscriptions(t *testing.T) {
	pool := openTestPool(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	wsApplyMigrations(ctx, t, pool)

	asset := fmt.Sprintf("0x%040x", time.Now().UnixNano())
	cfg := config.Config{
		EventsReconcileInterval: 500 * time.Millisecond,
		EventsSubBuffer:         64,
		WSAuthDomain:            "markets.numo.xyz",
		WSAuthMaxTTL:            5 * time.Minute,
		CNGNSpotAssetAddress:    asset,
	}
	srv := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	go func() { _ = srv.hub.Run(ctx) }()
	time.Sleep(150 * time.Millisecond)

	httpSrv := httptest.NewServer(http.HandlerFunc(srv.handleWS))
	defer httpSrv.Close()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(httpSrv.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "done")

	writeJSONFrame(ctx, t, conn, map[string]any{"op": "subscribe", "channel": "book", "market": "USDCcNGN-SPOT"})
	snap := readFrame(ctx, t, conn)
	if snap.Type != "snapshot" || snap.Channel != "book" || snap.Market != "cNGN-USDC" {
		t.Fatalf("alias subscription snapshot = %+v, want market cNGN-USDC", snap)
	}
	if !strings.Contains(string(snap.Data), `"market":"cNGN-USDC"`) {
		t.Fatalf("snapshot payload names the market %s", snap.Data)
	}

	// Dropped by canonical name: the alias and the canonical name are one subscription.
	writeJSONFrame(ctx, t, conn, map[string]any{"op": "unsubscribe", "channel": "book", "market": "cNGN-USDC"})
	if ack := readFrame(ctx, t, conn); ack.Type != "ack" || ack.Market != "cNGN-USDC" || ack.Message != "unsubscribed" {
		t.Fatalf("unsubscribe by canonical name: %+v", ack)
	}

	// The asset form is the same subscription too, and is also named canonically.
	writeJSONFrame(ctx, t, conn, map[string]any{"op": "subscribe", "channel": "trades", "market": asset + ":0"})
	if snap := readFrame(ctx, t, conn); snap.Type != "snapshot" || snap.Channel != "trades" || snap.Market != "cNGN-USDC" {
		t.Fatalf("asset-form subscription snapshot = %+v", snap)
	}
	writeJSONFrame(ctx, t, conn, map[string]any{"op": "unsubscribe", "channel": "trades", "market": "USDCcNGN-SPOT"})
	if ack := readFrame(ctx, t, conn); ack.Type != "ack" || ack.Market != "cNGN-USDC" {
		t.Fatalf("unsubscribe by alias: %+v", ack)
	}
}
