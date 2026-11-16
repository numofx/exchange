package matching

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/sha3"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func keccakHex(s string) string {
	h := sha3.NewLegacyKeccak256()
	h.Write([]byte(s))
	return fmt.Sprintf("0x%x", h.Sum(nil))
}

func TestBookTopicsMatchTheirSignatures(t *testing.T) {
	if got := keccakHex("Fill(uint256,uint256,uint256,bool,uint256,uint256,uint256)"); got != bookFillTopic {
		t.Fatalf("Fill topic %s, want %s", got, bookFillTopic)
	}
	if got := keccakHex("TakeExecuted(uint256,uint256,bool,uint256,uint256,uint256)"); got != bookTakeTopic {
		t.Fatalf("TakeExecuted topic %s, want %s", got, bookTakeTopic)
	}
	if got := keccakHex("markets(uint256)")[:10]; got != bookMarketsSelector {
		t.Fatalf("markets selector %s, want %s", got, bookMarketsSelector)
	}
}

func bookWord(v *big.Int) string { return fmt.Sprintf("%064x", v) }

func dec18(n int64, places int64) *big.Int {
	// n x 10^(18-places): dec18(116, 2) is 1.16e18
	return new(big.Int).Mul(big.NewInt(n), new(big.Int).Exp(big.NewInt(10), big.NewInt(18-places), nil))
}

func fillLog(tx string, block, index uint64, market, taker, maker int64, buy bool, amount, price, fee *big.Int) rawBookLog {
	b := big.NewInt(0)
	if buy {
		b = big.NewInt(1)
	}
	return rawBookLog{
		Topics: []string{bookFillTopic, "0x" + bookWord(big.NewInt(market)), "0x" + bookWord(big.NewInt(taker)),
			"0x" + bookWord(big.NewInt(maker))},
		Data:            "0x" + bookWord(b) + bookWord(amount) + bookWord(price) + bookWord(fee),
		TransactionHash: tx, BlockNumber: fmt.Sprintf("0x%x", block), LogIndex: fmt.Sprintf("0x%x", index),
	}
}

func takeLog(tx string, block, index uint64, market, taker int64, buy bool, filled, avg, fee *big.Int) rawBookLog {
	b := big.NewInt(0)
	if buy {
		b = big.NewInt(1)
	}
	return rawBookLog{
		Topics:          []string{bookTakeTopic, "0x" + bookWord(big.NewInt(market)), "0x" + bookWord(big.NewInt(taker))},
		Data:            "0x" + bookWord(b) + bookWord(filled) + bookWord(avg) + bookWord(fee),
		TransactionHash: tx, BlockNumber: fmt.Sprintf("0x%x", block), LogIndex: fmt.Sprintf("0x%x", index),
	}
}

// One take of 0.15 contracts against two makers: 0.1 at 1.16 and 0.05 at 1.1601, 5 bps, then the take's summary.
func twoMakerTake(tx string, block uint64) []rawBookLog {
	fee1 := dec18(58, 3)     // 0.1 x 1000 x 1.16 x 5 bps = 0.058
	fee2 := dec18(290025, 7) // 0.05 x 1000 x 1.1601 x 5 bps
	return []rawBookLog{
		fillLog(tx, block, 3, 1, 57, 56, true, dec18(1, 1), dec18(116, 2), fee1),
		fillLog(tx, block, 5, 1, 57, 58, true, dec18(5, 2), dec18(11601, 4), fee2),
		takeLog(tx, block, 6, 1, 57, true, dec18(15, 2), dec18(1160033, 6), new(big.Int).Add(fee1, fee2)),
	}
}

func TestDecodeBookLogsChecksEachTakeAgainstItsFills(t *testing.T) {
	logs := twoMakerTake("0xAA", 100)
	// Out of order, and a reorged entry: sorted, and the removed one skipped.
	removed := fillLog("0xbb", 99, 0, 1, 9, 9, false, dec18(1, 0), dec18(1, 0), big.NewInt(0))
	removed.Removed = true
	got, err := decodeBookLogs([]rawBookLog{logs[2], logs[0], removed, logs[1]})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 3 || got[0].logIndex != 3 || got[1].logIndex != 5 || !got[2].isTake {
		t.Fatalf("decoded %+v", got)
	}
	if got[0].maker.Int64() != 56 || got[0].taker.Int64() != 57 || !got[0].isBuy || got[0].txHash != "0xaa" {
		t.Fatalf("first fill %+v", got[0])
	}

	// A take with no fills (minFill 0, nothing in band) is a take, not an error.
	if _, err := decodeBookLogs([]rawBookLog{takeLog("0xcc", 1, 0, 1, 57, false, big.NewInt(0), big.NewInt(0), big.NewInt(0))}); err != nil {
		t.Fatalf("an empty take: %v", err)
	}

	for name, broken := range map[string][]rawBookLog{
		"fills short of the take": {logs[0], logs[2]},
		"a fill with no take":     {logs[0], logs[1]},
		"fills on the other side": {fillLog("0xaa", 100, 3, 1, 57, 56, false, dec18(15, 2), dec18(116, 2), big.NewInt(0)), logs[2]},
		"fills of another taker":  {fillLog("0xaa", 100, 3, 1, 99, 56, true, dec18(15, 2), dec18(116, 2), big.NewInt(0)), logs[2]},
		"fills charging more":     {fillLog("0xaa", 100, 3, 1, 57, 56, true, dec18(15, 2), dec18(116, 2), dec18(1, 0)), logs[2]},
		"a fill after its take":   {logs[2], fillLog("0xaa", 100, 7, 1, 57, 56, true, dec18(15, 2), dec18(116, 2), big.NewInt(0))},
		"isBuy not a bool": {func() rawBookLog {
			l := logs[0]
			l.Data = "0x" + bookWord(big.NewInt(2)) + l.Data[2+64:]
			return l
		}(), logs[1], logs[2]},
		"short data": {func() rawBookLog { l := logs[0]; l.Data = l.Data[:2+3*64]; return l }(), logs[1], logs[2]},
	} {
		if _, err := decodeBookLogs(broken); err == nil {
			t.Errorf("%s: decoded without an error", name)
		}
	}
}

func TestBookUnitsAreExact(t *testing.T) {
	eurc := instruments.Metadata{Symbol: "EURC-30NOV26", AmountScale: "1000000000000000"} // 1 EURC of a 1,000 EURC contract
	for _, c := range []struct {
		amount *big.Int
		want   string
	}{
		{dec18(15, 2), "150"},                    // 0.15 contract
		{big.NewInt(1_000_000_000_000_000), "1"}, // one lot
		{big.NewInt(1_500_000_000_000), "0.0015"},
	} {
		got, err := bookSize(c.amount, eurc)
		if err != nil || got != c.want {
			t.Fatalf("bookSize(%s) = %q %v, want %s", c.amount, got, err, c.want)
		}
	}
	if _, err := bookSize(big.NewInt(1), instruments.Metadata{Symbol: "x"}); err == nil {
		t.Fatal("a series with no amount scale must be refused")
	}
	if got := weiToDecimal(dec18(1160033, 6)); got != "1.160033" {
		t.Fatalf("price %s", got)
	}
	if got := weiToDecimal(big.NewInt(0)); got != "0" {
		t.Fatalf("zero %s", got)
	}
	if got := weiToDecimal(big.NewInt(1)); got != "0.000000000000000001" {
		t.Fatalf("one wei %s", got)
	}
}

// bookChain is the chain as the indexer reads it: a head, the book's logs, markets(id) and block times.
type bookChain struct {
	mu      sync.Mutex
	head    uint64
	logs    []rawBookLog
	markets map[int64][2]string // id -> future, subId (decimal)
	calls   map[string]int
}

func (c *bookChain) serve(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req struct {
			Method string            `json:"method"`
			Params []json.RawMessage `json:"params"`
		}
		_ = json.Unmarshal(body, &req)
		c.mu.Lock()
		defer c.mu.Unlock()
		c.calls[req.Method]++
		reply := func(v any) {
			_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": 1, "result": v})
		}
		switch req.Method {
		case "eth_blockNumber":
			reply(fmt.Sprintf("0x%x", c.head))
		case "eth_getBlockByNumber":
			var n string
			_ = json.Unmarshal(req.Params[0], &n)
			block, _ := parseHexUint(n)
			reply(map[string]string{"timestamp": fmt.Sprintf("0x%x", 1_800_000_000+block)})
		case "eth_getLogs":
			var filter struct {
				FromBlock string `json:"fromBlock"`
				ToBlock   string `json:"toBlock"`
			}
			_ = json.Unmarshal(req.Params[0], &filter)
			from, _ := parseHexUint(filter.FromBlock)
			to, _ := parseHexUint(filter.ToBlock)
			out := []rawBookLog{}
			for _, l := range c.logs {
				n, _ := parseHexUint(l.BlockNumber)
				if n >= from && n <= to {
					out = append(out, l)
				}
			}
			reply(out)
		case "eth_call":
			var call struct {
				Data string `json:"data"`
			}
			_ = json.Unmarshal(req.Params[0], &call)
			id, _ := new(big.Int).SetString(call.Data[10:], 16)
			m, ok := c.markets[id.Int64()]
			if !ok {
				reply("0x" + strings.Repeat("0", 13*64))
				return
			}
			future, _ := new(big.Int).SetString(strings.TrimPrefix(m[0], "0x"), 16)
			sub, _ := new(big.Int).SetString(m[1], 10)
			words := bookWord(future) + bookWord(big.NewInt(0xe9)) + bookWord(sub) + strings.Repeat("0", 10*64)
			reply("0x" + words)
		default:
			http.Error(w, "unexpected "+req.Method, http.StatusBadRequest)
		}
	}))
}

// The wiring, against the test database: a take on the book lands on its series' tape (/trades' reader, the 24h
// stats, the public stream), its take in book_takes, at the block's time; re-reading the range writes nothing twice;
// a range whose fills do not add up, or a market on a series the venue does not list, is not written and holds the
// cursor where it was.
func TestBookIndexerPutsTheBooksFillsOnTheSeriesTape(t *testing.T) {
	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()
	repo := orders.NewRepository(pool)

	// A series and a book of their own per run.
	nonce := time.Now().UnixNano()
	asset := fmt.Sprintf("0x%040x", nonce)
	book := fmt.Sprintf("0x%040x", nonce+1)
	const expiry = 1796050800
	tx1 := fmt.Sprintf("0x%064x", nonce)
	tx2 := fmt.Sprintf("0x%064x", nonce+2)
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where asset_address = $1", asset)
		_, _ = pool.Exec(ctx, "delete from book_takes where book_address = $1", book)
		_, _ = pool.Exec(ctx, "delete from book_index_cursor where book_address = $1", book)
		_, _ = pool.Exec(ctx, "delete from market_events where market_key = $1", asset+":"+fmt.Sprint(expiry))
	})

	chain := &bookChain{head: 1_000, markets: map[int64][2]string{1: {asset, fmt.Sprint(expiry)}}, calls: map[string]int{}}
	chain.logs = twoMakerTake(tx1, 500)
	rpc := chain.serve(t)
	defer rpc.Close()

	fee := 5
	cfg := config.Config{
		ChainRPCURL: rpc.URL,
		FutureSeries: []config.FutureSeries{{AssetAddress: asset, Expiry: expiry, ManagerAddress: "0x00000000000000000000000000000000000000e9",
			Kind: config.FutureKindLinear, BaseAsset: "EURC", ContractSize: "1000", TakerFeeBps: &fee}},
	}
	cfg.OnchainBookAddress, cfg.OnchainBookStartBlock = book, 400
	b := newBookIndexer(cfg, repo, instruments.DefaultRegistry(cfg))
	if b == nil {
		t.Fatal("a configured book must be indexed")
	}

	if err := b.tick(ctx); err != nil {
		t.Fatal(err)
	}
	if cursor, _, _ := repo.BookIndexCursor(ctx, book); cursor != 1_000-bookIndexerConfirmations {
		t.Fatalf("cursor %d", cursor)
	}
	trades, err := repo.ListTrades(ctx, asset, fmt.Sprint(expiry), 0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(trades) != 2 {
		t.Fatalf("%d trades on the tape, want the take's 2 fills", len(trades))
	}
	// Newest first; both at block 500's time, the later log first.
	second, first := trades[0], trades[1]
	if first.Price != "1.16" || first.Size != "100" || second.Price != "1.1601" || second.Size != "50" {
		t.Fatalf("fills %+v %+v", first, second)
	}
	if first.Source != orders.SourceBook || first.AggressorSide != orders.SideBuy || first.TakerOrderID != "" ||
		first.TxHash == nil || *first.TxHash != tx1 || !first.CreatedAt.Equal(time.Unix(1_800_000_500, 0)) {
		t.Fatalf("first fill %+v", first)
	}
	var takerAcc, makerAcc, takerFee string
	if err := pool.QueryRow(ctx, `select taker_subaccount_id::text, maker_subaccount_id::text, taker_fee from trade_fills
where trade_id = $1`, first.TradeID).Scan(&takerAcc, &makerAcc, &takerFee); err != nil {
		t.Fatal(err)
	}
	if takerAcc != "57" || makerAcc != "56" || takerFee != "0.058" {
		t.Fatalf("accounts %s/%s fee %s", takerAcc, makerAcc, takerFee)
	}
	var filled, avg, takeFee string
	var count int
	if err := pool.QueryRow(ctx, `select filled, avg_price, fee, fill_count from book_takes where book_address = $1`, book).
		Scan(&filled, &avg, &takeFee, &count); err != nil {
		t.Fatal(err)
	}
	if filled != "150" || avg != "1.160033" || takeFee != "0.0870025" || count != 2 {
		t.Fatalf("take %s @ %s fee %s, %d fills", filled, avg, takeFee, count)
	}
	var streamed int
	if err := pool.QueryRow(ctx, `select count(*) from market_events where market_key = $1 and channel = 'trades'
and payload->>'source' = 'book'`, asset+":"+fmt.Sprint(expiry)).Scan(&streamed); err != nil {
		t.Fatal(err)
	}
	if streamed != 2 {
		t.Fatalf("%d book fills on the public stream, want 2", streamed)
	}

	// Re-reading the same range (a crash before the cursor moved) writes nothing twice.
	if err := repo.SetBookIndexCursor(ctx, book, 399); err != nil {
		t.Fatal(err)
	}
	if err := b.tick(ctx); err != nil {
		t.Fatal(err)
	}
	if again, _ := repo.ListTrades(ctx, asset, fmt.Sprint(expiry), 0, 10); len(again) != 2 {
		t.Fatalf("a re-read range wrote %d fills, want the same 2", len(again))
	}

	// A take whose fills do not add up: nothing in the range is written and the cursor holds.
	short := twoMakerTake(tx2, 1_100)[1:]
	chain.mu.Lock()
	chain.logs = append(chain.logs, short...)
	chain.head = 1_200
	chain.mu.Unlock()
	if err := b.tick(ctx); err == nil || !strings.Contains(err.Error(), "sum to") {
		t.Fatalf("fills short of their take must stop the indexer, got %v", err)
	}
	if cursor, _, _ := repo.BookIndexCursor(ctx, book); cursor != 1_000-bookIndexerConfirmations {
		t.Fatalf("the cursor moved past a range it refused: %d", cursor)
	}
	if again, _ := repo.ListTrades(ctx, asset, fmt.Sprint(expiry), 0, 10); len(again) != 2 {
		t.Fatalf("a refused range wrote fills: %d", len(again))
	}

	// A market on a series the venue does not list: refused, with the reason.
	chain.mu.Lock()
	chain.logs = append(twoMakerTake(tx1, 500), func() []rawBookLog {
		l := twoMakerTake(tx2, 1_100)
		for i := range l {
			l[i].Topics[1] = "0x" + bookWord(big.NewInt(2))
		}
		return l
	}()...)
	chain.markets[2] = [2]string{fmt.Sprintf("0x%040x", nonce+3), fmt.Sprint(expiry)}
	chain.mu.Unlock()
	if err := b.tick(ctx); err == nil || !strings.Contains(err.Error(), "does not list") {
		t.Fatalf("an unlisted series must stop the indexer, got %v", err)
	}
	if cursor, _, _ := repo.BookIndexCursor(ctx, book); cursor != 1_000-bookIndexerConfirmations {
		t.Fatalf("the cursor moved past an unlisted market: %d", cursor)
	}
}

// A book fill is not one of the matcher's: the perp ledger's "the venue already moved this" skip must not take a
// book transaction for one.
func TestAChainAdjustmentInABookTransactionIsNotSkippedAsAVenueFill(t *testing.T) {
	databaseURL := os.Getenv("MARKETS_SERVICE_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("MARKETS_SERVICE_TEST_DATABASE_URL is not set")
	}
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	ctx := context.Background()
	repo := orders.NewRepository(pool)
	nonce := time.Now().UnixNano()
	asset := fmt.Sprintf("0x%040x", nonce)
	book := fmt.Sprintf("0x%040x", nonce+1)
	tx := fmt.Sprintf("0x%064x", nonce)
	t.Cleanup(func() {
		_, _ = pool.Exec(ctx, "delete from trade_fills where asset_address = $1", asset)
		_, _ = pool.Exec(ctx, "delete from perp_positions where asset_address = $1", asset)
		_, _ = pool.Exec(ctx, "delete from perp_position_cursor where asset_address = $1", asset)
		_, _ = pool.Exec(ctx, "delete from book_index_cursor where book_address = $1", book)
	})
	if _, _, err := repo.ApplyBookEvents(ctx, book, []orders.BookFill{{TxHash: tx, LogIndex: 1, BlockNumber: 5,
		BlockTime: time.Now(), AssetAddress: asset, SubID: "0", TakerSubaccountID: "7", MakerSubaccountID: "8",
		Side: orders.SideBuy, Price: "1", Size: "1", TakerFee: "0"}}, nil, 5); err != nil {
		t.Fatal(err)
	}
	applied, skipped, err := repo.ApplyChainAdjustments(ctx, asset, []orders.ChainPositionAdjustment{
		{SubaccountID: "7", PostBalance: big.NewInt(1000), TxHash: tx, BlockNumber: 5}}, 5)
	if err != nil {
		t.Fatal(err)
	}
	if applied != 1 || skipped != 0 {
		t.Fatalf("applied %d skipped %d: a book transaction was taken for a venue fill", applied, skipped)
	}
}

// Golden: the logs the contract itself emits, recorded (vm.recordLogs) from risk-core's OnchainBook unit fixture on
// 2026-11-16: testWalksBestPriceFirstAcrossMakers' take of 1,500 lots against two makers, settled in maker order.
// The fixtures above are encoded by hand; this pins the decoder to the contract's actual layout.
func TestDecodeBookLogsReadsTheContractsOwnLogs(t *testing.T) {
	topic := func(n int) string { return fmt.Sprintf("0x%064x", n) }
	logs := []rawBookLog{
		{Topics: []string{bookFillTopic, topic(1), topic(5), topic(3)}, BlockNumber: "0x1", LogIndex: "0xf", TransactionHash: "0x01",
			Data: "0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000006f05b59d3b200000000000000000000000000000000000000000000000000000f44571f1568400000000000000000000000000000000000000000000000000003d115c7c55a1000"},
		{Topics: []string{bookFillTopic, topic(1), topic(5), topic(4)}, BlockNumber: "0x1", LogIndex: "0x1f", TransactionHash: "0x01",
			Data: "0x00000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000000000000000000000000000000f444e06c6f5a00000000000000000000000000000000000000000000000000007a22703637ad000"},
		{Topics: []string{bookTakeTopic, topic(1), topic(5)}, BlockNumber: "0x1", LogIndex: "0x20", TransactionHash: "0x01",
			Data: "0x000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000014d1120d7b1600000000000000000000000000000000000000000000000000000f44510ee11bd5550000000000000000000000000000000000000000000000000b733ccb28d4e000"},
	}
	got, err := decodeBookLogs(logs)
	if err != nil {
		t.Fatal(err)
	}
	eurc := instruments.Metadata{AmountScale: "1000000000000000"}
	want := []struct{ maker, size, price, fee string }{
		{"3", "500", "1.1001", "0.275025"},
		{"4", "1000", "1.10009", "0.550045"},
		{"", "1500", "1.100093333333333333", "0.82507"},
	}
	for i, w := range want {
		size, _ := bookSize(got[i].amount, eurc)
		maker := ""
		if got[i].maker != nil {
			maker = got[i].maker.String()
		}
		if got[i].marketID.Int64() != 1 || got[i].taker.Int64() != 5 || !got[i].isBuy || maker != w.maker || size != w.size ||
			weiToDecimal(got[i].price) != w.price || weiToDecimal(got[i].fee) != w.fee || got[i].isTake != (i == 2) {
			t.Fatalf("log %d: %+v (size %s)", i, got[i], size)
		}
	}
}
