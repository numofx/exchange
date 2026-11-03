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

// The public API is served unprefixed and under the older /v1, and a route added to one must be on the
// other: clients move across one at a time, so the two cannot drift apart while both are served.
func TestEveryPublicRouteIsServedWithAndWithoutV1(t *testing.T) {
	routes := registeredRoutes(t, routeTestRouter())

	for _, want := range []string{
		"GET /health", "GET /markets", "GET /book", "GET /trades", "GET /candles",
		"GET /integrations/tickers", "GET /integrations/orderbook", "GET /integrations/trades",
		"GET /orders", "GET /fills", "GET /positions", "GET /orders/{order_id}",
		"POST /orders", "POST /orders/cancel", "POST /withdrawals", "POST /deposits",
		"GET /deposits/{action_hash}", "GET /ws",
	} {
		method, path, _ := strings.Cut(want, " ")
		if !routes[want] {
			t.Errorf("%s is not routed", want)
		}
		if !routes[method+" /v1"+path] {
			t.Errorf("%s /v1%s is not routed", method, path)
		}
	}

	// The same both ways round for whatever this list does not name yet.
	unversioned := map[string]bool{"GET /healthz": true, "GET /debug/markets": true}
	for route := range routes {
		method, path, _ := strings.Cut(route, " ")
		if rest, ok := strings.CutPrefix(path, "/v1/"); ok {
			if rest != "internal/index-status" && !routes[method+" /"+rest] {
				t.Errorf("%s has no unprefixed route", route)
			}
		} else if !unversioned[route] && !routes[method+" /v1"+path] {
			t.Errorf("%s has no /v1 route", route)
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

// Real requests through the real router: each path must reach the same handler, parameters included.
func TestBothPathsAnswerAlike(t *testing.T) {
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
			serve := func(path string) *httptest.ResponseRecorder {
				rec := httptest.NewRecorder()
				router.ServeHTTP(rec, httptest.NewRequest(tc.method, path, strings.NewReader(tc.body)))
				return rec
			}
			bare, versioned := serve(tc.path), serve("/v1"+tc.path)
			if bare.Code != tc.status {
				t.Errorf("%s = %d, want %d: %s", tc.path, bare.Code, tc.status, bare.Body.String())
			}
			if versioned.Code != bare.Code || versioned.Body.String() != bare.Body.String() {
				t.Errorf("/v1%s = %d %q, %s = %d %q", tc.path, versioned.Code, versioned.Body.String(), tc.path, bare.Code, bare.Body.String())
			}
		})
	}
}
