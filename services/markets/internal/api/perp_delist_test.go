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

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/ordersig"
)

// delistedConfig is the venue after the perp's delisting: the shared module, cash and SRM set, the
// perp's asset unset, spot and the future configured.
func delistedConfig(rpc string) config.Config {
	cfg := futureConfig(rpc)
	cfg.CNGNSpotAssetAddress = "0x6666666666666666666666666666666666666666"
	cfg.CNGNPerpSRMAddress = "0x5555555555555555555555555555555555555555"
	cfg.MatchingAddress = "0x9e90a9cd13d859bd6a08168082fb1f6f7405f191"
	return cfg
}

func TestADelistedPerpIsAnUnknownMarketUnderEitherName(t *testing.T) {
	cfg := delistedConfig("http://rpc")
	server := &Server{cfg: cfg, instruments: instruments.DefaultRegistry(cfg)}
	for _, symbol := range []string{"cNGN-PERP", "USDCcNGN-PERP"} {
		rec := httptest.NewRecorder()
		if _, ok := server.resolveMarket(rec, httptest.NewRequest(http.MethodGet, "/v1/book?symbol="+symbol, nil)); ok {
			t.Errorf("%s resolved", symbol)
		}
		if rec.Code != http.StatusBadRequest || !strings.Contains(rec.Body.String(), `"unknown_market"`) {
			t.Errorf("%s: status=%d body=%s; want 400 unknown_market", symbol, rec.Code, rec.Body.String())
		}
	}
	for _, symbol := range []string{instruments.CNGNSpotSymbol} {
		if _, ok := server.resolveMarket(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/v1/book?symbol="+symbol, nil)); !ok {
			t.Errorf("%s no longer resolves", symbol)
		}
	}
}

func TestADelistedPerpHasNoStateAndTheMarketsListLeavesItOut(t *testing.T) {
	rpc := newFutureRPC()
	srv := rpc.server(t)
	defer srv.Close()
	cfg := delistedConfig(srv.URL)
	if reader := newPerpStateReader(cfg); reader != nil {
		t.Fatal("perp state (mark, index, funding) is read with the perp delisted")
	}
	registry := instruments.DefaultRegistry(cfg)
	future := newFutureStateReader(cfg)
	server := &Server{cfg: cfg, instruments: registry, future: future, futureSeries: newFutureSeriesReaders(cfg, registry, future)}
	rec := httptest.NewRecorder()
	server.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var entries []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("markets: %v %s", err, rec.Body.String())
	}
	var listed []string
	for _, entry := range entries {
		listed = append(listed, fmt.Sprint(entry["market"]))
		if entry["contract_type"] == "perpetual" {
			t.Errorf("the perp is listed: %v", entry)
		}
	}
	if !strings.Contains(strings.Join(listed, ","), instruments.CNGNSpotSymbol) {
		t.Errorf("spot is not listed: %v", listed)
	}
	// The future is listed, on the shared module and cash.
	entry := futureEntry(t, server)
	if entry["trade_module_address"] != testFutureTM || entry["quote_asset_address"] != cfg.CNGNPerpCashAddress {
		t.Errorf("the future's stack = %v / %v", entry["trade_module_address"], entry["quote_asset_address"])
	}
}

// The future still admits an order it could settle, with the perp delisted.
func TestTheFutureAdmitsOrdersWithThePerpDelisted(t *testing.T) {
	rpc := newFutureRPC()
	index := new(big.Int).Div(new(big.Int).Mul(testWad, testWad), rpc.spot)
	srv := rpc.server(t)
	defer srv.Close()
	cfg := delistedConfig(srv.URL)
	registry := instruments.DefaultRegistry(cfg)
	future := newFutureStateReader(cfg)
	server := &Server{cfg: cfg, instruments: registry, future: future, futureSeries: newFutureSeriesReaders(cfg, registry, future)}
	instrument, ok := registry.ByAssetAndSubID(testFuture, fmt.Sprint(testFutureExpiry))
	if !ok {
		t.Fatal("no future instrument")
	}
	if status, msg := server.admitFuture(context.Background(), instrument, futureOrder("7", index.String())); status != 0 {
		t.Fatalf("an in-band future order with the perp delisted: %d %q", status, msg)
	}
}

// The USDC withdrawal ledger check reads the shared cash whether or not the perp is listed: a
// withdrawal of that cash is still held to the account's balance.
func TestTheUSDCWithdrawalLedgerCheckRunsWithThePerpDelisted(t *testing.T) {
	cfg := delistedConfig("http://rpc")
	cfg.WithdrawalModuleAddress = "0x0a10ae2f5d2482ce1e43bc309d430b8861c2b5ab"
	cfg.ExecutorWithdrawURL = "http://executor"
	cfg.WithdrawalAssetAddresses = []string{cfg.CNGNPerpCashAddress}
	svc := newWithdrawalService(cfg, &stubSignatureChecker{path: ordersig.PathEOA})
	if svc == nil {
		t.Fatal("withdrawals are off")
	}
	ledger, ok := svc.ledger.(*chainCashLedger)
	if !ok || ledger.cash != cfg.CNGNPerpCashAddress || svc.perpCash != cfg.CNGNPerpCashAddress {
		t.Fatalf("ledger = %#v, perpCash = %q; want the cash ledger on %s", svc.ledger, svc.perpCash, cfg.CNGNPerpCashAddress)
	}
}
