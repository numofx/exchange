package api

import (
	"log/slog"
	"math/big"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// The /v1/integrations endpoints restate market data in the orientation /v1/markets advertises.
//
// The native endpoints report a spot market the way the matching engine holds it: cNGN is what
// trades, priced in USDC per cNGN. /v1/markets advertises that same market as USDC/cNGN. An
// aggregator that reads /v1/book or stats_24h at face value against the advertised pair publishes
// an inverted book (the engine's bids are orders selling USDC) and a 24h volume that counts cNGN as
// USDC, about 1,300 times too large. The native shapes stay as they are because the trading UI and
// the market maker read them; these endpoints are the ones to hand to a third party.

const (
	integrationBookDefaultDepth = 50
	integrationBookMaxDepth     = 500
	// integrationBookOrderScan bounds how many resting orders per side are read to build levels.
	integrationBookOrderScan = 1000
	integrationTradesDefault = 100
	integrationTradesMax     = 500
)

// integrationLevel is one aggregated price level: [price, quantity in the base asset].
type integrationLevel [2]string

type integrationOrderbookResponse struct {
	TickerID  string             `json:"ticker_id"`
	Timestamp int64              `json:"timestamp"`
	Bids      []integrationLevel `json:"bids"`
	Asks      []integrationLevel `json:"asks"`
}

// integrationTicker leaves price fields null rather than omitting them: "no bid" and "field
// missing" must stay distinguishable to a client.
type integrationTicker struct {
	TickerID       string  `json:"ticker_id"`
	BaseCurrency   string  `json:"base_currency"`
	TargetCurrency string  `json:"target_currency"`
	LastPrice      *string `json:"last_price"`
	BaseVolume     string  `json:"base_volume"`
	TargetVolume   string  `json:"target_volume"`
	Bid            *string `json:"bid"`
	Ask            *string `json:"ask"`
	High           *string `json:"high"`
	Low            *string `json:"low"`
}

type integrationTrade struct {
	TradeID        int64  `json:"trade_id"`
	Price          string `json:"price"`
	BaseVolume     string `json:"base_volume"`
	TargetVolume   string `json:"target_volume"`
	TradeTimestamp int64  `json:"trade_timestamp"`
	// Type is the taker's side in terms of the base asset: buy means the taker acquired it.
	Type orders.Side `json:"type"`
}

type integrationTradesResponse struct {
	TickerID          string             `json:"ticker_id"`
	Trades            []integrationTrade `json:"trades"`
	NextBeforeTradeID int64              `json:"next_before_trade_id,omitempty"`
}

// marketOrientation maps engine values onto a market's advertised base and quote.
type marketOrientation struct {
	// inverted is true when the engine trades the advertised quote asset, priced in the base.
	// It uses the same predicate that derives spot_contract, so the two views cannot disagree.
	inverted bool
}

func orientationFor(market instruments.Metadata) marketOrientation {
	return marketOrientation{inverted: isSpotContractInstrument(market)}
}

func (o marketOrientation) priceScale() int {
	if o.inverted {
		return spotUIPriceDecimalScale
	}
	return spotEngineDecimalScale
}

func (o marketOrientation) baseScale() int {
	if o.inverted {
		return spotUISizeDecimalScale
	}
	return spotEngineDecimalScale
}

// price converts a positive engine price to base-quoted form.
func (o marketOrientation) price(enginePrice *big.Rat) *big.Rat {
	if o.inverted {
		return new(big.Rat).Inv(enginePrice)
	}
	return new(big.Rat).Set(enginePrice)
}

// volumes splits an engine amount at an engine price into base and target quantities.
func (o marketOrientation) volumes(enginePrice *big.Rat, engineAmount *big.Rat) (base *big.Rat, target *big.Rat) {
	notional := new(big.Rat).Mul(engineAmount, enginePrice)
	if o.inverted {
		return notional, new(big.Rat).Set(engineAmount)
	}
	return new(big.Rat).Set(engineAmount), notional
}

func (o marketOrientation) side(engineSide orders.Side) orders.Side {
	if !o.inverted {
		return engineSide
	}
	if engineSide == orders.SideBuy {
		return orders.SideSell
	}
	return orders.SideBuy
}

// formatDecimalDirected formats a non-negative value at scale, rounding up or down rather than to
// nearest. Book prices round away from the touch so a level never shows a better price than the
// orders behind it will trade at.
func formatDecimalDirected(value *big.Rat, scale int, up bool) string {
	scaled := new(big.Rat).Mul(value, new(big.Rat).SetInt(pow10(scale)))
	quotient, remainder := new(big.Int).QuoRem(scaled.Num(), scaled.Denom(), new(big.Int))
	if up && remainder.Sign() != 0 {
		quotient.Add(quotient, big.NewInt(1))
	}
	return formatDecimal(new(big.Rat).SetFrac(quotient, pow10(scale)), scale)
}

func (s *Server) resolveIntegrationMarket(w http.ResponseWriter, r *http.Request) (instruments.Metadata, bool) {
	tickerID := strings.TrimSpace(r.URL.Query().Get("ticker_id"))
	if tickerID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "ticker_id is required"})
		return instruments.Metadata{}, false
	}
	// Unlike resolveMarket, never fall back to a default market: an integrator asking for a pair
	// that does not exist must hear so, not receive another pair's data under its ticker.
	if s.instruments != nil {
		if item, ok := s.instruments.BySymbol(tickerID); ok && item.Enabled && item.AssetAddress != "" {
			return item, true
		}
	}
	writeJSON(w, http.StatusBadRequest, map[string]string{"error": "unknown ticker_id"})
	return instruments.Metadata{}, false
}

func parseBoundedQueryInt(r *http.Request, name string, fallback int, maximum int) (int, bool) {
	raw := strings.TrimSpace(r.URL.Query().Get(name))
	if raw == "" {
		return fallback, true
	}
	parsed, err := strconv.Atoi(raw)
	if err != nil || parsed <= 0 || parsed > maximum {
		return 0, false
	}
	return parsed, true
}

func (s *Server) handleIntegrationOrderbook(w http.ResponseWriter, r *http.Request) {
	market, ok := s.resolveIntegrationMarket(w, r)
	if !ok {
		return
	}
	depth, ok := parseBoundedQueryInt(r, "depth", integrationBookDefaultDepth, integrationBookMaxDepth)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "depth must be between 1 and " + strconv.Itoa(integrationBookMaxDepth),
		})
		return
	}

	engineBids, engineAsks, err := s.orders.ListBook(r.Context(), strings.ToLower(market.AssetAddress), market.SubID, integrationBookOrderScan)
	if err != nil {
		slog.Error("integration orderbook", "market", market.Symbol, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load orderbook"})
		return
	}

	orientation := orientationFor(market)
	// Inverted, the engine's asks are orders buying the base asset. Each engine side is already in
	// price-time priority, and inverting a price reverses its order, so the lists need no re-sort.
	bidOrders, askOrders := engineBids, engineAsks
	if orientation.inverted {
		bidOrders, askOrders = engineAsks, engineBids
	}

	writeJSON(w, http.StatusOK, integrationOrderbookResponse{
		TickerID:  market.Symbol,
		Timestamp: time.Now().UnixMilli(),
		Bids:      buildIntegrationLevels(bidOrders, orientation, false, depth),
		Asks:      buildIntegrationLevels(askOrders, orientation, true, depth),
	})
}

// buildIntegrationLevels aggregates best-first orders into at most depth levels. roundPriceUp is
// true for asks: bids round down and asks round up, and quantities round down, so nothing shown is
// better than what is resting.
func buildIntegrationLevels(items []orders.Order, orientation marketOrientation, roundPriceUp bool, depth int) []integrationLevel {
	levels := []integrationLevel{}
	var currentPrice string
	var currentQuantity *big.Rat

	flush := func() {
		if currentQuantity == nil {
			return
		}
		if quantity := formatDecimalDirected(currentQuantity, orientation.baseScale(), false); quantity != "0" {
			levels = append(levels, integrationLevel{currentPrice, quantity})
		}
		currentQuantity = nil
	}

	for _, order := range items {
		enginePrice, err := parsePositiveDecimal(order.LimitPrice, "limit_price")
		if err != nil {
			slog.Warn("integration orderbook skipped order", "order_id", order.OrderID, "error", err)
			continue
		}
		desired, err := parseDecimal(order.DesiredAmount)
		if err != nil {
			slog.Warn("integration orderbook skipped order", "order_id", order.OrderID, "error", err)
			continue
		}
		filled, err := parseDecimal(order.FilledAmount)
		if err != nil {
			slog.Warn("integration orderbook skipped order", "order_id", order.OrderID, "error", err)
			continue
		}
		remaining := new(big.Rat).Sub(desired, filled)
		if remaining.Sign() <= 0 {
			continue
		}

		price := formatDecimalDirected(orientation.price(enginePrice), orientation.priceScale(), roundPriceUp)
		base, _ := orientation.volumes(enginePrice, remaining)
		if currentQuantity != nil && price == currentPrice {
			currentQuantity.Add(currentQuantity, base)
			continue
		}
		flush()
		if len(levels) == depth {
			break
		}
		currentPrice, currentQuantity = price, base
	}
	if len(levels) < depth {
		flush()
	}
	return levels
}

func (s *Server) handleIntegrationTickers(w http.ResponseWriter, r *http.Request) {
	tickers := []integrationTicker{}
	if s.instruments == nil {
		writeJSON(w, http.StatusOK, tickers)
		return
	}

	markets := s.instruments.Enabled()
	sort.Slice(markets, func(i, j int) bool { return markets[i].Symbol < markets[j].Symbol })

	for _, market := range markets {
		if market.AssetAddress == "" {
			continue
		}
		ticker, err := s.integrationTicker(r, market)
		if err != nil {
			slog.Error("integration ticker", "market", market.Symbol, "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load tickers"})
			return
		}
		tickers = append(tickers, ticker)
	}
	writeJSON(w, http.StatusOK, tickers)
}

func (s *Server) integrationTicker(r *http.Request, market instruments.Metadata) (integrationTicker, error) {
	ctx := r.Context()
	asset := strings.ToLower(market.AssetAddress)
	orientation := orientationFor(market)

	stats, err := s.orders.GetTradeStats24h(ctx, asset, market.SubID)
	if err != nil {
		return integrationTicker{}, err
	}
	// Last price comes from the latest fill ever, not the 24h window: a quiet day has a last price.
	latest, err := s.orders.ListTrades(ctx, asset, market.SubID, 0, 1)
	if err != nil {
		return integrationTicker{}, err
	}
	engineBid, engineAsk, err := s.orders.BestBidAndAsk(ctx, asset, market.SubID)
	if err != nil {
		return integrationTicker{}, err
	}

	ticker := integrationTicker{
		TickerID:       market.Symbol,
		BaseCurrency:   market.BaseAssetSymbol,
		TargetCurrency: market.QuoteAssetSymbol,
		BaseVolume:     "0",
		TargetVolume:   "0",
	}

	// stats.Volume is the engine's traded amount and QuoteVolume its notional. Inverted, the
	// notional is what the advertised base asset measures.
	baseVolume, targetVolume := stats.Volume, stats.QuoteVolume
	if orientation.inverted {
		baseVolume, targetVolume = stats.QuoteVolume, stats.Volume
	}
	if value := optionalDecimal(baseVolume, orientation.baseScale(), false); value != nil {
		ticker.BaseVolume = *value
	}
	if value := optionalDecimal(targetVolume, spotEngineDecimalScale, false); value != nil {
		ticker.TargetVolume = *value
	}

	if len(latest) > 0 {
		ticker.LastPrice = optionalPrice(latest[0].Price, orientation, false)
	}
	high, low := stats.High, stats.Low
	if orientation.inverted {
		high, low = low, high
	}
	ticker.High = optionalPrice(high, orientation, false)
	ticker.Low = optionalPrice(low, orientation, false)

	bidOrder, askOrder := engineBid, engineAsk
	if orientation.inverted {
		bidOrder, askOrder = engineAsk, engineBid
	}
	// Rounded the same way as the orderbook's top level, so the two endpoints agree.
	if bidOrder != nil {
		ticker.Bid = optionalPrice(bidOrder.LimitPrice, orientation, false)
	}
	if askOrder != nil {
		ticker.Ask = optionalPrice(askOrder.LimitPrice, orientation, true)
	}
	return ticker, nil
}

// optionalPrice orients an engine price, or returns nil when there is none. Stats and last price
// round down, like a bid; only an ask rounds up.
func optionalPrice(enginePrice string, orientation marketOrientation, roundUp bool) *string {
	if strings.TrimSpace(enginePrice) == "" {
		return nil
	}
	parsed, err := parsePositiveDecimal(enginePrice, "price")
	if err != nil {
		return nil
	}
	formatted := formatDecimalDirected(orientation.price(parsed), orientation.priceScale(), roundUp)
	return &formatted
}

func optionalDecimal(raw string, scale int, roundUp bool) *string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parsed, err := parseDecimal(raw)
	if err != nil || parsed.Sign() < 0 {
		return nil
	}
	formatted := formatDecimalDirected(parsed, scale, roundUp)
	return &formatted
}

func (s *Server) handleIntegrationTrades(w http.ResponseWriter, r *http.Request) {
	market, ok := s.resolveIntegrationMarket(w, r)
	if !ok {
		return
	}
	limit, ok := parseBoundedQueryInt(r, "limit", integrationTradesDefault, integrationTradesMax)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "limit must be between 1 and " + strconv.Itoa(integrationTradesMax),
		})
		return
	}
	beforeTradeID := int64(0)
	if raw := strings.TrimSpace(r.URL.Query().Get("before_trade_id")); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": "before_trade_id must be a positive integer"})
			return
		}
		beforeTradeID = parsed
	}

	items, err := s.orders.ListTrades(r.Context(), strings.ToLower(market.AssetAddress), market.SubID, beforeTradeID, int32(limit))
	if err != nil {
		slog.Error("integration trades", "market", market.Symbol, "error", err)
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to load trades"})
		return
	}

	orientation := orientationFor(market)
	trades := make([]integrationTrade, 0, len(items))
	for _, item := range items {
		enginePrice, err := parsePositiveDecimal(item.Price, "price")
		if err != nil {
			slog.Warn("integration trades skipped fill", "trade_id", item.TradeID, "error", err)
			continue
		}
		engineSize, err := parsePositiveDecimal(item.Size, "size")
		if err != nil {
			slog.Warn("integration trades skipped fill", "trade_id", item.TradeID, "error", err)
			continue
		}
		base, target := orientation.volumes(enginePrice, engineSize)
		trades = append(trades, integrationTrade{
			TradeID:        item.TradeID,
			Price:          formatDecimal(orientation.price(enginePrice), orientation.priceScale()),
			BaseVolume:     formatDecimal(base, orientation.baseScale()),
			TargetVolume:   formatDecimal(target, spotEngineDecimalScale),
			TradeTimestamp: item.CreatedAt.UnixMilli(),
			Type:           orientation.side(item.AggressorSide),
		})
	}

	next := int64(0)
	if len(items) == limit {
		next = items[len(items)-1].TradeID
	}
	writeJSON(w, http.StatusOK, integrationTradesResponse{
		TickerID:          market.Symbol,
		Trades:            trades,
		NextBeforeTradeID: next,
	})
}
