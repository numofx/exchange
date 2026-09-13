package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/wsauth"
)

const (
	// orderHistoryAuthHeader carries the signed frame: the same fields as the WebSocket 'auth' op,
	// as base64url-encoded JSON, signed over wsauth.OrderHistoryStatement.
	orderHistoryAuthHeader = "X-Numo-Auth"

	orderHistoryDefaultLimit = 50
	orderHistoryMaxLimit     = 100

	// defaultOrderHistoryAuthMaxTTL applies when ORDER_HISTORY_AUTH_MAX_TTL is unset or not
	// positive. A zero MaxTTL means "unbounded" to the verifier, which must never be the result of
	// an empty config.
	defaultOrderHistoryAuthMaxTTL = 24 * time.Hour
)

var errOrderHistoryAuthEncoding = errors.New(orderHistoryAuthHeader + " must be base64url-encoded JSON")

type presentedHistoryOrder struct {
	presentedOrder
	CancelReason string     `json:"cancel_reason,omitempty"`
	CancelledAt  *time.Time `json:"cancelled_at,omitempty"`
}

type orderHistoryResponse struct {
	Orders []presentedHistoryOrder `json:"orders"`
	// NextBefore pages to older orders; absent on the last page.
	NextBefore string `json:"next_before,omitempty"`
}

// handleOrderHistory serves GET /v1/orders: the authenticated owner's orders in every status,
// newest first.
//
// Authentication is required, and the owner comes only from the signature — never from a query
// parameter. Resting orders are public on the book and fills settle on chain, but an owner's
// cancelled and expired orders are published nowhere else, and this endpoint is what would expose
// them.
func (s *Server) handleOrderHistory(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")

	owner, err := s.authenticateOrderHistory(r, time.Now())
	if err != nil {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": err.Error()})
		return
	}

	limit, err := parseOrderHistoryLimit(r.URL.Query().Get("limit"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	before, err := decodeOrderHistoryCursor(r.URL.Query().Get("before"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	items, err := s.orders.ListOrdersByOwner(r.Context(), owner, before, limit)
	if err != nil {
		slog.Error("list order history", "owner", owner, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load order history"})
		return
	}

	nextBefore := ""
	if len(items) == int(limit) {
		last := items[len(items)-1]
		nextBefore = encodeOrderHistoryCursor(orders.OrderHistoryCursor{CreatedAt: last.CreatedAt, OrderID: last.OrderID})
	}

	writeJSON(w, http.StatusOK, orderHistoryResponse{
		Orders:     s.presentOrderHistory(items),
		NextBefore: nextBefore,
	})
}

// authenticateOrderHistory returns the lowercased owner address the request's signed frame proves
// control of.
func (s *Server) authenticateOrderHistory(r *http.Request, now time.Time) (string, error) {
	raw := strings.TrimSpace(r.Header.Get(orderHistoryAuthHeader))
	if raw == "" {
		return "", errors.New(orderHistoryAuthHeader + " header is required")
	}

	decoded, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(raw, "="))
	if err != nil {
		return "", errOrderHistoryAuthEncoding
	}
	var frame wsauth.AuthFrame
	if err := json.Unmarshal(decoded, &frame); err != nil {
		return "", errOrderHistoryAuthEncoding
	}

	owner, err := s.orderHistoryAuth.Verify(frame, now)
	if err != nil {
		return "", fmt.Errorf("auth failed: %w", err)
	}
	return owner, nil
}

func parseOrderHistoryLimit(raw string) (int32, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return orderHistoryDefaultLimit, nil
	}
	parsed, err := strconv.Atoi(raw)
	if err != nil || parsed <= 0 || parsed > orderHistoryMaxLimit {
		return 0, fmt.Errorf("limit must be between 1 and %d", orderHistoryMaxLimit)
	}
	return int32(parsed), nil
}

// encodeOrderHistoryCursor makes an opaque `before` value. Clients pass back what they were given
// and never build one, so its shape can change without breaking them.
func encodeOrderHistoryCursor(cursor orders.OrderHistoryCursor) string {
	value := cursor.CreatedAt.UTC().Format(time.RFC3339Nano) + "|" + cursor.OrderID
	return base64.RawURLEncoding.EncodeToString([]byte(value))
}

func decodeOrderHistoryCursor(raw string) (*orders.OrderHistoryCursor, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	invalid := errors.New("before must be a next_before value returned by this endpoint")
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, invalid
	}
	createdAtRaw, orderID, found := strings.Cut(string(decoded), "|")
	if !found || orderID == "" {
		return nil, invalid
	}
	createdAt, err := time.Parse(time.RFC3339Nano, createdAtRaw)
	if err != nil {
		return nil, invalid
	}
	return &orders.OrderHistoryCursor{CreatedAt: createdAt, OrderID: orderID}, nil
}

func (s *Server) presentOrderHistory(items []orders.OrderHistoryEntry) []presentedHistoryOrder {
	out := make([]presentedHistoryOrder, 0, len(items))
	for _, item := range items {
		meta := instruments.Metadata{}
		if s.instruments != nil {
			meta, _ = s.instruments.ByAssetAndSubID(strings.ToLower(item.AssetAddress), item.SubID)
		}
		out = append(out, presentedHistoryOrder{
			presentedOrder: presentOrder(item.Order, meta),
			CancelReason:   item.CancelReason,
			CancelledAt:    item.CancelledAt,
		})
	}
	return out
}
