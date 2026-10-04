package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"strings"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
)

// balanceAdjustedTopic is keccak256 of
// BalanceAdjusted(uint256,address,bytes32,int256,int256,int256,uint256), the SubAccounts event every
// balance change emits, whoever caused it. TestBalanceAdjustedTopicMatchesItsSignature pins it.
const balanceAdjustedTopic = "0x503ec09c1b4597d114eca849f7013c8c457988802d1dc5da49a0c461b5f88658"

const (
	positionIndexerInterval      = 10 * time.Second
	positionIndexerConfirmations = 2
	positionIndexerChunk         = 2000
)

// positionIndexer follows the perp asset's BalanceAdjusted events on SubAccounts and writes each
// account's post-balance into the perp_positions ledger, so a position a liquidation, settlement or
// transfer changed is what a reduce-only order is clamped against -- not the position after the
// venue's own fills alone. The venue's own fills are skipped (FinalizeMatchWithPrice moves the ledger
// for those, in the fill's transaction); events are read a couple of blocks behind the head so a
// fill's row is in trade_fills by the time its event is seen. Runs inside the matcher, one instance.
type positionIndexer struct {
	rpc           *chainFundingChecker
	orders        *orders.Repository
	perp          string
	interval      time.Duration
	confirmations uint64
	chunk         uint64
}

func newPositionIndexer(cfg config.Config, repo *orders.Repository, margin marginChecker) *positionIndexer {
	checker, ok := margin.(*chainMarginChecker)
	if !ok || checker == nil || !cfg.PerpEnabled() {
		if cfg.PerpEnabled() {
			slog.Warn("perp_position_indexer_inert", "reason", "no chain reader", "effect", "the reduce-only ledger follows venue fills and match-time chain reads only")
		}
		return nil
	}
	return &positionIndexer{
		rpc:           checker.rpc,
		orders:        repo,
		perp:          strings.ToLower(strings.TrimSpace(cfg.CNGNPerpAssetAddress)),
		interval:      positionIndexerInterval,
		confirmations: positionIndexerConfirmations,
		chunk:         positionIndexerChunk,
	}
}

func (p *positionIndexer) run(ctx context.Context) {
	ticker := time.NewTicker(p.interval)
	defer ticker.Stop()
	slog.Info("perp_position_indexer_started", "perp", p.perp, "interval", p.interval, "confirmations", p.confirmations)
	for {
		if err := p.tick(ctx); err != nil && ctx.Err() == nil {
			slog.Warn("perp_position_indexer_tick_failed", "error", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (p *positionIndexer) tick(ctx context.Context) error {
	head, err := p.blockNumber(ctx)
	if err != nil {
		return fmt.Errorf("read head: %w", err)
	}
	if head < p.confirmations {
		return nil
	}
	through := head - p.confirmations
	cursor, ok, err := p.orders.PerpPositionCursor(ctx, p.perp)
	if err != nil {
		return err
	}
	if !ok {
		// First run: the ledger is seeded from the chain when an account first submits reduce-only,
		// so there is nothing to backfill; follow from here.
		if err := p.orders.SetPerpPositionCursor(ctx, p.perp, through); err != nil {
			return err
		}
		slog.Info("perp_position_indexer_cursor_started", "block", through)
		return nil
	}
	if through <= cursor {
		return nil
	}
	subAccounts, err := p.rpc.subAccountsAddress(ctx)
	if err != nil {
		return fmt.Errorf("read SubAccounts address: %w", err)
	}
	for from := cursor + 1; from <= through; {
		to := from + p.chunk - 1
		if to > through {
			to = through
		}
		logs, err := p.logs(ctx, subAccounts, from, to)
		if err != nil {
			return fmt.Errorf("read logs %d..%d: %w", from, to, err)
		}
		adjustments, err := decodeBalanceAdjustedLogs(logs)
		if err != nil {
			return err
		}
		applied, skipped, err := p.orders.ApplyChainAdjustments(ctx, p.perp, adjustments, to)
		if err != nil {
			return fmt.Errorf("apply adjustments %d..%d: %w", from, to, err)
		}
		if applied > 0 || skipped > 0 {
			for _, adjustment := range adjustments {
				slog.Info("perp_position_adjusted_on_chain",
					"subaccount_id", adjustment.SubaccountID,
					"post_balance", adjustment.PostBalance.String(),
					"tx_hash", adjustment.TxHash,
					"block", adjustment.BlockNumber,
				)
			}
			slog.Info("perp_position_indexer_applied", "from", from, "to", to, "applied", applied, "skipped_venue_fills", skipped)
		}
		from = to + 1
	}
	return nil
}

func (p *positionIndexer) blockNumber(ctx context.Context) (uint64, error) {
	raw, err := p.rpc.rpcCall(ctx, "eth_blockNumber", []any{})
	if err != nil {
		return 0, err
	}
	var hex string
	if err := json.Unmarshal(raw, &hex); err != nil {
		return 0, err
	}
	return parseHexUint(hex)
}

// rawLog is the subset of an eth_getLogs entry the indexer reads.
type rawLog struct {
	Topics          []string `json:"topics"`
	Data            string   `json:"data"`
	TransactionHash string   `json:"transactionHash"`
	BlockNumber     string   `json:"blockNumber"`
	Removed         bool     `json:"removed"`
}

func (p *positionIndexer) logs(ctx context.Context, subAccounts string, from, to uint64) ([]rawLog, error) {
	raw, err := p.rpc.rpcCall(ctx, "eth_getLogs", []any{map[string]any{
		"address":   subAccounts,
		"fromBlock": fmt.Sprintf("0x%x", from),
		"toBlock":   fmt.Sprintf("0x%x", to),
		"topics":    []any{balanceAdjustedTopic, nil, nil, assetAndSubIDTopic(p.perp, 0)},
	}})
	if err != nil {
		return nil, err
	}
	var logs []rawLog
	if err := json.Unmarshal(raw, &logs); err != nil {
		return nil, fmt.Errorf("decode logs: %w", err)
	}
	return logs, nil
}

// assetAndSubIDTopic is SubAccounts' packing of the indexed asset: the address in the high 160 bits,
// the subId in the low 96 (bytes32(uint(uint160(asset)) << 96) | bytes32(subId)).
func assetAndSubIDTopic(asset string, subID uint64) string {
	return "0x" + strings.TrimPrefix(strings.ToLower(asset), "0x") + fmt.Sprintf("%024x", subID)
}

// decodeBalanceAdjustedLogs reads the account (topic 1) and the post-balance (third data word) of
// each event, in the order the node returned them, which is block then log order.
func decodeBalanceAdjustedLogs(logs []rawLog) ([]orders.ChainPositionAdjustment, error) {
	adjustments := make([]orders.ChainPositionAdjustment, 0, len(logs))
	for _, entry := range logs {
		if entry.Removed || len(entry.Topics) < 4 {
			continue
		}
		account, err := wordAt(entry.Topics[1], 0)
		if err != nil {
			return nil, fmt.Errorf("account topic: %w", err)
		}
		post, err := signedWordAt(entry.Data, 2)
		if err != nil {
			return nil, fmt.Errorf("post balance: %w", err)
		}
		block, err := parseHexUint(entry.BlockNumber)
		if err != nil {
			return nil, fmt.Errorf("block number: %w", err)
		}
		adjustments = append(adjustments, orders.ChainPositionAdjustment{
			SubaccountID: account.String(),
			PostBalance:  post,
			TxHash:       strings.ToLower(entry.TransactionHash),
			BlockNumber:  block,
		})
	}
	return adjustments, nil
}

func signedWordAt(raw string, index int) (*big.Int, error) {
	value, err := wordAt(raw, index)
	if err != nil {
		return nil, err
	}
	if value.Bit(255) == 1 {
		value.Sub(value, new(big.Int).Lsh(big.NewInt(1), 256))
	}
	return value, nil
}

func parseHexUint(hex string) (uint64, error) {
	value, ok := new(big.Int).SetString(strings.TrimPrefix(strings.ToLower(strings.TrimSpace(hex)), "0x"), 16)
	if !ok || !value.IsUint64() {
		return 0, fmt.Errorf("invalid hex quantity %q", hex)
	}
	return value.Uint64(), nil
}
