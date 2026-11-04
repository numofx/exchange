package api

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

func routeTestRouter() chi.Router {
	cfg := config.Config{CNGNSpotAssetAddress: "0xf000000000000000000000000000000000000123"}
	server := NewServer(cfg, nil, instruments.DefaultRegistry(cfg))
	return server.routes(newIntegrationCache(5*time.Second, time.Now))
}

func registeredRoutes(t *testing.T, router chi.Router) map[string]bool {
	t.Helper()
	routes := map[string]bool{}
	err := chi.Walk(router, func(method, route string, _ http.Handler, _ ...func(http.Handler) http.Handler) error {
		routes[method+" "+route] = true
		return nil
	})
	if err != nil {
		t.Fatalf("walk routes: %v", err)
	}
	return routes
}

// The public API has no version prefix. A route under /v1 would be a client depending on a path that was retired on
// 2026-11-04, so anything but the publisher's report under it is a mistake.
func TestPublicRoutesAreUnprefixedAndV1IsGone(t *testing.T) {
	router := routeTestRouter()
	routes := registeredRoutes(t, router)

	public := []string{
		"GET /health", "GET /markets", "GET /book", "GET /trades", "GET /candles",
		"GET /integrations/tickers", "GET /integrations/orderbook", "GET /integrations/trades",
		"GET /orders", "GET /fills", "GET /positions", "GET /orders/{order_id}",
		"POST /orders", "POST /orders/cancel", "POST /withdrawals", "POST /deposits",
		"GET /deposits/{action_hash}", "GET /ws",
	}
	for _, want := range public {
		if !routes[want] {
			t.Errorf("%s is not routed", want)
		}
	}
	for route := range routes {
		_, path, _ := strings.Cut(route, " ")
		if strings.HasPrefix(path, "/v1") && route != "POST /v1/internal/index-status" {
			t.Errorf("%s is still routed under /v1", route)
		}
	}
	// Through the real router too, since a walk would not see a catch-all or a mount.
	for _, want := range public {
		method, path, _ := strings.Cut(want, " ")
		rec := httptest.NewRecorder()
		router.ServeHTTP(rec, httptest.NewRequest(method, "/v1"+strings.ReplaceAll(path, "{order_id}", "x"), nil))
		if rec.Code != http.StatusNotFound && rec.Code != http.StatusMethodNotAllowed {
			t.Errorf("%s /v1%s = %d, want it gone", method, path, rec.Code)
		}
	}
}

// The publisher's report is not part of the public API, so it does not gain a public path.
func TestInternalRouteIsNotServedUnprefixed(t *testing.T) {
	router := routeTestRouter()
	routes := registeredRoutes(t, router)
	if !routes["POST /v1/internal/index-status"] {
		t.Error("POST /v1/internal/index-status is not routed")
	}
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/internal/index-status", strings.NewReader("{}")))
	if rec.Code != http.StatusNotFound {
		t.Errorf("POST /internal/index-status = %d, want 404", rec.Code)
	}
}

// Real requests through the real router: each path must reach its handler, parameters included.
func TestPublicPathsReachTheirHandlers(t *testing.T) {
	router := routeTestRouter()
	for _, tc := range []struct {
		method, path, body string
		status             int
	}{
		{http.MethodGet, "/markets", "", http.StatusOK},
		{http.MethodGet, "/book", "", http.StatusBadRequest},
		{http.MethodGet, "/trades", "", http.StatusBadRequest},
		{http.MethodGet, "/candles", "", http.StatusBadRequest},
		{http.MethodGet, "/positions", "", http.StatusBadRequest},
		{http.MethodGet, "/orders", "", http.StatusUnauthorized},
		{http.MethodGet, "/fills", "", http.StatusUnauthorized},
		{http.MethodPost, "/orders", "not json", http.StatusBadRequest},
		{http.MethodPost, "/orders/cancel", "{}", http.StatusBadRequest},
		{http.MethodPost, "/withdrawals", "{}", http.StatusServiceUnavailable},
		{http.MethodPost, "/deposits", "{}", http.StatusServiceUnavailable},
		{http.MethodGet, "/deposits/0xabc", "", http.StatusServiceUnavailable},
		{http.MethodGet, "/integrations/orderbook", "", http.StatusBadRequest},
	} {
		t.Run(tc.method+" "+tc.path, func(t *testing.T) {
			rec := httptest.NewRecorder()
			router.ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body)))
			if rec.Code != tc.status {
				t.Errorf("%s = %d, want %d: %s", tc.path, rec.Code, tc.status, rec.Body.String())
			}
		})
	}
}
