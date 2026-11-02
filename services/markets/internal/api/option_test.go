package api

import (
	"context"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

const (
	optEngine  = "0x0705219a1594d5fc5dc2573da4082cae3e1b0950"
	optAsset   = "0x00000000000000000000000000000000000000a1"
	optLedger  = "0x7019244e25fa416e6ca2ed2f3ca25277aef72843"
	optOther   = "0x00000000000000000000000000000000000000ee"
	optVolFeed = "0x00000000000000000000000000000000000000a2"
)

// optChain answers subAccounts() on the option and manager(uint256) on the ledger: account 7 is under the engine, 8 is not.
func optChain(t *testing.T) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct{ To, Data string }
		_ = json.Unmarshal(req.Params[0], &call)
		word := func(address string) string { return "0x" + strings.Repeat("0", 24) + strings.TrimPrefix(address, "0x") }
		result := ""
		switch {
		case strings.HasPrefix(call.Data, "0x779e5012"): // subAccounts()
			result = word(optLedger)
		case strings.HasPrefix(call.Data, "0x52981457"): // manager(uint256)
			account, _ := new(big.Int).SetString(call.Data[10:], 16)
			result = word(optOther)
			if account.Int64() == 7 {
				result = word(optEngine)
			}
		default:
			t.Errorf("unexpected eth_call %s", call.Data[:10])
		}
		fmt.Fprintf(w, `{"jsonrpc":"2.0","id":1,"result":%q}`, result)
	}))
}

func optSeries(rpc string) (config.Config, instruments.Metadata) {
	fee := 300
	series := config.OptionSeries{AssetAddress: optAsset, ManagerAddress: optEngine, VolFeedAddress: optVolFeed, BaseAsset: "cNGN",
		Expiry: time.Now().Add(48 * time.Hour).Unix(), Strikes: []string{"0.00072"}, AmountScale: "1000000000000000000000", TakerFeeBps: &fee}
	cfg := config.Config{ChainRPCURL: rpc, OptionSeries: []config.OptionSeries{series}}
	var put instruments.Metadata
	for _, m := range instruments.DefaultRegistry(cfg).Enabled() {
		if m.IsOption() && m.OptionType == "put" {
			put = m
		}
	}
	return cfg, put
}

// action_json for an order at `limit` (18dp USDC per cNGN): only data's limitPrice is read here.
func optAction(limit *big.Int) json.RawMessage {
	words := []string{
		strings.Repeat("0", 64),             // asset
		strings.Repeat("0", 64),             // subId
		fmt.Sprintf("%064x", limit),         // limitPrice
		fmt.Sprintf("%064x", big.NewInt(1)), // desiredAmount
		strings.Repeat("0", 64),             // worstFee
		fmt.Sprintf("%064x", big.NewInt(7)), // recipientId
		fmt.Sprintf("%064x", big.NewInt(1)), // isBid
	}
	raw, _ := json.Marshal(map[string]string{"data": "0x" + strings.Join(words, "")})
	return raw
}

func TestOptionMarketsAreListed(t *testing.T) {
	_, put := optSeries("http://rpc")
	if put.Symbol == "" || !strings.HasSuffix(put.Symbol, "-0.00072-P") || put.ContractType != instruments.ContractTypeOption {
		t.Fatalf("the put is listed: %+v", put)
	}
	if put.LastTradeTimestamp != put.ExpiryTimestamp-3600 || put.OptionStrike != "0.00072" || put.VolFeedAddress != optVolFeed {
		t.Fatalf("its terms: %+v", put)
	}
	// One desired_amount is amount_scale / 1e18 of the base: 1,000 cNGN at 1e21. Every unit field says so, since a reader
	// who takes desired_amount for whole cNGN trades a thousand times what they meant.
	if put.AmountScale != "1000000000000000000000" || put.UISizeUnit != "1,000 cNGN" || put.EngineAmountUnit != "1,000 cNGN" ||
		!strings.Contains(put.UISizeToEngine, "ui_size x 1,000 cNGN") || !strings.Contains(put.SettlementNote, "desired_amount 1 is 1,000 cNGN") {
		t.Fatalf("the size unit: scale %s, ui %q, engine %q, %q; note %q", put.AmountScale, put.UISizeUnit, put.EngineAmountUnit, put.UISizeToEngine, put.SettlementNote)
	}
	unpriced := config.Config{OptionSeries: []config.OptionSeries{{AssetAddress: optAsset, ManagerAddress: optEngine, VolFeedAddress: optVolFeed,
		BaseAsset: "cNGN", Expiry: put.ExpiryTimestamp, Strikes: []string{"0.00072"}, AmountScale: "1"}}}
	for _, m := range instruments.DefaultRegistry(unpriced).Enabled() {
		if m.IsOption() {
			t.Fatalf("an unpriced series is not listed: %s", m.Symbol)
		}
	}
}

func TestAdmitOption(t *testing.T) {
	chain := optChain(t)
	defer chain.Close()
	cfg, put := optSeries(chain.URL)
	s := &Server{optionSeries: newOptionSeriesReaders(cfg)}
	ctx := context.Background()
	at := func(account string, limit *big.Int) orders.CreateOrderParams {
		return orders.CreateOrderParams{OrderID: "o", SubaccountID: account, ActionJSON: optAction(limit)}
	}
	premium := big.NewInt(32_000_000_000_000) // 0.000032 USDC per cNGN

	if status, msg := s.admitOption(ctx, put, at("7", premium)); msg != "" {
		t.Fatalf("an engine account at a sane premium: %d %s", status, msg)
	}
	if status, msg := s.admitOption(ctx, put, at("8", premium)); status != http.StatusUnprocessableEntity || !strings.Contains(msg, "only its accounts") {
		t.Fatalf("another manager's account: %d %s", status, msg)
	}
	// A zero premium: the order decoder already refuses a non-positive limit, before the option's own bound.
	if status, msg := s.admitOption(ctx, put, at("7", big.NewInt(0))); status != http.StatusBadRequest || !strings.Contains(msg, "must be positive") {
		t.Fatalf("a zero premium: %d %s", status, msg)
	}
	if status, msg := optionPremiumBound(put, big.NewInt(0)); status != http.StatusUnprocessableEntity || !strings.Contains(msg, "above zero") {
		t.Fatalf("and the bound refuses it on its own too: %d %s", status, msg)
	}
	strike, _ := config.StrikeWei("0.00072")
	if status, msg := s.admitOption(ctx, put, at("7", new(big.Int).Add(strike, big.NewInt(1)))); status != http.StatusUnprocessableEntity || !strings.Contains(msg, "above the put's strike") {
		t.Fatalf("a put above its strike: %d %s", status, msg)
	}
	if _, msg := s.admitOption(ctx, put, at("7", strike)); msg != "" {
		t.Fatalf("a put at its strike is the most it can pay, not refused: %s", msg)
	}
	expired := put
	expired.LastTradeTimestamp = time.Now().Add(-time.Minute).Unix()
	if status, msg := s.admitOption(ctx, expired, at("7", premium)); status != http.StatusConflict || !strings.Contains(msg, "past its last trade") {
		t.Fatalf("past last trade: %d %s", status, msg)
	}
	call := put
	call.OptionType = "call"
	if _, msg := s.admitOption(ctx, call, at("7", new(big.Int).Mul(strike, big.NewInt(10)))); msg != "" {
		t.Fatalf("a call has no strike bound: %s", msg)
	}
}
