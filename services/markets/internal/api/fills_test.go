package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	orderrepo "github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/wsauth"
)

func getFills(server *Server, header, query string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/v1/fills"+query, nil)
	if header != "" {
		req.Header.Set(orderHistoryAuthHeader, header)
	}
	rec := httptest.NewRecorder()
	server.handleFills(rec, req)
	return rec
}

// As with order history, every rejection returns before the repository is touched: a Server with no
// database proves no fill is read for a caller who has not proven which address they are.
func TestFillsRefusesUnauthenticatedRequests(t *testing.T) {
	server := &Server{orderHistoryAuth: historyVerifier()}
	key := bytes.Repeat([]byte{0x33}, 32)
	now := time.Now()
	websocketVerifier := wsauth.Verifier{Domain: historyTestDomain, MaxTTL: 24 * time.Hour}

	cases := []struct {
		name   string
		header string
	}{
		{name: "no header", header: ""},
		{name: "not base64url JSON", header: "!!!"},
		{name: "signed for the WebSocket, not order history", header: signedHistoryHeader(t, key, websocketVerifier, now, now.Add(time.Hour))},
		{name: "expired", header: signedHistoryHeader(t, key, historyVerifier(), now.Add(-2*time.Hour), now.Add(-time.Hour))},
		{name: "validity window past the maximum", header: signedHistoryHeader(t, key, historyVerifier(), now, now.Add(48*time.Hour))},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := getFills(server, tc.header, "")
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
			if got := rec.Header().Get("Cache-Control"); got != "no-store" {
				t.Fatalf("Cache-Control = %q, want no-store", got)
			}
		})
	}
}

func TestFillsRejectsBadPagingBeforeQuerying(t *testing.T) {
	server := &Server{orderHistoryAuth: historyVerifier()}
	now := time.Now()
	header := signedHistoryHeader(t, bytes.Repeat([]byte{0x33}, 32), historyVerifier(), now, now.Add(time.Hour))
	cursor := func(value string) string { return base64.RawURLEncoding.EncodeToString([]byte(value)) }

	for _, query := range []string{
		"?limit=0",
		"?limit=101",
		"?limit=abc",
		"?before=not-a-cursor",
		"?before=" + cursor("345"),
		"?before=" + cursor("0|taker"),
		"?before=" + cursor("abc|maker"),
		"?before=" + cursor("345|sideways"),
	} {
		t.Run(query, func(t *testing.T) {
			rec := getFills(server, header, query)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

func TestFillCursorRoundTrips(t *testing.T) {
	for _, cursor := range []orderrepo.FillCursor{
		{TradeID: 345, Liquidity: orderrepo.LiquidityTaker},
		{TradeID: 1, Liquidity: orderrepo.LiquidityMaker},
	} {
		decoded, err := decodeFillCursor(encodeFillCursor(cursor))
		if err != nil {
			t.Fatalf("decode %+v: %v", cursor, err)
		}
		if *decoded != cursor {
			t.Fatalf("round trip = %+v, want %+v", *decoded, cursor)
		}
	}
}

type fillsTestResponse struct {
	Fills []struct {
		TradeID      int64   `json:"trade_id"`
		OrderID      string  `json:"order_id"`
		Liquidity    string  `json:"liquidity"`
		Side         string  `json:"side"`
		Market       string  `json:"market"`
		DisplayName  string  `json:"display_name"`
		Fee          *string `json:"fee"`
		TxHash       string  `json:"tx_hash"`
		SpotContract *struct {
			UIIntent struct {
				Side  string `json:"side"`
				Price string `json:"price"`
				Size  string `json:"size"`
			} `json:"ui_intent"`
		} `json:"spot_contract"`
	} `json:"fills"`
	NextBefore string `json:"next_before"`
}

func TestFillsListsOnlyTheSignersFillsNewestFirst(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	wsApplyMigrations(ctx, t, pool)

	assetAddress := "0xfeed000000000000000000000000000000000999"
	registry := instruments.DefaultRegistry(config.Config{CNGNSpotAssetAddress: assetAddress})
	server := NewServer(config.Config{WSAuthDomain: historyTestDomain}, pool, registry)

	suffix := fmt.Sprintf("it-fills-%d", time.Now().UnixNano())
	// A key derived from the run, so rows left by an earlier crashed run can never share this owner.
	key := historyKeccak([]byte(suffix))
	owner := historyTestAddress(key)
	other := historyTestAddress(historyKeccak([]byte(suffix + "-other")))

	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "delete from trade_fills where taker_order_id like $1 or maker_order_id like $1", suffix+"%")
		_, _ = pool.Exec(context.Background(), "delete from active_orders where order_id like $1", suffix+"%")
	})

	// Engine sides. On USDCcNGN-SPOT an engine sell of cNGN is the trader buying USDC.
	orderRows := []struct {
		id, owner, side string
		subaccount      int
	}{
		{id: suffix + "-a", owner: owner, side: "sell", subaccount: 19},
		{id: suffix + "-b", owner: owner, side: "buy", subaccount: 19},
		// Two of the owner's orders on different subaccounts that traded with each other.
		{id: suffix + "-c", owner: owner, side: "buy", subaccount: 19},
		{id: suffix + "-d", owner: owner, side: "sell", subaccount: 20},
		{id: suffix + "-e", owner: other, side: "sell", subaccount: 21},
	}
	const insertOrder = `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status
) values ($1, $2, $2, $3, $3, $4, $5, $6, '0', '1339', '0', '0.00075', '750000000000000', '0', $7, '{}'::jsonb, '0xsig', 'filled')
`
	nonceBase := time.Now().UnixNano()
	for i, row := range orderRows {
		if _, err := pool.Exec(ctx, insertOrder, row.id, row.owner, row.subaccount, nonceBase+int64(i), row.side, assetAddress,
			time.Now().Add(time.Hour).Unix()); err != nil {
			t.Fatalf("insert %s: %v", row.id, err)
		}
	}

	// Recorded in this order, so trade ids ascend t1..t4. The aggressor side is the taker's.
	const insertFill = `
insert into trade_fills (asset_address, sub_id, price, size, aggressor_side, taker_order_id, maker_order_id)
values ($1, '0', $2, $3, $4, $5, $6)
`
	for _, fill := range []struct{ price, size, aggressor, taker, maker string }{
		{price: "0.00074", size: "1000", aggressor: "sell", taker: suffix + "-a", maker: suffix + "-counterparty-1"}, // t1
		{price: "0.00075", size: "400", aggressor: "sell", taker: suffix + "-counterparty-2", maker: suffix + "-b"},  // t2
		{price: "0.00075", size: "200", aggressor: "buy", taker: suffix + "-c", maker: suffix + "-d"},                // t3
		{price: "0.00075", size: "999", aggressor: "sell", taker: suffix + "-e", maker: suffix + "-counterparty-4"},  // t4, another owner
	} {
		if _, err := pool.Exec(ctx, insertFill, assetAddress, fill.price, fill.size, fill.aggressor, fill.taker, fill.maker); err != nil {
			t.Fatalf("insert fill: %v", err)
		}
	}

	// What the matcher recorded for t1's taker. t3's taker fee is left unrecorded.
	if _, err := pool.Exec(ctx, "update trade_fills set taker_fee = '0.001850000000000000', tx_hash = '0xfeed' where taker_order_id = $1", suffix+"-a"); err != nil {
		t.Fatalf("record fee: %v", err)
	}

	now := time.Now()
	// The order-history login: one signature covers both of the account's history endpoints.
	header := signedHistoryHeader(t, key, server.orderHistoryAuth, now, now.Add(time.Hour))

	fetch := func(query string) fillsTestResponse {
		t.Helper()
		rec := getFills(server, header, query)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET /v1/fills%s status = %d body=%s", query, rec.Code, rec.Body.String())
		}
		if got := rec.Header().Get("Cache-Control"); got != "no-store" {
			t.Fatalf("Cache-Control = %q, want no-store", got)
		}
		if bytes.Contains(rec.Body.Bytes(), []byte(`"fills":null`)) {
			t.Fatalf("fills must be an array, got %s", rec.Body.String())
		}
		var body fillsTestResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return body
	}
	rows := func(body fillsTestResponse) []string {
		out := make([]string, 0, len(body.Fills))
		for _, f := range body.Fills {
			out = append(out, f.OrderID[len(suffix):]+"/"+f.Liquidity)
		}
		return out
	}

	// The self-trade is listed once per order, and a page boundary between its two rows neither
	// skips nor repeats one.
	first := fetch("?limit=1")
	if got, want := rows(first), []string{"-c/taker"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("page 1 = %v, want %v", got, want)
	}
	second := fetch("?limit=1&before=" + first.NextBefore)
	if got, want := rows(second), []string{"-d/maker"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("page 2 = %v, want %v", got, want)
	}
	if first.Fills[0].TradeID != second.Fills[0].TradeID {
		t.Fatalf("the two sides of one trade carry different trade ids: %d, %d", first.Fills[0].TradeID, second.Fills[0].TradeID)
	}

	third := fetch("?limit=2&before=" + second.NextBefore)
	if got, want := rows(third), []string{"-b/maker", "-a/taker"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("page 3 = %v, want %v", got, want)
	}
	if third.NextBefore == "" {
		t.Fatal("a full page must offer next_before")
	}
	last := fetch("?limit=2&before=" + third.NextBefore)
	if len(last.Fills) != 0 || last.NextBefore != "" {
		t.Fatalf("page 4 = %v next_before=%q, want empty and no cursor", rows(last), last.NextBefore)
	}

	// A maker fill is the owner's side, not the aggressor's: order b bought cNGN (the trader sold
	// USDC) against a taker who sold.
	maker := third.Fills[0]
	if maker.Side != "buy" || maker.Market == "" || maker.DisplayName == "" || maker.SpotContract == nil {
		t.Fatalf("maker fill not presented from the owner's order: %+v", maker)
	}
	if maker.SpotContract.UIIntent.Side != "sell" || !decimalStringsMatch(maker.SpotContract.UIIntent.Size, "0.3") {
		t.Fatalf("maker fill ui_intent = %+v, want a 0.3 USDC sell", maker.SpotContract.UIIntent)
	}
	taker := third.Fills[1]
	if taker.Side != "sell" || taker.SpotContract == nil ||
		taker.SpotContract.UIIntent.Side != "buy" || !decimalStringsMatch(taker.SpotContract.UIIntent.Size, "0.74") {
		t.Fatalf("taker fill = %+v, want a 0.74 USDC buy", taker)
	}

	// What each order paid: a taker its recorded fee, a maker nothing, and a taker whose fee was never
	// recorded no figure at all rather than a zero.
	if taker.Fee == nil || *taker.Fee != "0.00185" || taker.TxHash != "0xfeed" {
		t.Fatalf("taker fill fee = %v tx_hash = %q, want 0.00185 and 0xfeed", taker.Fee, taker.TxHash)
	}
	for _, makerFill := range []struct {
		fee *string
		id  string
	}{{maker.Fee, maker.OrderID}, {second.Fills[0].Fee, second.Fills[0].OrderID}} {
		if makerFill.fee == nil || *makerFill.fee != "0" {
			t.Fatalf("maker fill %s fee = %v, want 0", makerFill.id, makerFill.fee)
		}
	}
	if first.Fills[0].Fee != nil {
		t.Fatalf("taker fill with no recorded fee reports fee %q", *first.Fills[0].Fee)
	}

	// Paging through everything: another owner's fill never appears.
	all := fetch("")
	if len(all.Fills) != 4 {
		t.Fatalf("unpaged = %v, want the owner's four fills", rows(all))
	}
	for _, f := range all.Fills {
		if f.OrderID == suffix+"-e" {
			t.Fatalf("returned another owner's fill: %+v", f)
		}
	}
}
