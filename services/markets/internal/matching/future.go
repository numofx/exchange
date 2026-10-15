package matching

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/futures"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// The matcher reads the band fresh enough that a fill it passes is a fill the chain passes, short of
// the index moving in the seconds before the transaction lands (which reverts FA_FillOutsideIndexBand,
// classified balance-dependent: the pair backs off and is retried against the next band).
const (
	futureBandTTL  = 2 * time.Second
	futureStateTTL = 30 * time.Second
)

// ErrFutureContractSizeMismatch stops the matcher: the venue presents a contract size, and charges
// its fee on it, that is not the chain's.
var ErrFutureContractSizeMismatch = errors.New("future contract size mismatch")

func newFutureReader(cfg config.Config) *futures.Reader {
	if !cfg.FutureEnabled() {
		return nil
	}
	return futures.NewReader(cfg.ChainRPCURL, cfg.CNGNFutureAssetAddress, cfg.CNGNFutureExpiry, futureBandTTL, futureStateTTL)
}

// verifyFutureContractSize refuses to start when the registry's contract size is not the chain's.
// Unreadable is not a refusal: every future fill reads the chain's size before it is charged, and is
// refused if it cannot.
func verifyFutureContractSize(ctx context.Context, reader *futures.Reader, instrument instruments.Metadata) error {
	if reader == nil {
		return nil
	}
	onChain, err := reader.ContractSize(ctx)
	if err != nil {
		slog.Warn("future_contract_size_unverified", "market", instrument.Symbol, "error", err.Error())
		return nil
	}
	presented, ok := new(big.Rat).SetString(instrument.ContractMultiplier)
	if !ok {
		return fmt.Errorf("%w: %s presents contract size %q", ErrFutureContractSizeMismatch, instrument.Symbol, instrument.ContractMultiplier)
	}
	presented.Mul(presented, new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)))
	if !presented.IsInt() || presented.Num().Cmp(onChain) != 0 {
		return fmt.Errorf("%w: %s presents %s USDC a contract, FutureAsset.contractSize() is %s",
			ErrFutureContractSizeMismatch, instrument.Symbol, instrument.ContractMultiplier, futures.Decimal(onChain))
	}
	slog.Info("future_contract_size_verified", "market", instrument.Symbol, "contract_size", futures.Decimal(onChain))
	return nil
}

// futureOpen gates the tick: a series not yet enabled on chain is listed (so quotes can rest) but
// never crossed, as the perp is before its gate opens. Unreadable is closed.
func (e *Engine) futureOpen(ctx context.Context, instrument instruments.Metadata) bool {
	if e.future == nil {
		return false
	}
	open, reason, err := e.future.TradingOpen(ctx, instrument.TradeModuleAddress, instrument.MarginManagerAddress)
	if err != nil {
		slog.Warn("future_gate_unreadable", "market", instrument.Symbol, "error", err.Error())
		return false
	}
	if !open {
		slog.Debug("future_gate_closed", "market", instrument.Symbol, "reason", reason)
	}
	return open
}

// futureBandRevert is how a fill the venue refuses for the band is recorded: as the chain would have
// reverted it. Balance-dependent, not permanent: the index moves, and the same pair can come back into
// the band.
var futureBandRevert = settlementRevert{Selector: "0x01bb8f43", Name: "FA_FillOutsideIndexBand", Class: revertBalanceDependent}

// futureFillInBand checks the fill's on-chain price against the band now. A stale or unreadable index
// refuses: the chain would revert the fill too (BLF_DataTooOld), or cannot be shown not to.
func (e *Engine) futureFillInBand(ctx context.Context, instrument instruments.Metadata, candidate orders.MatchCandidate, fillPrice string) bool {
	price, ok := new(big.Int).SetString(strings.TrimSpace(fillPrice), 10)
	if !ok {
		e.noteMatchFailure(instrument.Symbol, candidate, "fill_price_unparseable", settlementRevert{})
		return false
	}
	band, err := e.future.Band(ctx)
	if err != nil {
		reason := "fill_band_unreadable"
		if errors.Is(err, futures.ErrIndexStale) {
			reason = "fill_band_index_stale"
		}
		e.noteMatchFailure(instrument.Symbol, candidate, reason, settlementRevert{})
		slog.Warn("future_fill_refused", "market", instrument.Symbol, "reason", reason, "error", err.Error(),
			"taker_order_id", candidate.Taker.OrderID, "maker_order_id", candidate.Maker.OrderID)
		return false
	}
	if !band.Allows(price) {
		e.noteMatchFailure(instrument.Symbol, candidate, "fill_outside_band", futureBandRevert)
		slog.Info("future_fill_refused", "market", instrument.Symbol, "reason", "fill_outside_band",
			"fill_price", futures.Decimal(price), "band_low", futures.Decimal(band.Low()), "band_high", futures.Decimal(band.High()),
			"taker_order_id", candidate.Taker.OrderID, "maker_order_id", candidate.Maker.OrderID)
		return false
	}
	return true
}

// feeNotionalPrice is the per-unit notional takerFillFee charges on, 18dp USDC. A perp or spot fill's
// notional is price x amount; a future's is contracts x contract size, whatever its price in cNGN.
func (e *Engine) feeNotionalPrice(ctx context.Context, instrument instruments.Metadata, fillPrice string) (string, error) {
	if !instrument.IsFuture() {
		return fillPrice, nil
	}
	if e.future == nil {
		return "", errors.New("no future reader configured")
	}
	size, err := e.future.ContractSize(ctx)
	if err != nil {
		return "", fmt.Errorf("contractSize unreadable: %w", err)
	}
	return size.String(), nil
}

// futureMarkAt is the mark a settled future fill was valued at, read from its transaction, recorded
// with the fill so its variation margin can be reported. Empty when it cannot be read: the fill is
// recorded either way, its VM unknown rather than wrong.
func (e *Engine) futureMarkAt(ctx context.Context, instrument instruments.Metadata, txHash string) string {
	if e.future == nil || strings.TrimSpace(txHash) == "" {
		return ""
	}
	mark, err := e.future.MarkAtFill(ctx, txHash)
	if err != nil {
		slog.Warn("future_fill_mark_unread", "market", instrument.Symbol, "tx_hash", txHash, "error", err.Error())
		return ""
	}
	return futures.Decimal(mark)
}
