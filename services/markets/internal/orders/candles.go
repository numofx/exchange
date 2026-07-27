package orders

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// Candle is one OHLCV bucket aggregated from trade_fills.
//
// Prices are the raw engine values exactly as stored, matching what ListTrades
// returns — display conversion (including the spot reciprocal) is the client's
// job, so the chart and the trade prints cannot disagree.
type Candle struct {
	BucketStart time.Time
	Open        string
	High        string
	Low         string
	Close       string
	// Volume is base volume: the summed trade size in engine units.
	Volume string
	// QuoteVolume is sum(size * price), accumulated per trade before aggregation.
	// It cannot be recovered from Volume and the OHLC afterwards, and spot needs it:
	// the UI shows spot notional in USDC, which is the engine cNGN amount times the
	// engine price.
	QuoteVolume string
	TradeCount  int64
}

// CandleInterval is a supported bucket width. Arbitrary widths are deliberately
// not accepted: a whitelist keeps buckets aligned to wall-clock boundaries and
// bounds how much work one request can ask for.
type CandleInterval struct {
	Name    string
	Seconds int
}

var candleIntervals = []CandleInterval{
	{"1m", 60},
	{"5m", 300},
	{"15m", 900},
	{"1h", 3600},
	{"4h", 14400},
	{"1d", 86400},
}

// ParseCandleInterval resolves an interval name such as "1h".
func ParseCandleInterval(name string) (CandleInterval, error) {
	trimmed := strings.TrimSpace(name)
	for _, candidate := range candleIntervals {
		if candidate.Name == trimmed {
			return candidate, nil
		}
	}
	return CandleInterval{}, fmt.Errorf("unsupported interval %q", name)
}

// CandleIntervalNames lists the supported intervals, for error messages.
func CandleIntervalNames() []string {
	names := make([]string, 0, len(candleIntervals))
	for _, candidate := range candleIntervals {
		names = append(names, candidate.Name)
	}
	return names
}

// ListCandles returns up to limit of the most recent OHLCV buckets for a market,
// ordered oldest first so a chart can render them directly.
//
// Buckets with no trades are absent rather than zero-filled: this venue trades
// sparsely, and emitting flat synthetic candles for empty periods would invent
// price action that never happened. Callers that need a continuous axis should
// carry the previous close forward themselves, explicitly.
func (r *Repository) ListCandles(
	ctx context.Context,
	assetAddress string,
	subID string,
	interval CandleInterval,
	start time.Time,
	end time.Time,
	limit int32,
) ([]Candle, error) {
	if interval.Seconds <= 0 {
		return nil, fmt.Errorf("invalid candle interval")
	}
	if limit <= 0 {
		limit = 200
	}

	// open/close come from array_agg ordered by time; high/low from array_agg
	// ordered by price. Taking all four from the stored text (rather than a
	// numeric aggregate) keeps their formatting identical to /v1/trades.
	const query = `
with bucketed as (
  select
    to_timestamp(floor(extract(epoch from created_at) / $3::numeric) * $3::numeric) as bucket_start,
    price,
    size,
    created_at,
    trade_id
  from trade_fills
  where asset_address = $1
    and sub_id = $2
    and ($4::timestamptz is null or created_at >= $4::timestamptz)
    and ($5::timestamptz is null or created_at < $5::timestamptz)
),
aggregated as (
  select
    bucket_start,
    (array_agg(price order by created_at asc, trade_id asc))[1]   as open,
    (array_agg(price order by price::numeric desc))[1]            as high,
    (array_agg(price order by price::numeric asc))[1]             as low,
    (array_agg(price order by created_at desc, trade_id desc))[1] as close,
    sum(size::numeric)::text                                     as volume,
    sum(size::numeric * price::numeric)::text                    as quote_volume,
    count(*)::bigint                                             as trade_count
  from bucketed
  group by bucket_start
  order by bucket_start desc
  limit $6
)
select bucket_start, open, high, low, close, volume, quote_volume, trade_count
from aggregated
order by bucket_start asc
`

	var startArg, endArg any
	if !start.IsZero() {
		startArg = start.UTC()
	}
	if !end.IsZero() {
		endArg = end.UTC()
	}

	rows, err := r.pool.Query(ctx, query,
		strings.ToLower(strings.TrimSpace(assetAddress)),
		strings.TrimSpace(subID),
		interval.Seconds,
		startArg,
		endArg,
		limit,
	)
	if err != nil {
		return nil, mapPGError(err)
	}
	defer rows.Close()

	candles := make([]Candle, 0, limit)
	for rows.Next() {
		var candle Candle
		if err := rows.Scan(
			&candle.BucketStart,
			&candle.Open,
			&candle.High,
			&candle.Low,
			&candle.Close,
			&candle.Volume,
			&candle.QuoteVolume,
			&candle.TradeCount,
		); err != nil {
			return nil, mapPGError(err)
		}
		candles = append(candles, candle)
	}
	if err := rows.Err(); err != nil {
		return nil, mapPGError(err)
	}

	return candles, nil
}
