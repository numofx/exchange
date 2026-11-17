package matching

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

const (
	settlementVerifierInterval = 15 * time.Second
	// A transaction no node has heard of this long after its broadcast is taken as never sent. Ten minutes is far past
	// Base's inclusion time; a live one is in the mempool well before.
	settlementDroppedAfter = 10 * time.Minute
	settlementBatch        = 50
)

// settlementVerifier checks each matcher fill against the chain after the fact. execution-service answers on the
// broadcast (WAIT_FOR_RECEIPT=false), so a fill is recorded before its transaction is mined; one that then reverts, is
// replaced, or is never mined left a fill that never happened (2026-11-16 23:57, trade 547, voided by hand).
//
// A fill is voided only on proof: the receipt shows a revert, or the sender's nonce was consumed by another transaction
// with no receipt for this one, or neither the primary nor the fallback RPC has heard of the transaction ten minutes
// after it was sent. Anything else waits, and a fill still unproven at ten minutes is posted once. The perp's fills (a
// ledger the position indexer also moves) are never voided here: they are posted for a person. Runs in the matcher.
type settlementVerifier struct {
	rpc          *chainFundingChecker
	fallback     *chainFundingChecker // nil without CHAIN_RPC_FALLBACK_URL
	orders       *orders.Repository
	registry     *instruments.Registry
	alerts       *settlementAlerter
	droppedAfter time.Duration
	now          func() time.Time
	posted       map[int64]bool
}

func newSettlementVerifier(cfg config.Config, repo *orders.Repository, registry *instruments.Registry, alerts *settlementAlerter) *settlementVerifier {
	if strings.TrimSpace(cfg.ChainRPCURL) == "" {
		slog.Warn("settlement_verifier_inert", "reason", "CHAIN_RPC_URL is unset", "effect", "a fill whose transaction never lands stays on the tape")
		return nil
	}
	v := &settlementVerifier{
		rpc:          &chainFundingChecker{rpcURL: strings.TrimSpace(cfg.ChainRPCURL), httpClient: &http.Client{Timeout: 10 * time.Second}},
		orders:       repo,
		registry:     registry,
		alerts:       alerts,
		droppedAfter: settlementDroppedAfter,
		now:          time.Now,
		posted:       map[int64]bool{},
	}
	if cfg.ChainRPCFallbackURL != "" {
		v.fallback = &chainFundingChecker{rpcURL: cfg.ChainRPCFallbackURL, httpClient: &http.Client{Timeout: 10 * time.Second}}
	}
	return v
}

func (v *settlementVerifier) run(ctx context.Context) {
	ticker := time.NewTicker(settlementVerifierInterval)
	defer ticker.Stop()
	slog.Info("settlement_verifier_started", "dropped_after", v.droppedAfter, "fallback", v.fallback != nil)
	for {
		if err := v.tick(ctx); err != nil && ctx.Err() == nil {
			slog.Warn("settlement_verifier_tick_failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (v *settlementVerifier) tick(ctx context.Context) error {
	pending, err := v.orders.PendingSettlements(ctx, settlementBatch)
	if err != nil {
		return err
	}
	for _, f := range pending {
		outcome, reason, err := v.classify(ctx, f)
		if err != nil {
			slog.Warn("settlement_unreadable", "trade_id", f.TradeID, "tx_hash", f.TxHash, "error", err)
			continue
		}
		switch outcome {
		case settled:
			if err := v.orders.ConfirmSettlement(ctx, f.TradeID); err != nil {
				return err
			}
			delete(v.posted, f.TradeID)
		case notSettled:
			v.void(ctx, f, reason)
		default:
			if age := v.now().Sub(f.CreatedAt); age >= v.droppedAfter && !v.posted[f.TradeID] {
				v.posted[f.TradeID] = true
				v.alerts.NeedsResolution(fmt.Sprintf("Fill %d not mined %s after it was recorded (tx %s): %s. It stays on the tape until it lands or is proven gone.",
					f.TradeID, age.Round(time.Second), f.TxHash, reason), f.AssetAddress+":"+f.SubID, f.TakerOrderID, f.MakerOrderID, nil)
			}
		}
	}
	return nil
}

type settlementOutcome int

const (
	stillPending settlementOutcome = iota
	settled
	notSettled
)

// classify reads the chain for one fill. Only a mined receipt or proof it can never be mined is an answer.
func (v *settlementVerifier) classify(ctx context.Context, f orders.PendingSettlement) (settlementOutcome, string, error) {
	status, mined, err := v.receipt(ctx, v.rpc, f.TxHash)
	if err != nil {
		return stillPending, "", err
	}
	if mined {
		if status == 1 {
			return settled, "", nil
		}
		return notSettled, "reverted on chain", nil
	}
	from, nonce, known, err := v.transaction(ctx, v.rpc, f.TxHash)
	if err != nil {
		return stillPending, "", err
	}
	if known {
		latest, err := v.nonceOf(ctx, from)
		if err != nil {
			return stillPending, "", err
		}
		if latest <= nonce {
			return stillPending, "in the mempool", nil
		}
		// The nonce is consumed. If by this transaction, a receipt exists: ask again, and the fallback, before voiding.
		if s, m, err := v.receiptAnywhere(ctx, f.TxHash); err != nil || m {
			if err != nil {
				return stillPending, "", err
			}
			if s == 1 {
				return settled, "", nil
			}
			return notSettled, "reverted on chain", nil
		}
		return notSettled, fmt.Sprintf("replaced: nonce %d of %s was used by another transaction", nonce, from), nil
	}
	if v.fallback != nil {
		if _, _, knownThere, err := v.transaction(ctx, v.fallback, f.TxHash); err != nil || knownThere {
			if err != nil {
				return stillPending, "", err
			}
			return stillPending, "known to the fallback RPC only", nil
		}
		if s, m, err := v.receipt(ctx, v.fallback, f.TxHash); err != nil || m {
			if err != nil {
				return stillPending, "", err
			}
			if s == 1 {
				return settled, "", nil
			}
			return notSettled, "reverted on chain", nil
		}
	}
	if v.now().Sub(f.CreatedAt) < v.droppedAfter {
		return stillPending, "not yet seen by any node", nil
	}
	return notSettled, fmt.Sprintf("never seen by any node %s after the broadcast", v.droppedAfter), nil
}

func (v *settlementVerifier) receiptAnywhere(ctx context.Context, hash string) (uint64, bool, error) {
	s, m, err := v.receipt(ctx, v.rpc, hash)
	if err != nil || m || v.fallback == nil {
		return s, m, err
	}
	return v.receipt(ctx, v.fallback, hash)
}

func (v *settlementVerifier) receipt(ctx context.Context, c *chainFundingChecker, hash string) (uint64, bool, error) {
	raw, err := c.rpcCall(ctx, "eth_getTransactionReceipt", []any{hash})
	if err != nil {
		if strings.Contains(err.Error(), "empty rpc result") {
			return 0, false, nil
		}
		return 0, false, err
	}
	var r struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(raw, &r); err != nil {
		return 0, false, err
	}
	s, err := parseHexUint(r.Status)
	if err != nil {
		return 0, false, fmt.Errorf("receipt status: %w", err)
	}
	return s, true, nil
}

func (v *settlementVerifier) transaction(ctx context.Context, c *chainFundingChecker, hash string) (string, uint64, bool, error) {
	raw, err := c.rpcCall(ctx, "eth_getTransactionByHash", []any{hash})
	if err != nil {
		if strings.Contains(err.Error(), "empty rpc result") {
			return "", 0, false, nil
		}
		return "", 0, false, err
	}
	var t struct {
		From  string `json:"from"`
		Nonce string `json:"nonce"`
	}
	if err := json.Unmarshal(raw, &t); err != nil {
		return "", 0, false, err
	}
	n, err := parseHexUint(t.Nonce)
	if err != nil {
		return "", 0, false, fmt.Errorf("transaction nonce: %w", err)
	}
	return t.From, n, true, nil
}

func (v *settlementVerifier) nonceOf(ctx context.Context, from string) (uint64, error) {
	raw, err := v.rpc.rpcCall(ctx, "eth_getTransactionCount", []any{from, "latest"})
	if err != nil {
		return 0, err
	}
	var hex string
	if err := json.Unmarshal(raw, &hex); err != nil {
		return 0, err
	}
	return parseHexUint(hex)
}

func (v *settlementVerifier) void(ctx context.Context, f orders.PendingSettlement, reason string) {
	market := f.AssetAddress + ":" + f.SubID
	instrument, ok := v.registry.ByAssetAndSubID(f.AssetAddress, f.SubID)
	if ok {
		market = instrument.Symbol
	}
	if !ok || instrument.IsPerpetual() {
		if !v.posted[f.TradeID] {
			v.posted[f.TradeID] = true
			v.alerts.NeedsResolution(fmt.Sprintf("Fill %d did not settle (%s; tx %s) and is not voided automatically: void it by hand.",
				f.TradeID, reason, f.TxHash), market, f.TakerOrderID, f.MakerOrderID, nil)
		}
		return
	}
	var ledger *orders.VoidLedger
	if instrument.IsFuture() {
		if scale, ok := instrument.FixedAmountScale(); ok {
			ledger = &orders.VoidLedger{AssetAddress: instrument.AssetAddress, SubID: instrument.SubID, ChainPerUnit: scale}
		}
	}
	err := v.orders.VoidFill(ctx, f.TradeID, reason, ledger)
	switch {
	case errors.Is(err, orders.ErrVoidDeferred), errors.Is(err, orders.ErrNotPending):
		return
	case err != nil:
		slog.Error("settlement_void_failed", "trade_id", f.TradeID, "error", err)
		if !v.posted[f.TradeID] {
			v.posted[f.TradeID] = true
			v.alerts.NeedsResolution(fmt.Sprintf("Fill %d did not settle (%s; tx %s), and voiding it failed.", f.TradeID, reason, f.TxHash),
				market, f.TakerOrderID, f.MakerOrderID, err)
		}
		return
	}
	delete(v.posted, f.TradeID)
	slog.Warn("fill_voided", "trade_id", f.TradeID, "market", market, "tx_hash", f.TxHash, "reason", reason,
		"price", f.Price, "size", f.Size, "taker_order_id", f.TakerOrderID, "maker_order_id", f.MakerOrderID)
	v.alerts.Voided(fmt.Sprintf("%s fill %d (%s at %s) did not settle: %s.\ntx %s\nRemoved from the tape (kept in trade_fills_voided); taker %s and maker %s put back.",
		market, f.TradeID, f.Size, f.Price, reason, f.TxHash, f.TakerOrderID, f.MakerOrderID))
}
