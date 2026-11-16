package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

// The OnchainBook's events (risk-core src/periphery/OnchainBook.sol). TestBookTopicsMatchTheirSignatures pins both.
const (
	// Fill(uint256 indexed marketId, uint256 indexed takerAccountId, uint256 indexed makerAccountId, bool isBuy,
	// uint256 amount, uint256 price, uint256 fee)
	bookFillTopic = "0x8fc4d8f9db92eeeee5422077188e98e26b904620540784ef16dbe279d0b5ef94"
	// TakeExecuted(uint256 indexed marketId, uint256 indexed takerAccountId, bool isBuy, uint256 filled,
	// uint256 avgPrice, uint256 fee)
	bookTakeTopic = "0xf32b723fce7697fe2cd9b5c43451ac97e39dafb0614d2574ad9a3c2c62ea7f01"

	bookMarketsSelector = "0xb1283e77" // OnchainBook.markets(uint256)
	// The words of markets(id) the indexer reads: the future, and the series' subId. A market never changes either.
	bookMarketFutureWord = 0
	bookMarketSubIDWord  = 2
)

const (
	bookIndexerInterval = 5 * time.Second
	// About 4 s of Base blocks: a fill is on the tape once, so it is read only after the head has moved past it.
	bookIndexerConfirmations = 20
	bookIndexerChunk         = 2000
)

// bookIndexer puts the OnchainBook's fills on the tape of the series they trade (trade_fills, source 'book'), so
// /trades, candles, the 24h stats and the public stream count the book's volume with the matcher's. Each Fill is
// one row, at its block's time; each TakeExecuted is a book_takes row. The fills of a take must add up to its
// filled amount: a range where they do not is not written and the cursor does not move, so a decoding fault stops
// the tape (and shows on the matcher's /healthz as book_indexer.last_error) instead of writing wrong volume.
//
// It fails closed the same way on a market whose series the venue does not list: those fills would have no tape.
// Runs inside the matcher, one instance.
type bookIndexer struct {
	rpc           *chainFundingChecker
	orders        *orders.Repository
	registry      *instruments.Registry
	book          string
	startBlock    uint64
	interval      time.Duration
	confirmations uint64
	chunk         uint64

	marketsMu sync.Mutex
	markets   map[string]instruments.Metadata

	indexerTracker
}

func newBookIndexer(cfg config.Config, repo *orders.Repository, registry *instruments.Registry) *bookIndexer {
	if !cfg.OnchainBookEnabled() {
		return nil
	}
	if strings.TrimSpace(cfg.ChainRPCURL) == "" {
		slog.Warn("book_indexer_inert", "reason", "CHAIN_RPC_URL is unset", "book", cfg.OnchainBookAddress,
			"effect", "the OnchainBook's fills are not on the tape")
		return nil
	}
	return &bookIndexer{
		rpc:           &chainFundingChecker{rpcURL: strings.TrimSpace(cfg.ChainRPCURL), httpClient: &http.Client{Timeout: 10 * time.Second}},
		orders:        repo,
		registry:      registry,
		book:          cfg.OnchainBookAddress,
		startBlock:    cfg.OnchainBookStartBlock,
		interval:      bookIndexerInterval,
		confirmations: bookIndexerConfirmations,
		chunk:         bookIndexerChunk,
		markets:       map[string]instruments.Metadata{},
	}
}

func (b *bookIndexer) run(ctx context.Context) {
	ticker := time.NewTicker(b.interval)
	defer ticker.Stop()
	slog.Info("book_indexer_started", "book", b.book, "start_block", b.startBlock, "confirmations", b.confirmations)
	for {
		err := b.tick(ctx)
		if err != nil && ctx.Err() == nil {
			slog.Error("book_indexer_tick_failed", "book", b.book, "error", err)
		}
		b.note(func(s *indexerStatus) {
			if err != nil {
				s.LastError = err.Error()
			} else {
				s.LastError = ""
			}
		})
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (b *bookIndexer) tick(ctx context.Context) error {
	head, err := b.blockNumber(ctx)
	if err != nil {
		return fmt.Errorf("read head: %w", err)
	}
	if head < b.confirmations {
		return nil
	}
	through := head - b.confirmations
	cursor, ok, err := b.orders.BookIndexCursor(ctx, b.book)
	if err != nil {
		return err
	}
	if !ok {
		// First run: from the block before the deploy, so the first range read includes it.
		cursor = b.startBlock - 1
		if err := b.orders.SetBookIndexCursor(ctx, b.book, cursor); err != nil {
			return err
		}
		slog.Info("book_indexer_cursor_started", "book", b.book, "block", cursor)
	}
	b.note(func(s *indexerStatus) { s.HeadBlock = head; s.CursorBlock = cursor })
	if through <= cursor {
		b.note(func(s *indexerStatus) { s.LastAppliedAt = time.Now() })
		return nil
	}
	for from := cursor + 1; from <= through; {
		to := from + b.chunk - 1
		if to > through {
			to = through
		}
		logs, err := b.logs(ctx, from, to)
		if err != nil {
			return fmt.Errorf("read logs %d..%d: %w", from, to, err)
		}
		fills, takes, err := b.decode(ctx, logs)
		if err != nil {
			return fmt.Errorf("blocks %d..%d: %w", from, to, err)
		}
		newFills, newTakes, err := b.orders.ApplyBookEvents(ctx, b.book, fills, takes, to)
		if err != nil {
			return fmt.Errorf("apply %d..%d: %w", from, to, err)
		}
		b.note(func(s *indexerStatus) { s.CursorBlock = to; s.LastAppliedAt = time.Now() })
		if len(takes) > 0 {
			slog.Info("book_indexer_applied", "from", from, "to", to, "fills", len(fills), "takes", len(takes),
				"new_fills", newFills, "new_takes", newTakes)
		}
		from = to + 1
	}
	return nil
}

// bookLog is a decoded book event, before its market and block time are resolved.
type bookLog struct {
	isTake      bool
	txHash      string
	logIndex    uint64
	blockNumber uint64
	marketID    *big.Int
	taker       *big.Int
	maker       *big.Int // Fill only
	isBuy       bool
	amount      *big.Int // Fill: amount; TakeExecuted: filled
	price       *big.Int // Fill: price; TakeExecuted: avgPrice
	fee         *big.Int
}

// decodeBookLogs reads Fill and TakeExecuted in block then log order, skipping removed (reorged) entries, and checks
// each take against its fills: the Fills of one take come before its TakeExecuted in the same transaction, with the
// same market, taker and side, and their amounts sum to its filled. A fill with no take after it, a take whose fills
// do not add up, or fills charging more than the take's fee is an error.
func decodeBookLogs(logs []rawBookLog) ([]bookLog, error) {
	out := make([]bookLog, 0, len(logs))
	for _, entry := range logs {
		if entry.Removed || len(entry.Topics) == 0 {
			continue
		}
		var l bookLog
		switch strings.ToLower(entry.Topics[0]) {
		case bookFillTopic:
			l.isTake = false
			if len(entry.Topics) != 4 {
				return nil, fmt.Errorf("Fill in %s has %d topics", entry.TransactionHash, len(entry.Topics))
			}
		case bookTakeTopic:
			l.isTake = true
			if len(entry.Topics) != 3 {
				return nil, fmt.Errorf("TakeExecuted in %s has %d topics", entry.TransactionHash, len(entry.Topics))
			}
		default:
			continue
		}
		var err error
		if l.blockNumber, err = parseHexUint(entry.BlockNumber); err != nil {
			return nil, fmt.Errorf("block number: %w", err)
		}
		if l.logIndex, err = parseHexUint(entry.LogIndex); err != nil {
			return nil, fmt.Errorf("log index: %w", err)
		}
		l.txHash = strings.ToLower(entry.TransactionHash)
		if l.marketID, err = wordAt(entry.Topics[1], 0); err != nil {
			return nil, err
		}
		if l.taker, err = wordAt(entry.Topics[2], 0); err != nil {
			return nil, err
		}
		if !l.isTake {
			if l.maker, err = wordAt(entry.Topics[3], 0); err != nil {
				return nil, err
			}
		}
		if len(strings.TrimPrefix(entry.Data, "0x")) != 4*64 {
			return nil, fmt.Errorf("event in %s log %d: data is not 4 words", l.txHash, l.logIndex)
		}
		buy, _ := wordAt(entry.Data, 0)
		switch buy.Int64() {
		case 0:
		case 1:
			l.isBuy = true
		default:
			return nil, fmt.Errorf("event in %s log %d: isBuy is not a bool", l.txHash, l.logIndex)
		}
		l.amount, _ = wordAt(entry.Data, 1)
		l.price, _ = wordAt(entry.Data, 2)
		l.fee, _ = wordAt(entry.Data, 3)
		out = append(out, l)
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].blockNumber != out[j].blockNumber {
			return out[i].blockNumber < out[j].blockNumber
		}
		return out[i].logIndex < out[j].logIndex
	})

	type key struct {
		tx     string
		market string
		taker  string
		isBuy  bool
	}
	type pending struct {
		amount, fee *big.Int
		count       int
	}
	open := map[key]*pending{}
	for _, l := range out {
		k := key{l.txHash, l.marketID.String(), l.taker.String(), l.isBuy}
		if !l.isTake {
			p := open[k]
			if p == nil {
				p = &pending{amount: new(big.Int), fee: new(big.Int)}
				open[k] = p
			}
			p.amount.Add(p.amount, l.amount)
			p.fee.Add(p.fee, l.fee)
			p.count++
			continue
		}
		p := open[k]
		delete(open, k)
		if p == nil {
			p = &pending{amount: new(big.Int), fee: new(big.Int)}
		}
		if p.amount.Cmp(l.amount) != 0 {
			return nil, fmt.Errorf("take in %s log %d (market %s, taker %s) filled %s, its %d fills sum to %s",
				l.txHash, l.logIndex, k.market, k.taker, l.amount, p.count, p.amount)
		}
		if p.fee.Cmp(l.fee) > 0 {
			return nil, fmt.Errorf("take in %s log %d charged %s, its fills charge %s", l.txHash, l.logIndex, l.fee, p.fee)
		}
	}
	for k, p := range open {
		return nil, fmt.Errorf("%d fills in %s (market %s, taker %s) with no TakeExecuted after them", p.count, k.tx, k.market, k.taker)
	}
	return out, nil
}

// decode turns a range's logs into the rows to write: each event resolved to its series and converted to the venue's
// units (price quote per base, size in the series' order units, the fee in the quote asset), at its block's time.
func (b *bookIndexer) decode(ctx context.Context, raw []rawBookLog) ([]orders.BookFill, []orders.BookTake, error) {
	logs, err := decodeBookLogs(raw)
	if err != nil {
		return nil, nil, err
	}
	fillCounts := map[string]int{}
	for _, l := range logs {
		if !l.isTake {
			fillCounts[fmt.Sprintf("%s|%s|%s|%t", l.txHash, l.marketID, l.taker, l.isBuy)]++
		}
	}
	times := map[uint64]time.Time{}
	var fills []orders.BookFill
	var takes []orders.BookTake
	for _, l := range logs {
		instrument, err := b.market(ctx, l.marketID)
		if err != nil {
			return nil, nil, err
		}
		at, ok := times[l.blockNumber]
		if !ok {
			if at, err = b.blockTime(ctx, l.blockNumber); err != nil {
				return nil, nil, fmt.Errorf("block %d time: %w", l.blockNumber, err)
			}
			times[l.blockNumber] = at
		}
		side := orders.SideSell
		if l.isBuy {
			side = orders.SideBuy
		}
		size, err := bookSize(l.amount, instrument)
		if err != nil {
			return nil, nil, fmt.Errorf("%s log %d: %w", l.txHash, l.logIndex, err)
		}
		if !l.isTake {
			fills = append(fills, orders.BookFill{
				TxHash: l.txHash, LogIndex: l.logIndex, BlockNumber: l.blockNumber, BlockTime: at,
				AssetAddress: instrument.AssetAddress, SubID: instrument.SubID,
				TakerSubaccountID: l.taker.String(), MakerSubaccountID: l.maker.String(),
				Side: side, Price: weiToDecimal(l.price), Size: size, TakerFee: weiToDecimal(l.fee),
			})
			continue
		}
		avg := ""
		if l.amount.Sign() > 0 {
			avg = weiToDecimal(l.price)
		}
		takes = append(takes, orders.BookTake{
			TxHash: l.txHash, LogIndex: l.logIndex, BlockNumber: l.blockNumber, BlockTime: at,
			BookAddress: b.book, MarketID: l.marketID.String(),
			AssetAddress: instrument.AssetAddress, SubID: instrument.SubID,
			TakerSubaccountID: l.taker.String(), Side: side, Filled: size, AvgPrice: avg, Fee: weiToDecimal(l.fee),
			FillCount: fillCounts[fmt.Sprintf("%s|%s|%s|%t", l.txHash, l.marketID, l.taker, l.isBuy)],
		})
	}
	return fills, takes, nil
}

// market is the listed series a book market trades, read once: a market's future and subId never change.
func (b *bookIndexer) market(ctx context.Context, id *big.Int) (instruments.Metadata, error) {
	b.marketsMu.Lock()
	cached, ok := b.markets[id.String()]
	b.marketsMu.Unlock()
	if ok {
		return cached, nil
	}
	ret, err := b.rpc.ethCall(ctx, b.book, bookMarketsSelector+fmt.Sprintf("%064x", id))
	if err != nil {
		return instruments.Metadata{}, fmt.Errorf("book markets(%s): %w", id, err)
	}
	future, err := wordAt(ret, bookMarketFutureWord)
	if err != nil {
		return instruments.Metadata{}, fmt.Errorf("book markets(%s): %w", id, err)
	}
	subID, err := wordAt(ret, bookMarketSubIDWord)
	if err != nil {
		return instruments.Metadata{}, fmt.Errorf("book markets(%s): %w", id, err)
	}
	if future.Sign() == 0 {
		return instruments.Metadata{}, fmt.Errorf("book market %s does not exist", id)
	}
	asset := fmt.Sprintf("0x%040x", future)
	instrument, ok := b.registry.ByAssetAndSubID(asset, subID.String())
	if !ok || !instrument.IsFuture() {
		return instruments.Metadata{}, fmt.Errorf("book market %s trades %s:%s, a series the venue does not list: its fills have no tape (list it in FUTURE_SERIES)", id, asset, subID)
	}
	if _, ok := instrument.FixedAmountScale(); !ok {
		return instruments.Metadata{}, fmt.Errorf("book market %s: series %s has no amount scale", id, instrument.Symbol)
	}
	b.marketsMu.Lock()
	b.markets[id.String()] = instrument
	b.marketsMu.Unlock()
	return instrument, nil
}

// bookSize is a chain amount (1e18 a contract) in the series' order units: amount / amount_scale, exact.
func bookSize(amount *big.Int, instrument instruments.Metadata) (string, error) {
	scale, ok := instrument.FixedAmountScale()
	if !ok {
		return "", fmt.Errorf("series %s has no amount scale", instrument.Symbol)
	}
	return ratToDecimal(new(big.Rat).SetFrac(amount, scale))
}

// weiToDecimal is an 18-dp chain value as an exact decimal: 1160000000000000000 is "1.16".
func weiToDecimal(wei *big.Int) string {
	s, _ := ratToDecimal(new(big.Rat).SetFrac(wei, bookWad))
	return s
}

// ratToDecimal writes a non-negative rational with a terminating decimal exactly, trailing zeros trimmed.
func ratToDecimal(r *big.Rat) (string, error) {
	if r.Sign() < 0 {
		return "", fmt.Errorf("negative amount %s", r)
	}
	for places := 0; places <= 36; places++ {
		scaled := new(big.Rat).Mul(r, new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(places)), nil)))
		if scaled.IsInt() {
			return r.FloatString(places), nil
		}
	}
	return "", fmt.Errorf("%s has no exact decimal", r)
}

func (b *bookIndexer) blockNumber(ctx context.Context) (uint64, error) {
	raw, err := b.rpc.rpcCall(ctx, "eth_blockNumber", []any{})
	if err != nil {
		return 0, err
	}
	var hex string
	if err := json.Unmarshal(raw, &hex); err != nil {
		return 0, err
	}
	return parseHexUint(hex)
}

func (b *bookIndexer) blockTime(ctx context.Context, number uint64) (time.Time, error) {
	raw, err := b.rpc.rpcCall(ctx, "eth_getBlockByNumber", []any{fmt.Sprintf("0x%x", number), false})
	if err != nil {
		return time.Time{}, err
	}
	var block struct {
		Timestamp string `json:"timestamp"`
	}
	if err := json.Unmarshal(raw, &block); err != nil {
		return time.Time{}, err
	}
	ts, err := parseHexUint(block.Timestamp)
	if err != nil {
		return time.Time{}, err
	}
	return time.Unix(int64(ts), 0).UTC(), nil
}

// rawBookLog is the subset of an eth_getLogs entry the book indexer reads.
type rawBookLog struct {
	Topics          []string `json:"topics"`
	Data            string   `json:"data"`
	TransactionHash string   `json:"transactionHash"`
	BlockNumber     string   `json:"blockNumber"`
	LogIndex        string   `json:"logIndex"`
	Removed         bool     `json:"removed"`
}

func (b *bookIndexer) logs(ctx context.Context, from, to uint64) ([]rawBookLog, error) {
	raw, err := b.rpc.rpcCall(ctx, "eth_getLogs", []any{map[string]any{
		"address":   b.book,
		"fromBlock": fmt.Sprintf("0x%x", from),
		"toBlock":   fmt.Sprintf("0x%x", to),
		"topics":    []any{[]string{bookFillTopic, bookTakeTopic}},
	}})
	if err != nil {
		return nil, err
	}
	var logs []rawBookLog
	if err := json.Unmarshal(raw, &logs); err != nil {
		return nil, fmt.Errorf("decode logs: %w", err)
	}
	return logs, nil
}

var bookWad = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
