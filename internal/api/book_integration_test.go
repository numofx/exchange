package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	orderrepo "github.com/numofx/matching-backend/internal/orders"
)

type fakeCustodyChecker struct {
	allow map[string]bool
}

func (f fakeCustodyChecker) ValidateDeposited(_ context.Context, subaccountID string) error {
	if f.allow[subaccountID] {
		return nil
	}
	return errors.New("subaccount is not deposited in matching custody")
}

func openTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()

	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}

	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatalf("connect test db: %v", err)
	}
	t.Cleanup(pool.Close)

	return pool
}

func TestHandleBookAndTradesReturnEmptyArraysNotNull(t *testing.T) {
	pool := openTestPool(t)
	assetAddress := "0xfeed000000000000000000000000000000000777"

	registry := instruments.DefaultRegistry(config.Config{
		CNGNSep2026FutureAssetAddress: assetAddress,
		CNGNSep2026FutureSubID:        "1789567201",
	})
	server := NewServer(config.Config{}, pool, registry)

	bookReq := httptest.NewRequest(http.MethodGet, "/v1/book?asset_address="+assetAddress+"&sub_id=1789567201", nil)
	bookRec := httptest.NewRecorder()
	server.handleBook(bookRec, bookReq)

	if bookRec.Code != http.StatusOK {
		t.Fatalf("book status = %d body=%s", bookRec.Code, bookRec.Body.String())
	}
	if bytes.Contains(bookRec.Body.Bytes(), []byte(`"bids":null`)) || bytes.Contains(bookRec.Body.Bytes(), []byte(`"asks":null`)) {
		t.Fatalf("expected empty arrays in book response, got %s", bookRec.Body.String())
	}

	var bookResp bookResponse
	if err := json.Unmarshal(bookRec.Body.Bytes(), &bookResp); err != nil {
		t.Fatalf("unmarshal book response: %v", err)
	}
	if bookResp.MarketPresentation.LastTradeTimestamp != nil {
		t.Fatalf("expected null last_trade_timestamp in empty book response, got %v", *bookResp.MarketPresentation.LastTradeTimestamp)
	}

	tradesReq := httptest.NewRequest(http.MethodGet, "/v1/trades?asset_address="+assetAddress+"&sub_id=1789567201", nil)
	tradesRec := httptest.NewRecorder()
	server.handleTrades(tradesRec, tradesReq)

	if tradesRec.Code != http.StatusOK {
		t.Fatalf("trades status = %d body=%s", tradesRec.Code, tradesRec.Body.String())
	}
	if bytes.Contains(tradesRec.Body.Bytes(), []byte(`"trades":null`)) {
		t.Fatalf("expected empty arrays in trades response, got %s", tradesRec.Body.String())
	}

	var tradesResp tradesResponse
	if err := json.Unmarshal(tradesRec.Body.Bytes(), &tradesResp); err != nil {
		t.Fatalf("unmarshal trades response: %v", err)
	}
	if tradesResp.MarketPresentation.LastTradeTimestamp != nil {
		t.Fatalf("expected null last_trade_timestamp in empty trades response, got %v", *tradesResp.MarketPresentation.LastTradeTimestamp)
	}
}

func TestHandleMarketDiagnosticsReportsRegisteredEmptyFuture(t *testing.T) {
	pool := openTestPool(t)
	assetAddress := "0xfeed000000000000000000000000000000000776"

	registry := instruments.DefaultRegistry(config.Config{
		CNGNSep2026FutureAssetAddress: assetAddress,
		CNGNSep2026FutureSubID:        "1789567201",
	})
	server := NewServer(config.Config{}, pool, registry)

	req := httptest.NewRequest(http.MethodGet, "/debug/markets", nil)
	rec := httptest.NewRecorder()
	server.handleMarketDiagnostics(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
	}

	var diagnostics []marketDiagnosticsResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &diagnostics); err != nil {
		t.Fatalf("unmarshal diagnostics: %v", err)
	}

	var future *marketDiagnosticsResponse
	for i := range diagnostics {
		if diagnostics[i].Market == instruments.CNGNSep2026Symbol {
			future = &diagnostics[i]
			break
		}
	}

	if future == nil {
		t.Fatal("future market missing from diagnostics response")
	}
	if !future.LoadedInMatcher {
		t.Fatal("expected future to be marked loaded in matcher")
	}
	if future.OpenBidCount != 0 || future.OpenAskCount != 0 || future.TradeCount != 0 {
		t.Fatalf("unexpected diagnostics %+v", *future)
	}
	if future.LastTradeTimestamp != nil {
		t.Fatalf("expected nil last trade timestamp, got %+v", *future)
	}
}





func TestHandleCreateOrderRejectsUndepositedSubaccount(t *testing.T) {
	pool := openTestPool(t)
	assetAddress := "0xfeed000000000000000000000000000000000777"

	cfg := config.Config{
		CNGNSep2026FutureAssetAddress: assetAddress,
		CNGNSep2026FutureSubID:        "1789567201",
	}
	registry := instruments.DefaultRegistry(cfg)
	server := NewServer(cfg, pool, registry)
	server.custody = fakeCustodyChecker{allow: map[string]bool{"6": true}}

	payload := map[string]any{
		"order_id":       "reject-undeposited-1",
		"owner_address":  "0xabc",
		"signer_address": "0xabc",
		"subaccount_id":  "999",
		"recipient_id":   "999",
		"nonce":          "1",
		"side":           "buy",
		"asset_address":  assetAddress,
		"sub_id":         "1789567201",
		"desired_amount": "0.001",
		"filled_amount":  "0",
		"limit_price":    "1391",
		"worst_fee":      "0",
		"expiry":         time.Now().Add(time.Hour).Unix(),
		"action_json":    map[string]any{"subaccount_id": "999", "nonce": "1", "module": "0xtrade", "data": "0xaaa", "expiry": "100", "owner": "0xabc", "signer": "0xabc"},
		"signature":      "0xsig",
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	server.handleCreateOrder(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	if !bytes.Contains(rec.Body.Bytes(), []byte("not deposited")) {
		t.Fatalf("unexpected body=%s", rec.Body.String())
	}
}

func TestJUNDepositedCrossPathEndToEnd(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	suffix := fmt.Sprintf("jun-deposited-%d", time.Now().UnixNano())
	assetAddress := "0xfeed000000000000000000000000000000000776"
	subID := "1789567201"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1 or maker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
	})

	cfg := config.Config{
		CNGNSep2026FutureAssetAddress: assetAddress,
		CNGNSep2026FutureSubID:        subID,
	}
	registry := instruments.DefaultRegistry(cfg)
	server := NewServer(cfg, pool, registry)
	server.custody = fakeCustodyChecker{allow: map[string]bool{"6": true, "7": true}}
	repo := orderrepo.NewRepository(pool)

	expiry := time.Now().Add(time.Hour).Unix()
	makePayload := func(orderID string, subaccountID string, nonce string, side string, price string) map[string]any {
		return map[string]any{
			"order_id":       orderID,
			"owner_address":  "0xabc",
			"signer_address": "0xabc",
			"subaccount_id":  subaccountID,
			"recipient_id":   subaccountID,
			"nonce":          nonce,
			"side":           side,
			"asset_address":  assetAddress,
			"sub_id":         subID,
			"desired_amount": "0.001",
			"filled_amount":  "0",
			"limit_price":    price,
			"worst_fee":      "0",
			"expiry":         expiry,
			"action_json": map[string]any{
				"subaccount_id": subaccountID,
				"nonce":         nonce,
				"module":        "0xtrade",
				"data":          "0xaaa",
				"expiry":        "100",
				"owner":         "0xabc",
				"signer":        "0xabc",
			},
			"signature": "0xsig",
		}
	}

	submit := func(payload map[string]any) {
		body, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal payload: %v", err)
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/orders", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		rec := httptest.NewRecorder()
		server.handleCreateOrder(rec, req)
		if rec.Code != http.StatusCreated {
			t.Fatalf("create status=%d body=%s", rec.Code, rec.Body.String())
		}
	}

	askID := suffix + "-ask"
	buyID := suffix + "-buy"
	submit(makePayload(askID, "6", "1", "sell", "1390"))
	submit(makePayload(buyID, "7", "2", "buy", "1391"))

	candidate, err := repo.AcquireMatchCandidate(ctx, assetAddress, subID, time.Now().UTC())
	if err != nil {
		t.Fatalf("acquire match candidate: %v", err)
	}
	if candidate == nil {
		t.Fatal("expected match candidate")
	}

	if err := repo.FinalizeMatchWithPrice(ctx, candidate.Taker.OrderID, candidate.Maker.OrderID, "1390", "1000000"); err != nil {
		t.Fatalf("finalize match: %v", err)
	}

	tradesReq := httptest.NewRequest(http.MethodGet, "/v1/trades?asset_address="+assetAddress+"&sub_id="+subID, nil)
	tradesRec := httptest.NewRecorder()
	server.handleTrades(tradesRec, tradesReq)
	if tradesRec.Code != http.StatusOK {
		t.Fatalf("trades status=%d body=%s", tradesRec.Code, tradesRec.Body.String())
	}

	var trades tradesResponse
	if err := json.Unmarshal(tradesRec.Body.Bytes(), &trades); err != nil {
		t.Fatalf("unmarshal trades response: %v", err)
	}
	if len(trades.Trades) != 1 {
		t.Fatalf("expected 1 trade, got %d body=%s", len(trades.Trades), tradesRec.Body.String())
	}
	if trades.Trades[0].Size != "1000000" || trades.Trades[0].Price != "1390" {
		t.Fatalf("unexpected trade %+v", trades.Trades[0])
	}
}

func TestHandleCancelOrderRejectsServiceCancelForProtectedNamespace(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	suffix := fmt.Sprintf("cancel-protected-%d", time.Now().UnixNano())
	orderID := "smoke:" + suffix
	owner := "0xowner"
	nonce := "777001"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", orderID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $3, 6, 6, $4, 'sell', $5, $6, '1', '0', '1390', '1390', '0', $7, '{}'::jsonb, '0xsig', 'active')
`
	assetAddress := "0xce2846771074e20fec739cf97a60e6075d1e464b"
	expiry := time.Now().Add(time.Hour).Unix()
	if _, err := pool.Exec(ctx, insertOrder, orderID, owner, owner, nonce, assetAddress, "1789567201", expiry); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	server := NewServer(config.Config{
		CancelProtectedOrderPrefixes: []string{"smoke:"},
	}, pool, instruments.DefaultRegistry(config.Config{
		CNGNSep2026FutureAssetAddress: assetAddress,
		CNGNSep2026FutureSubID:        "1789567201",
	}))

	serviceReq := httptest.NewRequest(http.MethodPost, "/v1/orders/cancel", strings.NewReader(`{"owner_address":"0xowner","nonce":"777001","service":"market-maker","reason":"refresh"}`))
	serviceRec := httptest.NewRecorder()
	server.handleCancelOrder(serviceRec, serviceReq)

	if serviceRec.Code != http.StatusForbidden {
		t.Fatalf("status = %d body=%s", serviceRec.Code, serviceRec.Body.String())
	}
	if !strings.Contains(serviceRec.Body.String(), "protected namespace") {
		t.Fatalf("unexpected body: %s", serviceRec.Body.String())
	}

	var status string
	if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", orderID).Scan(&status); err != nil {
		t.Fatalf("query status: %v", err)
	}
	if status != "active" {
		t.Fatalf("status = %s", status)
	}

	manualReq := httptest.NewRequest(http.MethodPost, "/v1/orders/cancel", strings.NewReader(`{"owner_address":"0xowner","nonce":"777001","reason":"manual"}`))
	manualRec := httptest.NewRecorder()
	server.handleCancelOrder(manualRec, manualReq)
	if manualRec.Code != http.StatusOK {
		t.Fatalf("manual cancel status = %d body=%s", manualRec.Code, manualRec.Body.String())
	}
	if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", orderID).Scan(&status); err != nil {
		t.Fatalf("query status after manual cancel: %v", err)
	}
	if status != "cancelled" {
		t.Fatalf("status after manual cancel = %s", status)
	}
}

func TestHandleGetOrderStatusByID(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	orderID := fmt.Sprintf("status-endpoint-%d", time.Now().UnixNano())
	assetAddress := "0xfeed000000000000000000000000000000000776"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", orderID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $3, 6, 6, $4, 'buy', $5, $6, '10', '3', '1391', '1391', '0', $7, '{}'::jsonb, '0xsig', 'active')
`
	expiry := time.Now().Add(time.Hour).Unix()
	if _, err := pool.Exec(ctx, insertOrder, orderID, "0xowner", "0xowner", "12345", assetAddress, "1789567201", expiry); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	cfg := config.Config{
		CNGNSep2026FutureAssetAddress: assetAddress,
		CNGNSep2026FutureSubID:        "1789567201",
	}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	req := httptest.NewRequest(http.MethodGet, "/v1/orders/"+orderID, nil)
	routeCtx := chi.NewRouteContext()
	routeCtx.URLParams.Add("order_id", orderID)
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, routeCtx))
	rec := httptest.NewRecorder()
	server.handleGetOrderStatus(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
	}
	var payload orderStatusResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	if payload.OrderID != orderID {
		t.Fatalf("order_id = %s", payload.OrderID)
	}
	if payload.Status != orderrepo.StatusActive {
		t.Fatalf("status = %s", payload.Status)
	}
	if payload.FilledAmount != "3" {
		t.Fatalf("filled_amount = %s", payload.FilledAmount)
	}
	if payload.RemainingAmount != "7" {
		t.Fatalf("remaining_amount = %s", payload.RemainingAmount)
	}
}
