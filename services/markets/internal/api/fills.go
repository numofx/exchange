package api

import (
	"encoding/base64"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// presentedFill is one fill on one of the caller's orders.
type presentedFill struct {
	TradeID int64 `json:"trade_id"`
	// OrderID is the caller's order that filled. When two of the caller's orders traded with each
	// other, the trade is listed twice, once for each.
	OrderID   string           `json:"order_id"`
	Liquidity orders.Liquidity `json:"liquidity"`
	// Side, Price and Size are the engine's: the order's engine side, price in USDC per cNGN, size in
	// whole cNGN. On a spot market, spot_contract carries the trader's view of the same fill.
	Side         orders.Side            `json:"side"`
	Price        string                 `json:"price"`
	Size         string                 `json:"size"`
	AssetAddress string                 `json:"asset_address"`
	SubID        string                 `json:"sub_id"`
	CreatedAt    time.Time              `json:"created_at"`
	Market       string                 `json:"market,omitempty"`
	DisplayName  string                 `json:"display_name,omitempty"`
	SpotContract *spotOrderContractEcho `json:"spot_contract,omitempty"`
}

type fillsResponse struct {
	Fills []presentedFill `json:"fills"`
	// NextBefore pages to older fills; absent on the last page.
	NextBefore string `json:"next_before,omitempty"`
}

// handleFills serves GET /v1/fills: the fills on the authenticated owner's orders, newest first.
//
// It takes the same signed login as GET /v1/orders. A fill is part of an owner's order history — it
// is what the orders listed there actually did — and asking a trader to sign twice to see one account
// would buy no protection: either frame already reveals which orders are theirs. As with order
// history, the owner comes only from the signature. The public trade tape carries order ids but no
// owners; this is the endpoint that connects the two, so it is never served without that proof.
func (s *Server) handleFills(w http.ResponseWriter, r *http.Request) {
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
	before, err := decodeFillCursor(r.URL.Query().Get("before"))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	items, err := s.orders.ListFillsByOwner(r.Context(), owner, before, limit)
	if err != nil {
		slog.Error("list fills", "owner", owner, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load fills"})
		return
	}

	nextBefore := ""
	if len(items) == int(limit) {
		last := items[len(items)-1]
		nextBefore = encodeFillCursor(orders.FillCursor{TradeID: last.TradeID, Liquidity: last.Liquidity})
	}

	writeJSON(w, http.StatusOK, fillsResponse{
		Fills:      s.presentFills(items),
		NextBefore: nextBefore,
	})
}

// encodeFillCursor makes an opaque `before` value, like the order-history cursor.
func encodeFillCursor(cursor orders.FillCursor) string {
	value := strconv.FormatInt(cursor.TradeID, 10) + "|" + string(cursor.Liquidity)
	return base64.RawURLEncoding.EncodeToString([]byte(value))
}

func decodeFillCursor(raw string) (*orders.FillCursor, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}

	invalid := errors.New("before must be a next_before value returned by this endpoint")
	decoded, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return nil, invalid
	}
	tradeIDRaw, liquidity, found := strings.Cut(string(decoded), "|")
	if !found {
		return nil, invalid
	}
	tradeID, err := strconv.ParseInt(tradeIDRaw, 10, 64)
	if err != nil || tradeID <= 0 {
		return nil, invalid
	}
	switch orders.Liquidity(liquidity) {
	case orders.LiquidityTaker, orders.LiquidityMaker:
	default:
		return nil, invalid
	}
	return &orders.FillCursor{TradeID: tradeID, Liquidity: orders.Liquidity(liquidity)}, nil
}

func (s *Server) presentFills(items []orders.OwnerFill) []presentedFill {
	out := make([]presentedFill, 0, len(items))
	for _, item := range items {
		meta := instruments.Metadata{}
		if s.instruments != nil {
			meta, _ = s.instruments.ByAssetAndSubID(strings.ToLower(item.AssetAddress), item.SubID)
		}

		// Derived from the owner's order side, not the trade's aggressor side: for a maker fill those
		// are opposite, and the aggressor's view would show the trader's buy as a sell.
		var spotContract *spotOrderContractEcho
		if isSpotContractInstrument(meta) {
			spotContract, _ = deriveSpotOrderContractEchoFromEngine(item.OrderSide, item.Price, item.Size)
		}

		out = append(out, presentedFill{
			TradeID:      item.TradeID,
			OrderID:      item.OrderID,
			Liquidity:    item.Liquidity,
			Side:         item.OrderSide,
			Price:        item.Price,
			Size:         item.Size,
			AssetAddress: strings.ToLower(item.AssetAddress),
			SubID:        item.SubID,
			CreatedAt:    item.CreatedAt,
			Market:       meta.Symbol,
			DisplayName:  meta.DisplayName,
			SpotContract: spotContract,
		})
	}
	return out
}
