package api

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	orderrepo "github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/wsauth"
)

const historyTestDomain = "markets.numo.xyz"

func historyKeccak(parts ...[]byte) []byte {
	h := sha3.NewLegacyKeccak256()
	for _, part := range parts {
		h.Write(part)
	}
	return h.Sum(nil)
}

func historyTestAddress(key []byte) string {
	uncompressed := secp256k1.PrivKeyFromBytes(key).PubKey().SerializeUncompressed()
	return "0x" + hex.EncodeToString(historyKeccak(uncompressed[1:])[12:])
}

func historyVerifier() wsauth.Verifier {
	return wsauth.Verifier{Domain: historyTestDomain, MaxTTL: 24 * time.Hour, Statement: wsauth.OrderHistoryStatement}
}

// signedHistoryHeader builds the X-Numo-Auth value a client sends: the frame, signed with
// personal_sign over the given verifier's message, as base64url JSON.
func signedHistoryHeader(t *testing.T, key []byte, verifier wsauth.Verifier, issuedAt, expiry time.Time) string {
	t.Helper()
	frame := wsauth.AuthFrame{
		Address:  historyTestAddress(key),
		Nonce:    fmt.Sprintf("history-%d", time.Now().UnixNano()),
		IssuedAt: issuedAt.Unix(),
		Expiry:   expiry.Unix(),
	}
	message := verifier.Message(frame)
	digest := historyKeccak([]byte(fmt.Sprintf("\x19Ethereum Signed Message:\n%d%s", len(message), message)))

	// SignCompact returns [recoveryCode || R || S]; the wallet convention is [R || S || V].
	compact := ecdsa.SignCompact(secp256k1.PrivKeyFromBytes(key), digest, false)
	sig := make([]byte, 65)
	copy(sig[0:32], compact[1:33])
	copy(sig[32:64], compact[33:65])
	sig[64] = compact[0]
	frame.Signature = "0x" + hex.EncodeToString(sig)

	raw, err := json.Marshal(frame)
	if err != nil {
		t.Fatalf("marshal frame: %v", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw)
}

func getOrderHistory(server *Server, header, query string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, "/v1/orders"+query, nil)
	if header != "" {
		req.Header.Set(orderHistoryAuthHeader, header)
	}
	rec := httptest.NewRecorder()
	server.handleOrderHistory(rec, req)
	return rec
}

// Every rejection returns before the repository is touched, so a Server with no database proves the
// endpoint never reads history for a caller it has not authenticated.
func TestOrderHistoryRefusesUnauthenticatedRequests(t *testing.T) {
	server := &Server{orderHistoryAuth: historyVerifier()}
	key := bytes.Repeat([]byte{0x22}, 32)
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
			rec := getOrderHistory(server, tc.header, "")
			if rec.Code != http.StatusUnauthorized {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
			if got := rec.Header().Get("Cache-Control"); got != "no-store" {
				t.Fatalf("Cache-Control = %q, want no-store", got)
			}
		})
	}
}

func TestOrderHistoryRejectsBadPagingBeforeQuerying(t *testing.T) {
	server := &Server{orderHistoryAuth: historyVerifier()}
	now := time.Now()
	header := signedHistoryHeader(t, bytes.Repeat([]byte{0x22}, 32), historyVerifier(), now, now.Add(time.Hour))
	missingOrderID := base64.RawURLEncoding.EncodeToString([]byte("2026-09-13T16:51:01Z|"))

	for _, query := range []string{"?limit=0", "?limit=101", "?limit=abc", "?before=not-a-cursor", "?before=" + missingOrderID} {
		t.Run(query, func(t *testing.T) {
			rec := getOrderHistory(server, header, query)
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("status = %d body=%s", rec.Code, rec.Body.String())
			}
		})
	}
}

// The cursor splits on the first '|', so an order id that itself contains one still round-trips.
func TestOrderHistoryCursorRoundTrips(t *testing.T) {
	cursor := orderrepo.OrderHistoryCursor{
		CreatedAt: time.Date(2026, 9, 13, 16, 51, 1, 932614000, time.UTC),
		OrderID:   "spot-f2028e9a|odd",
	}

	decoded, err := decodeOrderHistoryCursor(encodeOrderHistoryCursor(cursor))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !decoded.CreatedAt.Equal(cursor.CreatedAt) || decoded.OrderID != cursor.OrderID {
		t.Fatalf("round trip = %+v, want %+v", *decoded, cursor)
	}
}

type orderHistoryTestResponse struct {
	Orders []struct {
		OrderID      string     `json:"order_id"`
		OwnerAddress string     `json:"owner_address"`
		Status       string     `json:"status"`
		Market       string     `json:"market"`
		CancelReason string     `json:"cancel_reason"`
		CancelledAt  *time.Time `json:"cancelled_at"`
	} `json:"orders"`
	NextBefore string `json:"next_before"`
}

func TestOrderHistoryListsOnlyTheSignersOrdersNewestFirst(t *testing.T) {
	pool := openTestPool(t)
	ctx := context.Background()
	wsApplyMigrations(ctx, t, pool)

	assetAddress := "0xfeed000000000000000000000000000000000888"
	registry := instruments.DefaultRegistry(config.Config{CNGNSpotAssetAddress: assetAddress})
	server := NewServer(config.Config{WSAuthDomain: historyTestDomain}, pool, registry)

	suffix := fmt.Sprintf("it-history-%d", time.Now().UnixNano())
	// A key derived from the run, so rows left by an earlier crashed run can never share this owner.
	key := historyKeccak([]byte(suffix))
	owner := historyTestAddress(key)
	other := "0x" + strings.Repeat("ab", 20)
	base := time.Now().Add(-time.Hour).UTC().Truncate(time.Microsecond)

	t.Cleanup(func() {
		_, _ = pool.Exec(context.Background(), "delete from active_orders where order_id like $1", suffix+"%")
	})

	rows := []struct {
		id           string
		owner        string
		status       string
		cancelReason string
		createdAt    time.Time
		nullTicks    bool
	}{
		// Written before limit_price_ticks existed: a history reaches back to rows the book never reads.
		{id: suffix + "-filled", owner: owner, status: "filled", createdAt: base, nullTicks: true},
		{id: suffix + "-cancelled", owner: owner, status: "cancelled", cancelReason: "user_requested", createdAt: base.Add(time.Minute)},
		// Same instant: the page boundary is decided by order_id, not skipped or repeated.
		{id: suffix + "-active-a", owner: owner, status: "active", createdAt: base.Add(2 * time.Minute)},
		{id: suffix + "-active-b", owner: owner, status: "active", createdAt: base.Add(2 * time.Minute)},
		{id: suffix + "-other", owner: other, status: "active", createdAt: base.Add(3 * time.Minute)},
	}

	const insert = `
insert into active_orders (
  order_id, owner_address, signer_address, subaccount_id, recipient_id, nonce, side, asset_address, sub_id,
  desired_amount, filled_amount, limit_price, limit_price_ticks, worst_fee, expiry, action_json, signature, status,
  created_at, cancel_reason, cancelled_at
) values ($1, $2, $2, 19, 19, $3, 'sell', $4, '0', '1339', '0', '0.000746559270989681', $5, '0', $6, '{}'::jsonb, '0xsig', $7, $8, $9, $10)
`
	nonceBase := time.Now().UnixNano()
	for i, row := range rows {
		var ticks any = "746559270989681"
		if row.nullTicks {
			ticks = nil
		}
		var cancelReason, cancelledAt any
		if row.cancelReason != "" {
			cancelReason = row.cancelReason
			cancelledAt = row.createdAt.Add(30 * time.Second)
		}
		if _, err := pool.Exec(ctx, insert, row.id, row.owner, nonceBase+int64(i), assetAddress, ticks,
			time.Now().Add(time.Hour).Unix(), row.status, row.createdAt, cancelReason, cancelledAt); err != nil {
			t.Fatalf("insert %s: %v", row.id, err)
		}
	}

	now := time.Now()
	header := signedHistoryHeader(t, key, server.orderHistoryAuth, now, now.Add(time.Hour))

	fetch := func(query string) orderHistoryTestResponse {
		t.Helper()
		rec := getOrderHistory(server, header, query)
		if rec.Code != http.StatusOK {
			t.Fatalf("GET /v1/orders%s status = %d body=%s", query, rec.Code, rec.Body.String())
		}
		if bytes.Contains(rec.Body.Bytes(), []byte(`"orders":null`)) {
			t.Fatalf("orders must be an array, got %s", rec.Body.String())
		}
		var body orderHistoryTestResponse
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return body
	}
	ids := func(body orderHistoryTestResponse) []string {
		out := make([]string, 0, len(body.Orders))
		for _, o := range body.Orders {
			out = append(out, o.OrderID)
		}
		return out
	}

	first := fetch("?limit=2")
	if got, want := ids(first), []string{suffix + "-active-b", suffix + "-active-a"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("page 1 = %v, want %v", got, want)
	}
	if first.NextBefore == "" {
		t.Fatal("a full page must offer next_before")
	}

	second := fetch("?limit=2&before=" + first.NextBefore)
	if got, want := ids(second), []string{suffix + "-cancelled", suffix + "-filled"}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("page 2 = %v, want %v", got, want)
	}
	cancelled := second.Orders[0]
	if cancelled.CancelReason != "user_requested" || cancelled.CancelledAt == nil {
		t.Fatalf("cancelled row lost its audit: %+v", cancelled)
	}
	if second.Orders[1].Status != "filled" || second.Orders[1].Market == "" {
		t.Fatalf("filled row not presented: %+v", second.Orders[1])
	}

	last := fetch("?limit=2&before=" + second.NextBefore)
	if len(last.Orders) != 0 || last.NextBefore != "" {
		t.Fatalf("page 3 = %v next_before=%q, want empty and no cursor", ids(last), last.NextBefore)
	}

	for _, page := range []orderHistoryTestResponse{first, second} {
		for _, o := range page.Orders {
			if o.OwnerAddress != owner {
				t.Fatalf("returned another owner's order: %+v", o)
			}
		}
	}
}
