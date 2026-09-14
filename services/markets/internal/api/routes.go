package api

import "github.com/go-chi/chi/v5"

// routes builds the router Run serves. It is separate from Run so tests can drive requests through
// the real routing, and so the integration cache is provably in front of those endpoints rather
// than only present in the package.
func (s *Server) routes(integrations *integrationCache) chi.Router {
	router := chi.NewRouter()
	router.Get("/healthz", s.handleHealth)
	router.Get("/v1/markets", s.handleMarkets)
	router.Get("/v1/book", s.handleBook)
	router.Get("/v1/trades", s.handleTrades)
	router.Get("/v1/candles", s.handleCandles)
	router.Get("/v1/integrations/tickers", integrations.wrap(s.handleIntegrationTickers))
	router.Get("/v1/integrations/orderbook", integrations.wrap(s.handleIntegrationOrderbook, "ticker_id", "depth"))
	router.Get("/v1/integrations/trades", integrations.wrap(s.handleIntegrationTrades, "ticker_id", "limit", "before_trade_id"))
	router.Get("/v1/orders", s.handleOrderHistory)
	router.Get("/v1/fills", s.handleFills)
	router.Get("/v1/orders/{order_id}", s.handleGetOrderStatus)
	router.Get("/debug/markets", s.handleMarketDiagnostics)
	router.Post("/v1/orders", s.handleCreateOrder)
	router.Post("/v1/orders/cancel", s.handleCancelOrder)
	router.Post("/v1/withdrawals", s.handleCreateWithdrawal)
	router.Get("/v1/ws", s.handleWS)
	return router
}
