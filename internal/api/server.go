package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

type Server struct {
	cfg         config.Config
	pool        *pgxpool.Pool
	orders      *orders.Repository
	instruments *instruments.Registry
	custody     custodyChecker
}

type marketPresentation struct {
	Market             string `json:"market"`
	ContractType       string `json:"contract_type,omitempty"`
	SettlementType     string `json:"settlement_type,omitempty"`
	BaseAssetSymbol    string `json:"base_asset_symbol,omitempty"`
	QuoteAssetSymbol   string `json:"quote_asset_symbol,omitempty"`
	ExpiryTimestamp    int64  `json:"expiry_timestamp,omitempty"`
	LastTradeTimestamp *int64 `json:"last_trade_timestamp"`
	PriceSemantics     string `json:"price_semantics,omitempty"`
	DisplaySemantics   string `json:"display_semantics,omitempty"`
	DisplayName        string `json:"display_name,omitempty"`
	DisplayLabel       string `json:"display_label,omitempty"`
	TickSize           string `json:"tick_size,omitempty"`
	SettlementNote     string `json:"settlement_note,omitempty"`
	PricingModel       string `json:"pricing_model,omitempty"`
	DisplayPriceKind   string `json:"display_price_kind,omitempty"`
	AssetAddress       string `json:"asset_address,omitempty"`
	SubID              string `json:"sub_id,omitempty"`
	OrderEntrySpec     string `json:"order_entry_spec,omitempty"`
	UIPriceUnit        string `json:"ui_price_unit,omitempty"`
	UISizeUnit         string `json:"ui_size_unit,omitempty"`
	UISideMeaning      string `json:"ui_side_meaning,omitempty"`
	EnginePriceUnit    string `json:"engine_price_unit,omitempty"`
	EngineAmountUnit   string `json:"engine_amount_unit,omitempty"`
	EngineSidePolicy   string `json:"engine_side_policy,omitempty"`
	UIPriceToEngine    string `json:"ui_price_to_engine,omitempty"`
	UISizeToEngine     string `json:"ui_size_to_engine,omitempty"`
}

type presentedOrder struct {
	OrderID          string                 `json:"order_id"`
	OwnerAddress     string                 `json:"owner_address"`
	SignerAddress    string                 `json:"signer_address"`
	SubaccountID     string                 `json:"subaccount_id"`
	RecipientID      string                 `json:"recipient_id"`
	Nonce            string                 `json:"nonce"`
	Side             orders.Side            `json:"side"`
	AssetAddress     string                 `json:"asset_address"`
	SubID            string                 `json:"sub_id"`
	DesiredAmount    string                 `json:"desired_amount"`
	FilledAmount     string                 `json:"filled_amount"`
	LimitPrice       string                 `json:"limit_price"`
	WorstFee         string                 `json:"worst_fee"`
	Expiry           int64                  `json:"expiry"`
	ActionJSON       json.RawMessage        `json:"action_json"`
	Signature        string                 `json:"signature"`
	Status           orders.Status          `json:"status"`
	CreatedAt        time.Time              `json:"created_at"`
	Market           string                 `json:"market,omitempty"`
	ContractType     string                 `json:"contract_type,omitempty"`
	SettlementType   string                 `json:"settlement_type,omitempty"`
	BaseAssetSymbol  string                 `json:"base_asset_symbol,omitempty"`
	QuoteAssetSymbol string                 `json:"quote_asset_symbol,omitempty"`
	ExpiryTimestamp  int64                  `json:"expiry_timestamp,omitempty"`
	PriceSemantics   string                 `json:"price_semantics,omitempty"`
	DisplayName      string                 `json:"display_name,omitempty"`
	DisplayLabel     string                 `json:"display_label,omitempty"`
	DisplaySemantic  string                 `json:"display_semantics,omitempty"`
	TickSize         string                 `json:"tick_size,omitempty"`
	SpotContract     *spotOrderContractEcho `json:"spot_contract,omitempty"`
}

type orderResponse struct {
	Order presentedOrder `json:"order"`
}

type orderStatusResponse struct {
	OrderID         string        `json:"order_id"`
	Status          orders.Status `json:"status"`
	FilledAmount    string        `json:"filled_amount"`
	RemainingAmount string        `json:"remaining_amount"`
	CancelReason    string        `json:"cancel_reason"`
	UpdatedAt       time.Time     `json:"updated_at"`
}

type bookResponse struct {
	MarketPresentation marketPresentation `json:"market_presentation"`
	Bids               []presentedOrder   `json:"bids"`
	Asks               []presentedOrder   `json:"asks"`
}

type presentedTrade struct {
	TradeID        int64                  `json:"trade_id"`
	AssetAddress   string                 `json:"asset_address"`
	SubID          string                 `json:"sub_id"`
	Price          string                 `json:"price"`
	Size           string                 `json:"size"`
	AggressorSide  orders.Side            `json:"aggressor_side"`
	TakerOrderID   string                 `json:"taker_order_id,omitempty"`
	MakerOrderID   string                 `json:"maker_order_id,omitempty"`
	CreatedAt      time.Time              `json:"created_at"`
	ContractType   string                 `json:"contract_type,omitempty"`
	SettlementType string                 `json:"settlement_type,omitempty"`
	Market         string                 `json:"market,omitempty"`
	SpotContract   *spotOrderContractEcho `json:"spot_contract,omitempty"`
}

type presentedTradeStats struct {
	Change string `json:"change,omitempty"`
	High   string `json:"high,omitempty"`
	Last   string `json:"last,omitempty"`
	Low    string `json:"low,omitempty"`
	Volume string `json:"volume,omitempty"`
}

type tradesResponse struct {
	MarketPresentation marketPresentation  `json:"market_presentation"`
	Stats              presentedTradeStats `json:"stats_24h"`
	Trades             []presentedTrade    `json:"trades"`
	NextBeforeTradeID  int64               `json:"next_before_trade_id,omitempty"`
}

type marketDiagnosticsResponse struct {
	Market             string `json:"market"`
	AssetAddress       string `json:"asset_address"`
	SubID              string `json:"sub_id"`
	ContractType       string `json:"contract_type,omitempty"`
	SettlementType     string `json:"settlement_type,omitempty"`
	LoadedInMatcher    bool   `json:"loaded_in_matcher"`
	OpenBidCount       int32  `json:"open_bid_count"`
	OpenAskCount       int32  `json:"open_ask_count"`
	TradeCount         int64  `json:"trade_count"`
	LastTradeTimestamp *int64 `json:"last_trade_timestamp"`
}

func NewServer(cfg config.Config, pool *pgxpool.Pool, registry *instruments.Registry) *Server {
	return &Server{
		cfg:         cfg,
		pool:        pool,
		orders:      orders.NewRepository(pool),
		instruments: registry,
		custody:     newCustodyChecker(cfg),
	}
}

func (s *Server) Run() error {
	router := chi.NewRouter()
	router.Get("/healthz", s.handleHealth)
	router.Get("/v1/markets", s.handleMarkets)
	router.Get("/v1/book", s.handleBook)
	router.Get("/v1/trades", s.handleTrades)
	router.Get("/v1/orders/{order_id}", s.handleGetOrderStatus)
	router.Get("/debug/markets", s.handleMarketDiagnostics)
	router.Post("/v1/orders", s.handleCreateOrder)
	router.Post("/v1/orders/cancel", s.handleCancelOrder)

	s.logRegisteredMarkets()
	slog.Info(
		"custody_guard_config",
		"enabled", s.custody != nil,
		"enforce_matching_custody", s.cfg.EnforceMatchingCustody,
		"matching_address", strings.ToLower(strings.TrimSpace(s.cfg.MatchingAddress)),
		"chain_rpc_configured", strings.TrimSpace(s.cfg.ChainRPCURL) != "",
	)
	slog.Info("api listening", "addr", s.cfg.APIAddr)
	return http.ListenAndServe(s.cfg.APIAddr, router)
}

func (s *Server) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleMarkets(w http.ResponseWriter, r *http.Request) {
	if s.instruments == nil {
		writeJSON(w, http.StatusOK, []marketPresentation{})
		return
	}

	items := s.instruments.Enabled()
	sort.Slice(items, func(i, j int) bool {
		return items[i].Symbol < items[j].Symbol
	})

	response := make([]marketPresentation, 0, len(items))
	for _, item := range items {
		response = append(response, s.presentMarket(r.Context(), item))
	}

	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleBook(w http.ResponseWriter, r *http.Request) {
	market := s.resolveMarket(r)
	if market.AssetAddress == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown market"})
		return
	}

	bids, asks, err := s.orders.ListBook(r.Context(), strings.ToLower(market.AssetAddress), market.SubID, 25)
	if err != nil {
		slog.Error("list book", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load book"})
		return
	}
	s.logMarketQuery(r.Context(), "book_query", market)

	writeJSON(w, http.StatusOK, bookResponse{
		MarketPresentation: s.presentMarket(r.Context(), market),
		Bids:               presentOrders(bids, market),
		Asks:               presentOrders(asks, market),
	})
}

func (s *Server) handleTrades(w http.ResponseWriter, r *http.Request) {
	market := s.resolveMarket(r)
	if market.AssetAddress == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown market"})
		return
	}

	limit := int32(50)
	beforeTradeID := int64(0)
	if rawLimit := strings.TrimSpace(r.URL.Query().Get("limit")); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil || parsed <= 0 || parsed > 100 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "limit must be between 1 and 100"})
			return
		}
		limit = int32(parsed)
	}
	if rawBefore := strings.TrimSpace(r.URL.Query().Get("before_trade_id")); rawBefore != "" {
		parsed, err := strconv.ParseInt(rawBefore, 10, 64)
		if err != nil || parsed <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before_trade_id must be a positive integer"})
			return
		}
		beforeTradeID = parsed
	}

	items, err := s.orders.ListTrades(r.Context(), strings.ToLower(market.AssetAddress), market.SubID, beforeTradeID, limit)
	if err != nil {
		slog.Error("list trades", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load trades"})
		return
	}
	stats, err := s.orders.GetTradeStats24h(r.Context(), strings.ToLower(market.AssetAddress), market.SubID)
	if err != nil {
		slog.Error("trade stats", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load trades"})
		return
	}
	s.logMarketQuery(r.Context(), "trades_query", market)

	nextBeforeTradeID := int64(0)
	if len(items) == int(limit) {
		nextBeforeTradeID = items[len(items)-1].TradeID
	}

	writeJSON(w, http.StatusOK, tradesResponse{
		MarketPresentation: s.presentMarket(r.Context(), market),
		Stats:              presentTradeStats(stats),
		Trades:             presentTrades(items, market),
		NextBeforeTradeID:  nextBeforeTradeID,
	})
}

func (s *Server) handleGetOrderStatus(w http.ResponseWriter, r *http.Request) {
	orderID := strings.TrimSpace(chi.URLParam(r, "order_id"))
	if orderID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "order_id is required"})
		return
	}

	snapshot, err := s.orders.GetOrderStatusSnapshot(r.Context(), orderID)
	if err != nil {
		if errors.Is(err, orders.ErrNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "order not found"})
			return
		}
		slog.Error("load order status", "order_id", orderID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load order"})
		return
	}

	remaining, err := remainingAmountString(snapshot.DesiredAmount, snapshot.FilledAmount)
	if err != nil {
		slog.Error("compute remaining amount", "order_id", orderID, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to compute remaining amount"})
		return
	}

	writeJSON(w, http.StatusOK, orderStatusResponse{
		OrderID:         snapshot.OrderID,
		Status:          snapshot.Status,
		FilledAmount:    snapshot.FilledAmount,
		RemainingAmount: remaining,
		CancelReason:    snapshot.CancelReason,
		UpdatedAt:       snapshot.UpdatedAt.UTC(),
	})
}

func (s *Server) handleMarketDiagnostics(w http.ResponseWriter, r *http.Request) {
	if s.instruments == nil {
		writeJSON(w, http.StatusOK, []marketDiagnosticsResponse{})
		return
	}

	items := s.instruments.Enabled()
	sort.Slice(items, func(i, j int) bool {
		return items[i].Symbol < items[j].Symbol
	})

	response := make([]marketDiagnosticsResponse, 0, len(items))
	for _, item := range items {
		response = append(response, s.marketDiagnosticsPayload(r.Context(), item))
	}

	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	var req createOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}

	params, err := req.toParams(s.cfg)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	if s.custody != nil {
		if err := s.custody.ValidateDeposited(r.Context(), params.SubaccountID); err != nil {
			slog.Warn("order_submit_rejected_custody", "order_id", params.OrderID, "subaccount_id", params.SubaccountID, "error", err)
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
	}

	order, err := s.orders.Create(r.Context(), params)
	if err != nil {
		statusCode := http.StatusInternalServerError
		if strings.Contains(err.Error(), "duplicate order") {
			statusCode = http.StatusConflict
		}
		slog.Error("create order", "error", err)
		writeJSON(w, statusCode, map[string]string{"error": err.Error()})
		return
	}

	slog.Info(
		"order_submit_trace",
		"order_id", order.OrderID,
		"asset_address", strings.ToLower(order.AssetAddress),
		"sub_id", order.SubID,
		"side", order.Side,
		"desired_amount", order.DesiredAmount,
		"filled_amount", order.FilledAmount,
		"limit_price", order.LimitPrice,
		"limit_price_ticks", order.LimitPriceTicks,
		"status", order.Status,
	)

	instrument, _ := s.instruments.ByAssetAndSubID(strings.ToLower(order.AssetAddress), order.SubID)
	writeJSON(w, http.StatusCreated, orderResponse{Order: presentOrder(order, instrument)})
}

func (s *Server) handleCancelOrder(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid request body"})
		return
	}

	var req cancelOrderRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}

	requester := resolveCancelRequester(r)
	sourceIP := resolveSourceIP(r)
	internal := cancelInternalHeaders(r)
	slog.Info(
		"order_cancel_request",
		"body", string(body),
		"requester", requester,
		"service", strings.TrimSpace(req.Service),
		"user_agent", r.UserAgent(),
		"source_ip", sourceIP,
		"internal_headers", internal,
	)

	if err := req.validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	cancelParams := orders.CancelOrderParams{
		OwnerAddress: strings.ToLower(req.OwnerAddress),
		Nonce:        req.Nonce,
	}
	targetOrder, err := s.orders.FindActiveByOwnerNonce(r.Context(), cancelParams)
	if err != nil {
		if errors.Is(err, orders.ErrNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "active order not found"})
			return
		}
		slog.Error("load cancel target", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to resolve cancel target"})
		return
	}
	if err := s.validateCancelNamespace(req, targetOrder); err != nil {
		slog.Warn(
			"cancel_namespace_violation",
			"order_id", targetOrder.OrderID,
			"service", strings.TrimSpace(req.Service),
			"reason", strings.TrimSpace(req.Reason),
			"error", err,
		)
		writeJSON(w, http.StatusForbidden, map[string]string{"error": err.Error()})
		return
	}

	order, err := s.orders.CancelByOwnerNonce(r.Context(), cancelParams)
	if err != nil {
		if errors.Is(err, orders.ErrNotFound) {
			writeJSON(w, http.StatusNotFound, map[string]string{"error": "active order not found"})
			return
		}
		slog.Error("cancel order", "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to cancel order"})
		return
	}

	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "unspecified"
	}
	slog.Info(
		"order_cancel_trace",
		"order_id", order.OrderID,
		"owner", order.OwnerAddress,
		"request_owner", strings.ToLower(req.OwnerAddress),
		"requester", requester,
		"service", strings.TrimSpace(req.Service),
		"user_agent", r.UserAgent(),
		"source_ip", sourceIP,
		"internal_headers", internal,
		"reason", reason,
	)

	instrument, _ := s.instruments.ByAssetAndSubID(strings.ToLower(order.AssetAddress), order.SubID)
	writeJSON(w, http.StatusOK, orderResponse{Order: presentOrder(order, instrument)})
}

func (s *Server) validateCancelNamespace(req cancelOrderRequest, target orders.Order) error {
	service := strings.TrimSpace(req.Service)
	if service == "" {
		return nil
	}
	orderID := strings.ToLower(strings.TrimSpace(target.OrderID))
	for _, prefix := range s.cfg.CancelProtectedOrderPrefixes {
		if strings.HasPrefix(orderID, prefix) {
			return fmt.Errorf("service-tagged cancels are not allowed for protected namespace %q", prefix)
		}
	}
	return nil
}

func resolveCancelRequester(r *http.Request) string {
	candidates := []string{
		"X-Principal",
		"X-Authenticated-User",
		"X-Forwarded-User",
		"X-User",
		"X-User-ID",
	}
	for _, key := range candidates {
		if value := strings.TrimSpace(r.Header.Get(key)); value != "" {
			return value
		}
	}
	if value := strings.TrimSpace(r.Header.Get("Authorization")); value != "" {
		parts := strings.Fields(value)
		if len(parts) > 0 {
			return strings.ToLower(parts[0]) + "_token"
		}
		return "authorization_present"
	}
	return "anonymous"
}

func resolveSourceIP(r *http.Request) string {
	if forwarded := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); forwarded != "" {
		if parts := strings.Split(forwarded, ","); len(parts) > 0 {
			if ip := strings.TrimSpace(parts[0]); ip != "" {
				return ip
			}
		}
	}
	if realIP := strings.TrimSpace(r.Header.Get("X-Real-IP")); realIP != "" {
		return realIP
	}
	if cfIP := strings.TrimSpace(r.Header.Get("CF-Connecting-IP")); cfIP != "" {
		return cfIP
	}
	host, _, err := net.SplitHostPort(strings.TrimSpace(r.RemoteAddr))
	if err == nil && host != "" {
		return host
	}
	return strings.TrimSpace(r.RemoteAddr)
}

func cancelInternalHeaders(r *http.Request) map[string]string {
	keys := []string{
		"X-Forwarded-For",
		"X-Real-IP",
		"X-Forwarded-Proto",
		"X-Forwarded-Host",
		"X-Forwarded-Port",
		"X-Envoy-External-Address",
		"X-Request-ID",
		"X-Railway-Edge",
		"X-Railway-Request-ID",
		"Fly-Client-IP",
		"CF-Connecting-IP",
		"True-Client-IP",
	}
	headers := make(map[string]string)
	for _, key := range keys {
		if value := strings.TrimSpace(r.Header.Get(key)); value != "" {
			headers[key] = value
		}
	}
	return headers
}

func (s *Server) resolveMarket(r *http.Request) instruments.Metadata {
	if s.instruments == nil {
		return instruments.Metadata{}
	}

	if symbol := strings.TrimSpace(r.URL.Query().Get("symbol")); symbol != "" {
		if item, ok := s.instruments.BySymbol(symbol); ok {
			return item
		}
	}

	if assetAddress := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("asset_address"))); assetAddress != "" {
		subID := strings.TrimSpace(r.URL.Query().Get("sub_id"))
		if subID == "" {
			subID = "0"
		}
		if item, ok := s.instruments.ByAssetAndSubID(assetAddress, subID); ok {
			return item
		}
	}

	if item, ok := s.instruments.BySymbol(instruments.CNGNSpotSymbol); ok {
		return item
	}
	return instruments.Metadata{}
}

func writeJSON(w http.ResponseWriter, statusCode int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	_ = json.NewEncoder(w).Encode(payload)
}

func remainingAmountString(desired string, filled string) (string, error) {
	desiredInt, ok := new(big.Int).SetString(strings.TrimSpace(desired), 10)
	if !ok {
		return "", fmt.Errorf("invalid desired amount")
	}
	filledInt, ok := new(big.Int).SetString(strings.TrimSpace(filled), 10)
	if !ok {
		return "", fmt.Errorf("invalid filled amount")
	}
	remaining := new(big.Int).Sub(desiredInt, filledInt)
	if remaining.Sign() < 0 {
		return "", fmt.Errorf("filled amount exceeds desired amount")
	}
	return remaining.String(), nil
}

func presentOrders(items []orders.Order, instrument instruments.Metadata) []presentedOrder {
	if len(items) == 0 {
		return []presentedOrder{}
	}

	presented := make([]presentedOrder, 0, len(items))
	for _, item := range items {
		presented = append(presented, presentOrder(item, instrument))
	}
	return presented
}

func presentTrades(items []orders.TradeFill, instrument instruments.Metadata) []presentedTrade {
	if len(items) == 0 {
		return []presentedTrade{}
	}

	presented := make([]presentedTrade, 0, len(items))
	for _, item := range items {
		spotContract, _ := deriveSpotContractFromTrade(item, instrument)
		presented = append(presented, presentedTrade{
			TradeID:        item.TradeID,
			AssetAddress:   strings.ToLower(item.AssetAddress),
			SubID:          item.SubID,
			Price:          item.Price,
			Size:           item.Size,
			AggressorSide:  item.AggressorSide,
			TakerOrderID:   item.TakerOrderID,
			MakerOrderID:   item.MakerOrderID,
			CreatedAt:      item.CreatedAt,
			ContractType:   instrument.ContractType,
			SettlementType: instrument.SettlementType,
			Market:         instrument.Symbol,
			SpotContract:   spotContract,
		})
	}
	return presented
}

func presentTradeStats(stats orders.TradeStats24h) presentedTradeStats {
	return presentedTradeStats{
		Change: stats.Change,
		High:   stats.High,
		Last:   stats.Last,
		Low:    stats.Low,
		Volume: stats.Volume,
	}
}

func (s *Server) logRegisteredMarkets() {
	if s.instruments == nil {
		return
	}

	for _, item := range s.instruments.Enabled() {
		slog.Info(
			"market registered",
			"market", item.Symbol,
			"asset_address", item.AssetAddress,
			"sub_id", item.SubID,
			"contract_type", item.ContractType,
			"settlement_type", item.SettlementType,
			"loaded_in_matcher", item.Enabled,
		)
	}
}

func (s *Server) logMarketQuery(ctx context.Context, event string, market instruments.Metadata) {
	diagnostics := s.marketDiagnosticsPayload(ctx, market)
	slog.Info(
		event,
		"market", diagnostics.Market,
		"asset_address", diagnostics.AssetAddress,
		"sub_id", diagnostics.SubID,
		"loaded_in_matcher", diagnostics.LoadedInMatcher,
		"open_bid_count", diagnostics.OpenBidCount,
		"open_ask_count", diagnostics.OpenAskCount,
		"trade_count", diagnostics.TradeCount,
		"last_trade_timestamp", diagnostics.LastTradeTimestamp,
	)
}

func (s *Server) marketDiagnosticsPayload(ctx context.Context, market instruments.Metadata) marketDiagnosticsResponse {
	response := marketDiagnosticsResponse{
		Market:          market.Symbol,
		AssetAddress:    strings.ToLower(market.AssetAddress),
		SubID:           market.SubID,
		ContractType:    market.ContractType,
		SettlementType:  market.SettlementType,
		LoadedInMatcher: market.Enabled,
	}

	if s.pool == nil || s.orders == nil || market.AssetAddress == "" {
		return response
	}

	diagnostics, err := s.orders.GetMarketDiagnostics(ctx, market.AssetAddress, market.SubID)
	if err != nil {
		slog.Error("load market diagnostics", "market", market.Symbol, "error", err)
		return response
	}

	response.OpenBidCount = diagnostics.OpenBidCount
	response.OpenAskCount = diagnostics.OpenAskCount
	response.TradeCount = diagnostics.TradeCount
	if diagnostics.LastTradeTimestamp != nil {
		timestamp := diagnostics.LastTradeTimestamp.Unix()
		response.LastTradeTimestamp = &timestamp
	}

	return response
}

func presentOrder(order orders.Order, instrument instruments.Metadata) presentedOrder {
	spotContract, _ := deriveSpotContractFromOrder(order, instrument)
	presented := presentedOrder{
		OrderID:          order.OrderID,
		OwnerAddress:     order.OwnerAddress,
		SignerAddress:    order.SignerAddress,
		SubaccountID:     order.SubaccountID,
		RecipientID:      order.RecipientID,
		Nonce:            order.Nonce,
		Side:             order.Side,
		AssetAddress:     order.AssetAddress,
		SubID:            order.SubID,
		DesiredAmount:    order.DesiredAmount,
		FilledAmount:     order.FilledAmount,
		LimitPrice:       order.LimitPrice,
		WorstFee:         order.WorstFee,
		Expiry:           order.Expiry,
		ActionJSON:       order.ActionJSON,
		Signature:        order.Signature,
		Status:           order.Status,
		CreatedAt:        order.CreatedAt,
		Market:           instrument.Symbol,
		ContractType:     instrument.ContractType,
		SettlementType:   instrument.SettlementType,
		BaseAssetSymbol:  instrument.BaseAssetSymbol,
		QuoteAssetSymbol: instrument.QuoteAssetSymbol,
		ExpiryTimestamp:  instrument.ExpiryTimestamp,
		PriceSemantics:   instrument.PriceSemantics,
		DisplayName:      instrument.DisplayName,
		DisplayLabel:     instrument.DisplayLabel,
		DisplaySemantic:  instrument.DisplaySemantics,
		TickSize:         instrument.TickSize,
		SpotContract:     spotContract,
	}
	return presented
}

func presentMarket(market instruments.Metadata) marketPresentation {
	return marketPresentation{
		Market:           market.Symbol,
		ContractType:     market.ContractType,
		SettlementType:   market.SettlementType,
		BaseAssetSymbol:  market.BaseAssetSymbol,
		QuoteAssetSymbol: market.QuoteAssetSymbol,
		ExpiryTimestamp:  market.ExpiryTimestamp,
		PriceSemantics:   market.PriceSemantics,
		DisplaySemantics: market.DisplaySemantics,
		DisplayName:      market.DisplayName,
		DisplayLabel:     market.DisplayLabel,
		TickSize:         market.TickSize,
		SettlementNote:   market.SettlementNote,
		PricingModel:     market.PricingModel,
		DisplayPriceKind: market.DisplayPriceKind,
		AssetAddress:     strings.ToLower(market.AssetAddress),
		SubID:            market.SubID,
		OrderEntrySpec:   market.OrderEntrySpec,
		UIPriceUnit:      market.UIPriceUnit,
		UISizeUnit:       market.UISizeUnit,
		UISideMeaning:    market.UISideMeaning,
		EnginePriceUnit:  market.EnginePriceUnit,
		EngineAmountUnit: market.EngineAmountUnit,
		EngineSidePolicy: market.EngineSidePolicy,
		UIPriceToEngine:  market.UIPriceToEngine,
		UISizeToEngine:   market.UISizeToEngine,
	}
}

func (s *Server) presentMarket(ctx context.Context, market instruments.Metadata) marketPresentation {
	presentation := presentMarket(market)
	if s.pool == nil || s.orders == nil || market.AssetAddress == "" {
		return presentation
	}

	diagnostics, err := s.orders.GetMarketDiagnostics(ctx, market.AssetAddress, market.SubID)
	if err != nil {
		slog.Error("load market trade state", "market", market.Symbol, "error", err)
		return presentation
	}
	if diagnostics.LastTradeTimestamp != nil {
		timestamp := diagnostics.LastTradeTimestamp.Unix()
		presentation.LastTradeTimestamp = &timestamp
	}

	return presentation
}
