package api

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

const (
	// quote((uint256,uint256,bool,uint256,uint256,uint256,uint256,uint64,uint16,uint8,bytes)) and markets(uint256),
	// from `cast sig`; book_depth_test.go pins the encoding against `cast calldata`.
	selectorBookQuote   = "24bea503"
	selectorBookMarkets = "b1283e77"
	bookDepthCacheTTL   = 5 * time.Second
	bookDepthMarketID   = 1
	// One lot (0.001 contract): the best price each side.
	bookDepthLot = 1_000_000_000_000_000
)

// bookDepthLadder is what /book-depth quotes each side, in contracts: a trader sees the average price for each size.
var bookDepthLadder = []string{"0.001", "0.1", "0.25", "0.5", "1", "2", "5", "10"}

type bookDepthLevel struct {
	Contracts string `json:"contracts"`
	// Filled is how much of Contracts the book fills now, in contracts; less than Contracts when the curve runs out.
	Filled   string `json:"filled"`
	AvgPrice string `json:"avg_price,omitempty"`
	Fee      string `json:"fee,omitempty"`
}

type bookDepthResponse struct {
	Market   string           `json:"market"`
	Book     string           `json:"book"`
	MarketID int              `json:"market_id"`
	Bids     []bookDepthLevel `json:"bids"`
	Asks     []bookDepthLevel `json:"asks"`
	ReadAt   int64            `json:"read_at"`
}

// bookChain is the one chain read /book-depth makes: eth_call at latest.
type bookChain interface {
	ethCall(ctx context.Context, contractAddress string, data string) (string, error)
}

type bookDepthService struct {
	chain bookChain
	books []string
	now   func() time.Time

	mu      sync.Mutex
	series  map[string]string // book -> "future:subId", read once: a book's market never changes series
	cache   map[string]bookDepthResponse
	cacheAt map[string]time.Time
}

func newBookDepthService(chain bookChain, books []string) *bookDepthService {
	if chain == nil || len(books) == 0 {
		return nil
	}
	return &bookDepthService{chain: chain, books: books, now: time.Now, series: map[string]string{}, cache: map[string]bookDepthResponse{},
		cacheAt: map[string]time.Time{}}
}

// handleBookDepth serves GET /book-depth?symbol=: what a take on the series' OnchainBook would fill now, each side,
// at a ladder of sizes, read with the book's own quote(). The venue's matcher holds no futures depth since the
// makers moved to the books; this is where the futures liquidity is.
func (s *Server) handleBookDepth(w http.ResponseWriter, r *http.Request) {
	market, ok := s.resolveMarket(w, r)
	if !ok {
		return
	}
	svc := s.bookDepth
	if svc == nil || !market.IsFuture() {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no onchain book serves this market"})
		return
	}
	depth, err := svc.depth(r.Context(), market)
	if errors.Is(err, errNoBookForSeries) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "no onchain book serves this market"})
		return
	}
	if err != nil {
		slog.Warn("book_depth_unreadable", "market", market.Symbol, "error", err)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"error": "the onchain book could not be read; retry shortly"})
		return
	}
	w.Header().Set("Cache-Control", "max-age=5")
	writeJSON(w, http.StatusOK, depth)
}

var errNoBookForSeries = errors.New("no onchain book serves this series")

func (svc *bookDepthService) depth(ctx context.Context, market instruments.Metadata) (bookDepthResponse, error) {
	svc.mu.Lock()
	if cached, ok := svc.cache[market.Symbol]; ok && svc.now().Sub(svc.cacheAt[market.Symbol]) < bookDepthCacheTTL {
		svc.mu.Unlock()
		return cached, nil
	}
	svc.mu.Unlock()

	book, err := svc.bookFor(ctx, market)
	if err != nil {
		return bookDepthResponse{}, err
	}
	deadline := svc.now().Unix() + 60
	out := bookDepthResponse{Market: market.Symbol, Book: book, MarketID: bookDepthMarketID, ReadAt: svc.now().Unix()}
	for _, size := range bookDepthLadder {
		amount, ok := contractsToUnits(size)
		if !ok {
			return bookDepthResponse{}, fmt.Errorf("bad ladder size %s", size)
		}
		for _, isBuy := range []bool{true, false} {
			level, err := svc.quote(ctx, book, isBuy, amount, deadline)
			if err != nil {
				return bookDepthResponse{}, err
			}
			level.Contracts = size
			// A buy takes the asks; a sell, the bids.
			if isBuy {
				out.Asks = append(out.Asks, level)
			} else {
				out.Bids = append(out.Bids, level)
			}
		}
	}
	svc.mu.Lock()
	svc.cache[market.Symbol], svc.cacheAt[market.Symbol] = out, svc.now()
	svc.mu.Unlock()
	return out, nil
}

// bookFor finds the book whose market 1 trades the series, reading each configured book's markets(1) once.
func (svc *bookDepthService) bookFor(ctx context.Context, market instruments.Metadata) (string, error) {
	want := strings.ToLower(market.AssetAddress) + ":" + market.SubID
	for _, book := range svc.books {
		svc.mu.Lock()
		series, known := svc.series[book]
		svc.mu.Unlock()
		if !known {
			result, err := svc.chain.ethCall(ctx, book, "0x"+selectorBookMarkets+fmt.Sprintf("%064x", bookDepthMarketID))
			if err != nil {
				return "", fmt.Errorf("read %s markets(1): %w", book, err)
			}
			raw := strings.TrimPrefix(result, "0x")
			if len(raw) < 3*64 {
				return "", fmt.Errorf("read %s markets(1): short result", book)
			}
			future := "0x" + raw[24:64]
			subID, _ := new(big.Int).SetString(raw[2*64:3*64], 16)
			series = strings.ToLower(future) + ":" + subID.String()
			svc.mu.Lock()
			svc.series[book] = series
			svc.mu.Unlock()
		}
		if series == want {
			return book, nil
		}
	}
	return "", errNoBookForSeries
}

func (svc *bookDepthService) quote(ctx context.Context, book string, isBuy bool, amount *big.Int, deadline int64) (bookDepthLevel, error) {
	result, err := svc.chain.ethCall(ctx, book, encodeBookQuote(isBuy, amount, deadline))
	if err != nil {
		return bookDepthLevel{}, fmt.Errorf("quote %s: %w", book, err)
	}
	raw := strings.TrimPrefix(result, "0x")
	if len(raw) < 4*64 {
		return bookDepthLevel{}, fmt.Errorf("quote %s: short result", book)
	}
	num := func(i int) *big.Int { n, _ := new(big.Int).SetString(raw[i*64:(i+1)*64], 16); return n }
	filled, avg, fee := num(0), num(1), num(2)
	level := bookDepthLevel{Filled: bookWeiToDecimal(filled)}
	if filled.Sign() > 0 {
		level.AvgPrice, level.Fee = bookWeiToDecimal(avg), bookWeiToDecimal(fee)
	}
	return level, nil
}

// encodeBookQuote is quote(TakeOrder) for a price quote with no account (takerAccountId 0): market 1, the amount,
// no price limit (a buy accepts any price, a sell any above zero), no minimum fill, a fee bound that never binds,
// 255 levels, Abort, no managerData. The TakeOrder holds `bytes`, so it is encoded behind an offset.
func encodeBookQuote(isBuy bool, amount *big.Int, deadline int64) string {
	w := func(v *big.Int) string { return fmt.Sprintf("%064x", v) }
	maxUint := new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(1)) // high enough, and positive as int256
	limit, buy := big.NewInt(0), big.NewInt(0)
	if isBuy {
		limit, buy = maxUint, big.NewInt(1)
	}
	words := []string{
		w(big.NewInt(0x20)),              // offset of the tuple
		w(big.NewInt(bookDepthMarketID)), // marketId
		w(big.NewInt(0)),                 // takerAccountId: a quote with no account
		w(buy),                           // isBuy
		w(amount),                        // amount
		w(limit),                         // limitPrice
		w(big.NewInt(0)),                 // minFill
		w(maxUint),                       // maxFee
		w(big.NewInt(deadline)),          // deadline
		w(big.NewInt(255)),               // maxLevels
		w(big.NewInt(0)),                 // selfTradeMode: Abort
		w(big.NewInt(11 * 32)),           // managerData's offset within the tuple
		w(big.NewInt(0)),                 // managerData's length
	}
	return "0x" + selectorBookQuote + strings.Join(words, "")
}

// contractsToUnits is a decimal number of contracts in position units (1e18 a contract).
func contractsToUnits(contracts string) (*big.Int, bool) {
	r, ok := new(big.Rat).SetString(contracts)
	if !ok {
		return nil, false
	}
	r.Mul(r, new(big.Rat).SetInt(new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)))
	if !r.IsInt() {
		return nil, false
	}
	return r.Num(), true
}

// bookWeiToDecimal is an 18-dp chain value as an exact decimal, trailing zeros trimmed: 1160000000000000000 is "1.16".
func bookWeiToDecimal(wei *big.Int) string {
	r := new(big.Rat).SetFrac(wei, new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil))
	s := r.FloatString(18)
	if strings.Contains(s, ".") {
		s = strings.TrimRight(strings.TrimRight(s, "0"), ".")
	}
	return s
}

// bookDepthChain reads the books through CHAIN_RPC_URL; nil without it, which turns /book-depth off.
func bookDepthChain(cfg config.Config) bookChain {
	if strings.TrimSpace(cfg.ChainRPCURL) == "" {
		return nil
	}
	return &chainCustodyChecker{rpcURL: strings.TrimSpace(cfg.ChainRPCURL), httpClient: &http.Client{Timeout: 5 * time.Second}}
}
