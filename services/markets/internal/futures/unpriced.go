package futures

import (
	"context"
	"fmt"
	"log/slog"
	"math/big"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// positionReadTimeout bounds each startup read of a series' open positions.
const positionReadTimeout = 10 * time.Second

// PositionReader is a series' positions held under its engine, in the FutureAsset's 1e18 a contract.
type PositionReader func(ctx context.Context, series config.FutureSeries) (*big.Int, error)

// ChainPositions reads FutureAsset.totalPosition(engine). It counts every series on the asset, so a
// series sharing its asset with one that holds positions reads as holding them: the safe direction.
func ChainPositions(rpcURL string) PositionReader {
	return func(ctx context.Context, series config.FutureSeries) (*big.Int, error) {
		return NewSeriesReader(rpcURL, series, 0, 0).TotalPosition(ctx, series.ManagerAddress)
	}
}

// TotalPosition is FutureAsset.totalPosition(manager).
func (r *Reader) TotalPosition(ctx context.Context, manager string) (*big.Int, error) {
	raw, err := r.call(ctx, r.future, sigTotalPosition+addressWord(manager))
	if err != nil {
		return nil, err
	}
	position, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("totalPosition: %w", err)
	}
	return position, nil
}

// ResolveUnpricedSeries settles each FUTURE_SERIES entry without a taker_fee_bps before anything lists
// it, so that a missing fee never takes the process down with every other market:
//
//   - no positions under its engine: the series is dropped, unlisted, with an error logged;
//   - positions, or a read that fails: it stays listed close-only, so holders can still close, at a fee
//     of 0 rather than one nobody chose.
//
// Priced series are returned unchanged. The config is copied, never edited in place.
func ResolveUnpricedSeries(ctx context.Context, cfg config.Config, positions PositionReader) config.Config {
	resolved := make([]config.FutureSeries, 0, len(cfg.FutureSeries))
	for _, series := range cfg.FutureSeries {
		if series.Priced() {
			resolved = append(resolved, series)
			continue
		}
		readCtx, cancel := context.WithTimeout(ctx, positionReadTimeout)
		position, err := positions(readCtx, series)
		cancel()
		if err == nil && position.Sign() == 0 {
			slog.Error("future_series_unpriced_skipped", "market", series.MarketSymbol(), "asset", series.AssetAddress,
				"reason", "taker_fee_bps is not set and no position is open: the series is not listed")
			continue
		}
		zero := 0
		series.CloseOnly, series.TakerFeeBps = true, &zero
		attrs := []any{"market", series.MarketSymbol(), "asset", series.AssetAddress,
			"reason", "taker_fee_bps is not set but positions may be open: listed close-only at no fee"}
		if err != nil {
			attrs = append(attrs, "position_error", err.Error())
		} else {
			attrs = append(attrs, "total_position", position.String())
		}
		slog.Error("future_series_unpriced_close_only", attrs...)
		resolved = append(resolved, series)
	}
	cfg.FutureSeries = resolved
	return cfg
}
