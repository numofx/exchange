package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/events"
	"github.com/numofx/matching-backend/internal/instruments"
)

const (
	resolutionSpotAsset = "0xf000000000000000000000000000000000000123"
	resolutionPerpAsset = "0xf000000000000000000000000000000000000456"
)

func resolutionServer(t *testing.T) *Server {
	t.Helper()
	cfg := config.Config{
		CNGNSpotAssetAddress: resolutionSpotAsset,
		CNGNPerpAssetAddress: resolutionPerpAsset,
	}
	// No pool: every request below must be refused before any storage is touched.
	return NewServer(cfg, nil, instruments.DefaultRegistry(cfg))
}

// Every market identifier the REST market-data endpoints might be sent that is not one the venue
// lists. GET /v1/book?symbol=cNGN-PERP once returned the spot book under that name; each of these
// must now be a 400 that names the identifiers the venue accepts.
var unknownMarketQueries = []string{
	"symbol=cNGN-PERP",
	"symbol=cNGN-USDC",
	"symbol=usdccngn-spot",
	"symbol=USDCcNGN",
	"symbol=USDCcNGN-SPOT-",
	"symbol=BTC-PERP",
	"symbol=cNGN-PERP&asset_address=" + resolutionSpotAsset, // a bad symbol is not rescued by a good address
	"asset_address=0xf000000000000000000000000000000000000999",
	"asset_address=" + resolutionSpotAsset + "&sub_id=7",
	"", // no market named at all: no default
}

func TestMarketDataEndpointsRefuseUnknownMarkets(t *testing.T) {
	server := resolutionServer(t)
	handlers := map[string]http.HandlerFunc{
		"/v1/book":    server.handleBook,
		"/v1/trades":  server.handleTrades,
		"/v1/candles": server.handleCandles,
	}
	for path, handler := range handlers {
		for _, query := range unknownMarketQueries {
			rec := httptest.NewRecorder()
			handler(rec, httptest.NewRequest(http.MethodGet, path+"?"+query, nil))
			if rec.Code != http.StatusBadRequest {
				t.Errorf("GET %s?%s = %d, want 400: %s", path, query, rec.Code, rec.Body.String())
				continue
			}
			var body unknownMarketResponse
			if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
				t.Errorf("GET %s?%s: decode %v: %s", path, query, err, rec.Body.String())
				continue
			}
			if body.Error != "unknown_market" {
				t.Errorf("GET %s?%s error = %q", path, query, body.Error)
			}
			if len(body.Markets) != 2 || body.Markets[0] != instruments.CNGNSpotSymbol || body.Markets[1] != instruments.CNGNPerpSymbol {
				t.Errorf("GET %s?%s markets = %v", path, query, body.Markets)
			}
		}
	}
}

func TestResolveMarketAcceptsListedIdentifiersOnly(t *testing.T) {
	server := resolutionServer(t)
	cases := map[string]string{
		"symbol=" + instruments.CNGNSpotSymbol:                     instruments.CNGNSpotSymbol,
		"symbol=" + instruments.CNGNPerpSymbol:                     instruments.CNGNPerpSymbol,
		"asset_address=" + resolutionSpotAsset:                     instruments.CNGNSpotSymbol,
		"asset_address=" + resolutionPerpAsset + "&sub_id=0":       instruments.CNGNPerpSymbol,
		"asset_address=0xF000000000000000000000000000000000000456": instruments.CNGNPerpSymbol,
	}
	for query, want := range cases {
		rec := httptest.NewRecorder()
		market, ok := server.resolveMarket(rec, httptest.NewRequest(http.MethodGet, "/v1/book?"+query, nil))
		if !ok || market.Symbol != want {
			t.Errorf("resolveMarket(%q) = %q, %v; want %q (%s)", query, market.Symbol, ok, want, rec.Body.String())
		}
	}

	// The spot and the perp never cross: each symbol resolves to its own asset.
	spot, _ := server.resolveMarket(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/book?symbol="+instruments.CNGNSpotSymbol, nil))
	perp, _ := server.resolveMarket(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/book?symbol="+instruments.CNGNPerpSymbol, nil))
	if spot.AssetAddress != resolutionSpotAsset || perp.AssetAddress != resolutionPerpAsset {
		t.Fatalf("spot -> %s, perp -> %s", spot.AssetAddress, perp.AssetAddress)
	}
}

func TestIntegrationEndpointsRefuseUnknownTickers(t *testing.T) {
	server := resolutionServer(t)
	handlers := map[string]http.HandlerFunc{
		"/v1/integrations/orderbook": server.handleIntegrationOrderbook,
		"/v1/integrations/trades":    server.handleIntegrationTrades,
	}
	for path, handler := range handlers {
		for _, ticker := range []string{"cNGN-PERP", "cNGN-USDC", "usdccngn-spot", "USDCcNGN", "BTC-PERP"} {
			rec := httptest.NewRecorder()
			handler(rec, httptest.NewRequest(http.MethodGet, path+"?ticker_id="+ticker, nil))
			if rec.Code != http.StatusBadRequest {
				t.Errorf("GET %s?ticker_id=%s = %d, want 400: %s", path, ticker, rec.Code, rec.Body.String())
			}
		}
	}
}

// The websocket resolver is the same lookup: an unknown market is an unknown_market error frame,
// for a public channel and for scoping the orders channel alike.
func TestWebsocketSubscribeRefusesUnknownMarkets(t *testing.T) {
	server := resolutionServer(t)
	for _, market := range []string{"cNGN-PERP", "cNGN-USDC", "usdccngn-spot", "USDCcNGN", "BTC-PERP", ""} {
		for _, channel := range []string{events.ChannelBook, events.ChannelTrades, events.ChannelOrders} {
			c := &wsConn{srv: server, out: make(chan wsOut, 1), subs: map[string]*wsSubscription{}, owner: "0xowner"}
			if channel == events.ChannelOrders && market == "" {
				continue // an unscoped orders subscription names no market
			}
			if _, _, ok := c.buildFilter(channel, market); ok {
				t.Errorf("subscribe %s %q accepted", channel, market)
				continue
			}
			frame := <-c.out
			if frame.Type != "error" || frame.Code != "unknown_market" || frame.Market != market {
				t.Errorf("subscribe %s %q: frame %+v", channel, market, frame)
			}
		}
	}

	c := &wsConn{srv: server, out: make(chan wsOut, 1), subs: map[string]*wsSubscription{}}
	filter, meta, ok := c.buildFilter(events.ChannelBook, instruments.CNGNPerpSymbol)
	if !ok || meta.Symbol != instruments.CNGNPerpSymbol || filter.Market != resolutionPerpAsset+":0" {
		t.Fatalf("subscribe book %s: ok=%v meta=%q filter=%+v", instruments.CNGNPerpSymbol, ok, meta.Symbol, filter)
	}
}
