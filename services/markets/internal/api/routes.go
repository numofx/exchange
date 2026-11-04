package api

import "github.com/go-chi/chi/v5"

// routes builds the router Run serves. It is separate from Run so tests can drive requests through
// the real routing, and so the integration cache is provably in front of those endpoints rather
// than only present in the package.
func (s *Server) routes(integrations *integrationCache) chi.Router {
	router := chi.NewRouter()
	router.Get("/healthz", s.handleHealth)
	router.Get("/debug/markets", s.handleMarketDiagnostics)
	router.Get("/health", s.handleHealthReport)
	router.Get("/markets", s.handleMarkets)
	router.Get("/book", s.handleBook)
	router.Get("/trades", s.handleTrades)
	router.Get("/candles", s.handleCandles)
	router.Get("/integrations/tickers", integrations.wrap(s.handleIntegrationTickers))
	router.Get("/integrations/orderbook", integrations.wrap(s.handleIntegrationOrderbook, "ticker_id", "depth"))
	router.Get("/integrations/trades", integrations.wrap(s.handleIntegrationTrades, "ticker_id", "limit", "before_trade_id"))
	router.Get("/orders", s.handleOrderHistory)
	router.Get("/fills", s.handleFills)
	router.Get("/positions", s.handlePositions)
	router.Get("/orders/{order_id}", s.handleGetOrderStatus)
	router.Post("/orders", s.handleCreateOrder)
	router.Post("/orders/cancel", s.handleCancelOrder)
	router.Post("/withdrawals", s.handleCreateWithdrawal)
	router.Post("/deposits", s.handleCreateDeposit)
	router.Get("/deposits/{action_hash}", s.handleGetDeposit)
	router.Get("/ws", s.handleWS)
	// The publisher's report is not public API, so it stays where the publisher calls it.
	router.Post("/v1/internal/index-status", s.handleIndexStatus)
	return router
}
