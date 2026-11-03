package api

import "github.com/go-chi/chi/v5"

// routes builds the router Run serves. It is separate from Run so tests can drive requests through
// the real routing, and so the integration cache is provably in front of those endpoints rather
// than only present in the package.
func (s *Server) routes(integrations *integrationCache) chi.Router {
	router := chi.NewRouter()
	router.Get("/healthz", s.handleHealth)
	router.Get("/debug/markets", s.handleMarketDiagnostics)
	// The public API, unprefixed and under the older /v1 while clients move across.
	for _, prefix := range []string{"", "/v1"} {
		router.Get(prefix+"/health", s.handleHealthReport)
		router.Get(prefix+"/markets", s.handleMarkets)
		router.Get(prefix+"/book", s.handleBook)
		router.Get(prefix+"/trades", s.handleTrades)
		router.Get(prefix+"/candles", s.handleCandles)
		router.Get(prefix+"/integrations/tickers", integrations.wrap(s.handleIntegrationTickers))
		router.Get(prefix+"/integrations/orderbook", integrations.wrap(s.handleIntegrationOrderbook, "ticker_id", "depth"))
		router.Get(prefix+"/integrations/trades", integrations.wrap(s.handleIntegrationTrades, "ticker_id", "limit", "before_trade_id"))
		router.Get(prefix+"/orders", s.handleOrderHistory)
		router.Get(prefix+"/fills", s.handleFills)
		router.Get(prefix+"/positions", s.handlePositions)
		router.Get(prefix+"/orders/{order_id}", s.handleGetOrderStatus)
		router.Post(prefix+"/orders", s.handleCreateOrder)
		router.Post(prefix+"/orders/cancel", s.handleCancelOrder)
		router.Post(prefix+"/withdrawals", s.handleCreateWithdrawal)
		router.Post(prefix+"/deposits", s.handleCreateDeposit)
		router.Get(prefix+"/deposits/{action_hash}", s.handleGetDeposit)
		router.Get(prefix+"/ws", s.handleWS)
	}
	// The publisher's report is not public API, so it stays where the publisher calls it.
	router.Post("/v1/internal/index-status", s.handleIndexStatus)
	return router
}
