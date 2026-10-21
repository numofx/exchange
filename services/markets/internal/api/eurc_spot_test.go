package api

import (
	"context"
	"encoding/json"
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
	testEURCSpotEscrow = "0x00000000000000000000000000000000000e0dc0"
	testCNGNSpotEscrow = "0xf000000000000000000000000000000000000123"
	baseEURC           = "0x60a3e35cc302bfa44cb288bc5a4f316fdb1adb42"
)

func twoSpotConfig() config.Config {
	return config.Config{
		CNGNSpotAssetAddress:        testCNGNSpotEscrow,
		EURCSpotAssetAddress:        testEURCSpotEscrow,
		EnforceActionDataInvariants: true,
	}
}

func eurcOrderRequest(limitPrice, desiredAmount, signedPrice, signedAmount string) createOrderRequest {
	return createOrderRequest{
		OrderID:       "order-eurc",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "7",
		RecipientID:   "7",
		Nonce:         "21",
		Side:          "buy",
		AssetAddress:  testEURCSpotEscrow,
		SubID:         "0",
		DesiredAmount: desiredAmount,
		FilledAmount:  "0",
		LimitPrice:    limitPrice,
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"7",
			"nonce":"21",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(testEURCSpotEscrow, "0", signedPrice, signedAmount, true) + `",
			"expiry":"2000000000",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}
}

// EURC-USDC takes orders on the plain native path: the price is USDC per EURC as signed, and desired_amount 1 is one
// whole EURC, signed as 1e18.
func TestEURCSpotOrderIsTakenInEngineUnits(t *testing.T) {
	params, err := eurcOrderRequest("1.12345", "3", "1123450000000000000", "3000000000000000000").toParams(twoSpotConfig())
	if err != nil {
		t.Fatalf("toParams: %v", err)
	}
	if params.LimitPriceTicks != "1123450000000000000" || params.DesiredAmount != "3" || params.AssetAddress != testEURCSpotEscrow {
		t.Fatalf("params = %+v", params)
	}

	// Any other amount scale is refused: the market fixes one, as cNGN spot does.
	if _, err := eurcOrderRequest("1.12345", "3", "1123450000000000000", "3000000").toParams(twoSpotConfig()); err == nil {
		t.Fatal("an EURC order signed at a 6-decimal amount scale was accepted")
	}
}

// EURC-USDC carries no ui_intent contract: a ticket signed for cNGN spot's spec, or any spec, is refused on it, and
// nothing about it is presented as the cNGN contract.
func TestEURCSpotRefusesTheUIIntentContract(t *testing.T) {
	for _, spec := range []string{instruments.SpotOrderEntrySpec, instruments.PerpOrderEntrySpec, "eurc_usdc_spot_v1"} {
		req := eurcOrderRequest("1.12345", "3", "1123450000000000000", "3000000000000000000")
		req.OrderEntrySpec = spec
		req.UIIntent = &spotOrderIntent{Side: "buy", Price: "1.12345", Size: "3"}
		if _, err := req.toParams(twoSpotConfig()); err == nil || !strings.Contains(err.Error(), "only supported") {
			t.Fatalf("spec %q: err = %v, want a refusal", spec, err)
		}
	}

	eurc, ok := instruments.DefaultRegistry(twoSpotConfig()).Resolve(instruments.EURCSpotSymbol)
	if !ok {
		t.Fatal("EURC-USDC not listed")
	}
	if isSpotContractInstrument(eurc) {
		t.Fatal("EURC-USDC is not under the cNGN ui_intent contract")
	}
	echo, err := deriveSpotContractFromOrder(orders.Order{Side: orders.SideBuy, LimitPrice: "1.12345", DesiredAmount: "3"}, eurc)
	if err != nil || echo != nil {
		t.Fatalf("EURC order echo = %+v, %v; want none", echo, err)
	}
}

// The integrations endpoints round to each market's own places: cNGN-USDC at the ui_intent echo's (10 / 6), EURC-USDC
// at 5 / 6, and a market without places (the future) at the engine's 18.
func TestIntegrationScalesAreEachMarketsOwn(t *testing.T) {
	registry := instruments.DefaultRegistry(twoSpotConfig())
	cngn, _ := registry.Resolve(instruments.CNGNSpotSymbol)
	eurc, _ := registry.Resolve(instruments.EURCSpotSymbol)

	if o := orientationFor(cngn); o.priceScale() != 10 || o.baseScale() != 6 {
		t.Fatalf("cNGN-USDC scales = %d / %d", o.priceScale(), o.baseScale())
	}
	if o := orientationFor(eurc); o.priceScale() != 5 || o.baseScale() != 6 {
		t.Fatalf("EURC-USDC scales = %d / %d", o.priceScale(), o.baseScale())
	}
	if o := orientationFor(instruments.Metadata{ContractType: instruments.ContractTypeFuture}); o.priceScale() != 18 || o.baseScale() != 18 {
		t.Fatalf("a market without places = %d / %d, want 18 / 18", o.priceScale(), o.baseScale())
	}
}

// The ui_intent markets' display places are what their spot_contract echo is formatted at, so the integrations
// endpoints and the echo cannot show the same order at two precisions.
func TestUIDecimalsMatchTheSpotContractEcho(t *testing.T) {
	registry := instruments.DefaultRegistry(config.Config{
		CNGNSpotAssetAddress:       testCNGNSpotEscrow,
		CNGNPerpAssetAddress:       "0xf000000000000000000000000000000000000456",
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x3333333333333333333333333333333333333333",
		CNGNPerpSRMAddress:         "0x4444444444444444444444444444444444444444",
	})
	checked := 0
	for _, market := range registry.Enabled() {
		if !isSpotContractInstrument(market) {
			continue
		}
		checked++
		if market.UIPriceDecimals != spotUIPriceDecimalScale || market.UISizeDecimals != spotUISizeDecimalScale {
			t.Errorf("%s places = %d / %d, spot_contract echo = %d / %d", market.Symbol, market.UIPriceDecimals, market.UISizeDecimals, spotUIPriceDecimalScale, spotUISizeDecimalScale)
		}
	}
	if checked != 2 {
		t.Fatalf("checked %d ui_intent markets, want 2 (spot and perp)", checked)
	}
}

// /v1/markets lists both spots, each bound to its own escrow, and only EURC-USDC without a ui_intent spec.
func TestHandleMarketsListsBothSpotsUnderTheirOwnAssets(t *testing.T) {
	server := NewServer(config.Config{}, nil, instruments.DefaultRegistry(twoSpotConfig()))
	rec := httptest.NewRecorder()
	server.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d", rec.Code)
	}
	var markets []marketPresentation
	if err := json.Unmarshal(rec.Body.Bytes(), &markets); err != nil {
		t.Fatal(err)
	}
	if len(markets) != 2 || markets[0].Market != "EURC-USDC" || markets[1].Market != "cNGN-USDC" {
		t.Fatalf("markets = %+v", markets)
	}
	eurc, cngn := markets[0], markets[1]
	if eurc.ContractType != "spot" || eurc.AssetAddress != testEURCSpotEscrow || eurc.BaseAssetSymbol != "EURC" || eurc.QuoteAssetSymbol != "USDC" ||
		eurc.OrderEntrySpec != "" || eurc.UIPriceUnit != "USDC per EURC" || eurc.TakerFeeBps != 5 || eurc.MakerFeeBps != 0 ||
		eurc.AmountScale != instruments.SpotAmountScale || eurc.MinSize != "1" || eurc.AmountStep != "1" ||
		eurc.UIPriceDecimals != 5 || eurc.UISizeDecimals != 6 {
		t.Fatalf("EURC-USDC listing = %+v", eurc)
	}
	if cngn.AssetAddress != testCNGNSpotEscrow || cngn.OrderEntrySpec != instruments.SpotOrderEntrySpec || cngn.UIPriceDecimals != 10 {
		t.Fatalf("cNGN-USDC listing = %+v", cngn)
	}
}

// EURC is a Circle FiatToken: the venue reads its pause and each party's freeze from the token itself, as for USDC.
func TestTokenControlsReadEURCFromTheTokenItself(t *testing.T) {
	owner := strings.ToLower(testWithdrawalOwner)
	state := newTokenState()
	state.tokens[testEURCSpotEscrow] = baseEURC
	if stop, err := checkTokenControls(context.Background(), state, testEURCSpotEscrow, "withdrawal", withdrawalParties(owner, testEURCSpotEscrow)); stop != nil || err != nil {
		t.Fatalf("nothing frozen: stop=%+v err=%v", stop, err)
	}
	want := []string{
		baseEURC + " " + sigPaused,
		frozenAt(baseEURC, sigIsBlacklisted, owner),
		frozenAt(baseEURC, sigIsBlacklisted, testEURCSpotEscrow),
	}
	if strings.Join(state.calls, "\n") != strings.Join(want, "\n") {
		t.Fatalf("EURC reads:\n%s\nwant:\n%s", strings.Join(state.calls, "\n"), strings.Join(want, "\n"))
	}

	for _, tc := range []struct {
		answer string
		status int
		words  string
	}{
		{baseEURC + " " + sigPaused, http.StatusServiceUnavailable, "EURC is paused by its issuer"},
		{frozenAt(baseEURC, sigIsBlacklisted, owner), http.StatusBadRequest, "EURC's issuer has frozen " + owner},
		{frozenAt(baseEURC, sigIsBlacklisted, testEURCSpotEscrow), http.StatusServiceUnavailable, "frozen the venue's custody contract (" + testEURCSpotEscrow},
	} {
		state := newTokenState()
		state.tokens[testEURCSpotEscrow] = baseEURC
		state.answers[tc.answer] = trueWord
		stop, err := checkTokenControls(context.Background(), state, testEURCSpotEscrow, "withdrawal", withdrawalParties(owner, testEURCSpotEscrow))
		if err != nil || stop == nil || stop.status != tc.status || !strings.Contains(stop.message, tc.words) {
			t.Fatalf("%s: stop=%+v err=%v; want %d mentioning %q", tc.answer, stop, err, tc.status, tc.words)
		}
	}
}
