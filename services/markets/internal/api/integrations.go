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

// The /v1/integrations endpoints restate market data in the orientation /v1/markets advertises,
// in the shape aggregators read: an aggregated book, a ticker and a trade tape per market.
//
// Since the cngn_usdc_*_v1 contract the advertised pair is the engine's own -- cNGN is what trades,
// priced in USDC per cNGN -- so nothing is inverted here any more. What remains is presentation:
// levels are aggregated and rounded away from the touch, and markets under the ui_intent contract
// are shown at the UI's price and size scales rather than the engine's 18 places.

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

// marketOrientation maps engine values onto a market's advertised base and quote. The advertised
// pair is the engine's own, so price, volumes and side pass through; only the scales differ. It uses
// the same predicate that derives spot_contract, so the two views cannot disagree.
type marketOrientation struct {
	// uiScales is true for markets under the ui_intent contract, shown at the UI's scales.
	uiScales bool
}

func orientationFor(market instruments.Metadata) marketOrientation {
	return marketOrientation{uiScales: isSpotContractInstrument(market)}
}

func (o marketOrientation) priceScale() int {
	if o.uiScales {
		return spotUIPriceDecimalScale
	}
	return spotEngineDecimalScale
}

func (o marketOrientation) baseScale() int {
	if o.uiScales {
		return spotUISizeDecimalScale
	}
	return spotEngineDecimalScale
}

// price is the engine price in base-quoted form: the same number.
func (o marketOrientation) price(enginePrice *big.Rat) *big.Rat {
	return new(big.Rat).Set(enginePrice)
}

// volumes splits an engine amount at an engine price into base and target quantities: the amount
// is the base (cNGN) and its notional the target (USDC).
func (o marketOrientation) volumes(enginePrice *big.Rat, engineAmount *big.Rat) (base *big.Rat, target *big.Rat) {
	return new(big.Rat).Set(engineAmount), new(big.Rat).Mul(engineAmount, enginePrice)
}

func (o marketOrientation) side(engineSide orders.Side) orders.Side {
	return engineSide
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
	// The registry's exact-match lookup: an integrator asking for a pair that does not exist must
	// hear so, not receive another pair's data under its ticker.
	if item, deprecated, ok := s.instruments.ResolveIdentifier(tickerID); ok {
		if deprecated {
			markDeprecatedIdentifier(w, item)
		}
		return item, true
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
	// Each engine side is already in price-time priority, so the lists need no re-sort.
	writeJSON(w, http.StatusOK, integrationOrderbookResponse{
		TickerID:  market.Symbol,
		Timestamp: time.Now().UnixMilli(),
		Bids:      buildIntegrationLevels(engineBids, orientation, false, depth),
		Asks:      buildIntegrationLevels(engineAsks, orientation, true, depth),
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

	// stats.Volume is the engine's traded amount (the base, cNGN) and QuoteVolume its notional
	// (the target, USDC).
	if value := optionalDecimal(stats.Volume, orientation.baseScale(), false); value != nil {
		ticker.BaseVolume = *value
	}
	if value := optionalDecimal(stats.QuoteVolume, spotEngineDecimalScale, false); value != nil {
		ticker.TargetVolume = *value
	}

	if len(latest) > 0 {
		ticker.LastPrice = optionalPrice(latest[0].Price, orientation, false)
	}
	ticker.High = optionalPrice(stats.High, orientation, false)
	ticker.Low = optionalPrice(stats.Low, orientation, false)

	// Rounded the same way as the orderbook's top level, so the two endpoints agree.
	if engineBid != nil {
		ticker.Bid = optionalPrice(engineBid.LimitPrice, orientation, false)
	}
	if engineAsk != nil {
		ticker.Ask = optionalPrice(engineAsk.LimitPrice, orientation, true)
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
