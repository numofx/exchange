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
		CNGNSpotAssetAddress: assetAddress,
	})
	server := NewServer(config.Config{}, pool, registry)

	bookReq := httptest.NewRequest(http.MethodGet, "/v1/book?asset_address="+assetAddress+"&sub_id=0", nil)
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

	tradesReq := httptest.NewRequest(http.MethodGet, "/v1/trades?asset_address="+assetAddress+"&sub_id=0", nil)
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

func TestHandleMarketDiagnosticsReportsRegisteredEmptyMarket(t *testing.T) {
	pool := openTestPool(t)
	assetAddress := "0xfeed000000000000000000000000000000000776"

	registry := instruments.DefaultRegistry(config.Config{
		CNGNSpotAssetAddress: assetAddress,
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

	var market *marketDiagnosticsResponse
	for i := range diagnostics {
		if diagnostics[i].Market == instruments.CNGNSpotSymbol {
			market = &diagnostics[i]
			break
		}
	}

	if market == nil {
		t.Fatal("market market missing from diagnostics response")
	}
	if !market.LoadedInMatcher {
		t.Fatal("expected market to be marked loaded in matcher")
	}
	if market.OpenBidCount != 0 || market.OpenAskCount != 0 || market.TradeCount != 0 {
		t.Fatalf("unexpected diagnostics %+v", *market)
	}
	if market.LastTradeTimestamp != nil {
		t.Fatalf("expected nil last trade timestamp, got %+v", *market)
	}
}

func TestHandleCreateOrderRejectsUndepositedSubaccount(t *testing.T) {
	pool := openTestPool(t)
	assetAddress := "0xfeed000000000000000000000000000000000777"

	cfg := config.Config{
		CNGNSpotAssetAddress: assetAddress,
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
		"sub_id":         "0",
		"desired_amount": "1",
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

func TestDepositedCrossPathEndToEnd(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	suffix := fmt.Sprintf("spot-deposited-%d", time.Now().UnixNano())
	assetAddress := "0xfeed000000000000000000000000000000000776"
	subID := "0"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where taker_order_id like $1 or maker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id like $1", suffix+"%")
	})

	cfg := config.Config{
		CNGNSpotAssetAddress: assetAddress,
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
			"desired_amount": "1",
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

	candidate, err := repo.AcquireMatchCandidate(ctx, assetAddress, subID, time.Now().UTC(), nil)
	if err != nil {
		t.Fatalf("acquire match candidate: %v", err)
	}
	if candidate == nil {
		t.Fatal("expected match candidate")
	}

	// desired_amount "1" is one whole unit (amount step "1"), so a full fill is 1
	// atomic unit — not a raw 1e6-scaled value.
	if err := repo.FinalizeMatchWithPrice(ctx, candidate.Taker.OrderID, candidate.Maker.OrderID, "1390", "1"); err != nil {
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
	if trades.Trades[0].Size != "1" || trades.Trades[0].Price != "1390" {
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
	if _, err := pool.Exec(ctx, insertOrder, orderID, owner, owner, nonce, assetAddress, "0", expiry); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	server := NewServer(config.Config{
		CancelProtectedOrderPrefixes: []string{"smoke:"},
	}, pool, instruments.DefaultRegistry(config.Config{
		CNGNSpotAssetAddress: assetAddress,
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

// A cancel must leave an auditable trace: the reason and requester on the row, and a status
// endpoint that reports a real cancel_reason and an updated_at at the cancel time rather than the
// hardcoded ”/created_at that made a cancel indistinguishable from an expiry.
func TestHandleCancelOrderRecordsAudit(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	suffix := fmt.Sprintf("cancel-audit-%d", time.Now().UnixNano())
	orderID := "manual:" + suffix
	owner := "0xaudit0000000000000000000000000000000001"
	nonce := "778220"
	assetAddress := "0xce2846771074e20fec739cf97a60e6075d1e464b"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", orderID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $2, 6, 6, $3, 'sell', $4, $5, '1', '0', '1390', '1390', '0', $6, '{}'::jsonb, '0xsig', 'active')
`
	expiry := time.Now().Add(time.Hour).Unix()
	if _, err := pool.Exec(ctx, insertOrder, orderID, owner, nonce, assetAddress, "0", expiry); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	cfg := config.Config{
		CNGNSpotAssetAddress: assetAddress,
	}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))

	beforeCancel := time.Now().Add(-time.Second)
	body := fmt.Sprintf(`{"owner_address":%q,"nonce":%q,"reason":"trader clicked cancel"}`, owner, nonce)
	cancelReq := httptest.NewRequest(http.MethodPost, "/v1/orders/cancel", strings.NewReader(body))
	cancelReq.Header.Set("X-Principal", "trader-42")
	cancelRec := httptest.NewRecorder()
	server.handleCancelOrder(cancelRec, cancelReq)
	if cancelRec.Code != http.StatusOK {
		t.Fatalf("cancel status = %d body=%s", cancelRec.Code, cancelRec.Body.String())
	}

	// The row carries when/why/by-whom.
	var (
		reason      string
		cancelledBy string
		cancelledAt time.Time
	)
	if err := pool.QueryRow(ctx,
		"select cancel_reason, cancelled_by, cancelled_at from active_orders where order_id = $1", orderID,
	).Scan(&reason, &cancelledBy, &cancelledAt); err != nil {
		t.Fatalf("query audit columns: %v", err)
	}
	if reason != "trader clicked cancel" {
		t.Fatalf("cancel_reason = %q", reason)
	}
	if cancelledBy != "trader-42" {
		t.Fatalf("cancelled_by = %q", cancelledBy)
	}
	if cancelledAt.Before(beforeCancel) {
		t.Fatalf("cancelled_at %s is before the cancel request", cancelledAt)
	}

	// The status endpoint surfaces them, and updated_at tracks the cancel, not created_at.
	statusReq := httptest.NewRequest(http.MethodGet, "/v1/orders/"+orderID, nil)
	routeCtx := chi.NewRouteContext()
	routeCtx.URLParams.Add("order_id", orderID)
	statusReq = statusReq.WithContext(context.WithValue(statusReq.Context(), chi.RouteCtxKey, routeCtx))
	statusRec := httptest.NewRecorder()
	server.handleGetOrderStatus(statusRec, statusReq)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("status endpoint = %d body=%s", statusRec.Code, statusRec.Body.String())
	}
	var payload orderStatusResponse
	if err := json.Unmarshal(statusRec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("unmarshal status: %v", err)
	}
	if payload.Status != orderrepo.StatusCancelled {
		t.Fatalf("status = %s", payload.Status)
	}
	if payload.CancelReason != "trader clicked cancel" {
		t.Fatalf("cancel_reason = %q", payload.CancelReason)
	}
	if payload.UpdatedAt.Before(beforeCancel) {
		t.Fatalf("updated_at %s did not advance to the cancel time", payload.UpdatedAt)
	}
}

// With enforcement on, an unsigned cancel is rejected and the order stays on the book, while a
// cancel whose signature verifies goes through and still records its audit trail. The signature
// cryptography itself is covered by ordersig; here the stub stands in for a verified/failed check
// so the test exercises the handler's enforce-or-allow wiring end to end.
func TestHandleCancelOrderEnforcesSignature(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	suffix := fmt.Sprintf("cancel-enforce-%d", time.Now().UnixNano())
	orderID := "manual:" + suffix
	owner := "0xenforce00000000000000000000000000000001"
	nonce := "778330"
	assetAddress := "0xce2846771074e20fec739cf97a60e6075d1e464b"

	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from active_orders where order_id = $1", orderID)
	})

	insertOrder := `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $2, 6, 6, $3, 'sell', $4, $5, '1', '0', '1390', '1390', '0', $6, '{}'::jsonb, '0xsig', 'active')
`
	expiry := time.Now().Add(time.Hour).Unix()
	if _, err := pool.Exec(ctx, insertOrder, orderID, owner, nonce, assetAddress, "0", expiry); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	cfg := config.Config{
		EnforceCancelSignatures: true,
		CNGNSpotAssetAddress:    assetAddress,
	}
	server := NewServer(cfg, pool, instruments.DefaultRegistry(cfg))
	// NewServer builds no verifier without a chain configured; inject a stub so enforcement has
	// something to consult. Its default is a passing check.
	server.signatures = &stubSignatureChecker{}

	// Unsigned cancel is rejected, and the order is untouched.
	unsigned := fmt.Sprintf(`{"owner_address":%q,"nonce":%q,"reason":"no sig"}`, owner, nonce)
	unsignedRec := httptest.NewRecorder()
	server.handleCancelOrder(unsignedRec, httptest.NewRequest(http.MethodPost, "/v1/orders/cancel", strings.NewReader(unsigned)))
	if unsignedRec.Code != http.StatusUnauthorized {
		t.Fatalf("unsigned cancel status = %d body=%s", unsignedRec.Code, unsignedRec.Body.String())
	}
	var status string
	if err := pool.QueryRow(ctx, "select status from active_orders where order_id = $1", orderID).Scan(&status); err != nil {
		t.Fatalf("query status: %v", err)
	}
	if status != "active" {
		t.Fatalf("order should still be active after a rejected cancel, got %s", status)
	}

	// A cancel whose signature verifies goes through.
	signed := fmt.Sprintf(`{"owner_address":%q,"nonce":%q,"expiry":%q,"signature":"0xdeadbeef","reason":"signed"}`,
		owner, nonce, fmt.Sprintf("%d", time.Now().Add(10*time.Minute).Unix()))
	signedRec := httptest.NewRecorder()
	server.handleCancelOrder(signedRec, httptest.NewRequest(http.MethodPost, "/v1/orders/cancel", strings.NewReader(signed)))
	if signedRec.Code != http.StatusOK {
		t.Fatalf("signed cancel status = %d body=%s", signedRec.Code, signedRec.Body.String())
	}
	var reason string
	if err := pool.QueryRow(ctx,
		"select status, cancel_reason from active_orders where order_id = $1", orderID,
	).Scan(&status, &reason); err != nil {
		t.Fatalf("query after signed cancel: %v", err)
	}
	if status != "cancelled" {
		t.Fatalf("status after signed cancel = %s", status)
	}
	if reason != "signed" {
		t.Fatalf("cancel_reason = %q", reason)
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
	if _, err := pool.Exec(ctx, insertOrder, orderID, "0xowner", "0xowner", "12345", assetAddress, "0", expiry); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	cfg := config.Config{
		CNGNSpotAssetAddress: assetAddress,
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
