package api

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"golang.org/x/crypto/sha3"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

func e18Int(whole int64) *big.Int { return new(big.Int).Mul(big.NewInt(whole), perpE18) }

// A UI long of $7,200 is a SHORT of 10M cNGN at 0.00072. With $1,540 of maintenance surplus and a
// 20% MM, it is liquidated when USD falls far enough against NGN: the engine price must RISE.
func TestLiquidationPriceForAUILongIsAboveTheMarkInEngineTerms(t *testing.T) {
	mark := big.NewInt(720_000_000_000_000)
	size := new(big.Int).Neg(e18Int(10_000_000))
	mm := big.NewInt(200_000_000_000_000_000)
	p := liquidationPrice(size, mark, mm, e18Int(1_540))
	if p == nil {
		t.Fatal("a margined short has a liquidation price")
	}
	// surplus(P) = 1540 + (-S - 0.2 S)(P - M) with S = 1e7: P = M + 1540 / 1.2e7
	want := new(big.Rat).Add(new(big.Rat).SetFrac(mark, perpE18), big.NewRat(1540, 12_000_000))
	if p.Cmp(want) != 0 {
		t.Fatalf("liquidation price = %s, want %s", p.FloatString(12), want.FloatString(12))
	}
	if p.Cmp(new(big.Rat).SetFrac(mark, perpE18)) <= 0 {
		t.Fatal("a short is liquidated above the mark")
	}
}

func TestLiquidationPriceForALongIsBelowTheMark(t *testing.T) {
	mark := big.NewInt(720_000_000_000_000)
	p := liquidationPrice(e18Int(10_000_000), mark, big.NewInt(200_000_000_000_000_000), e18Int(1_000))
	if p == nil || p.Cmp(new(big.Rat).SetFrac(mark, perpE18)) >= 0 {
		t.Fatalf("a long is liquidated below the mark, got %v", p)
	}
}

func TestNoLiquidationPriceWhenNoPositivePriceReachesIt(t *testing.T) {
	// A long so overcollateralized the price would have to go negative.
	if p := liquidationPrice(e18Int(1_000), big.NewInt(720_000_000_000_000), big.NewInt(200_000_000_000_000_000), e18Int(1_000_000)); p != nil {
		t.Fatalf("want no liquidation price, got %s", p.FloatString(12))
	}
}

// ---------------------------------------------------------------------------------------------
// the endpoints against a stubbed chain
// ---------------------------------------------------------------------------------------------

const (
	testPerpAsset = "0x3333333333333333333333333333333333333333"
	testPerpSRM   = "0x5555555555555555555555555555555555555555"
)

func word(v *big.Int) string {
	if v.Sign() >= 0 {
		return fmt.Sprintf("%064x", v)
	}
	return fmt.Sprintf("%064x", new(big.Int).Add(new(big.Int).Lsh(big.NewInt(1), 256), v))
}

// stubPaused is what the stub answers for the SRM's adjustmentsPaused(): 0 unless a test pauses it.
// stubCap is the OI cap it serves, in whole cNGN: 50M unless a test closes the market.
var (
	stubPaused int64
	stubCap    int64 = 50_000_000
	// stubDepositsOpen is the escrow's whitelistedManager(srm): 0 until a test opens deposits.
	stubDepositsOpen int64
)

func stubPerpRPC(t *testing.T, position *big.Int) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Params []json.RawMessage `json:"params"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		var call struct {
			Data string `json:"data"`
		}
		_ = json.Unmarshal(req.Params[0], &call)
		mark := big.NewInt(720_000_000_000_000)
		var result string
		switch strings.ToLower(call.Data)[:10] {
		case "0x779e5012": // Matching.subAccounts()
			result = word(big.NewInt(0x7019))
		case sigGetIndexPrice, sigGetPerpPrice:
			result = word(mark) + word(perpE18)
		case sigGetFundingRate:
			result = word(big.NewInt(12_500_000_000_000)) // 0.0000125/h: NGN longs pay
		case sigOpenInterest:
			result = word(e18Int(10_000_000))
		case sigAssetDetails:
			result = word(big.NewInt(1)) + word(big.NewInt(2)) + word(big.NewInt(1))
		case sigPerpMarginRequirements:
			result = word(big.NewInt(200_000_000_000_000_000)) + word(big.NewInt(333_330_000_000_000_000))
		case sigGetBalance:
			if strings.Contains(strings.ToLower(call.Data), strings.TrimPrefix(testPerpCollateral, "0x")) {
				result = word(e18Int(2_000_000)) // 2M cNGN posted
			} else {
				result = word(position)
			}
		case sigBaseMarginParams:
			result = word(big.NewInt(500_000_000_000_000_000)) + word(perpE18) // 50% haircut, IM scale 1
		case sigTotalPosition:
			result = word(e18Int(2_000_000))
		case sigWhitelistedManager:
			result = word(big.NewInt(stubDepositsOpen))
		case sigUnrealizedCash:
			result = word(new(big.Int).Neg(e18Int(40)))
		case sigGetMargin:
			result = word(e18Int(1_540))
		case sigAllowedModules:
			result = word(big.NewInt(1))
		case sigTotalPositionCap:
			result = word(e18Int(stubCap))
		case sigAdjustmentsPaused:
			result = word(big.NewInt(stubPaused))
		default:
			t.Errorf("unexpected call %s", call.Data[:10])
		}
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"0x` + result + `"}`))
	}))
}

func perpServer(t *testing.T, rpc string) *Server {
	t.Helper()
	cfg := config.Config{
		ChainRPCURL:                rpc,
		MatchingAddress:            "0x1111111111111111111111111111111111111111",
		CNGNPerpAssetAddress:       testPerpAsset,
		CNGNPerpTradeModuleAddress: "0x2222222222222222222222222222222222222222",
		CNGNPerpCashAddress:        "0x4444444444444444444444444444444444444444",
		CNGNPerpSRMAddress:         testPerpSRM,
	}
	return &Server{cfg: cfg, instruments: instruments.DefaultRegistry(cfg), perp: newPerpStateReader(cfg)}
}

const testPerpCollateral = "0x6666666666666666666666666666666666666666"

// perpServerWithCollateral is perpServer once the vault has whitelisted the cNGN escrow.
func perpServerWithCollateral(t *testing.T, rpc string) *Server {
	t.Helper()
	s := perpServer(t, rpc)
	s.cfg.CNGNPerpCollateralAddress = testPerpCollateral
	s.instruments = instruments.DefaultRegistry(s.cfg)
	return s
}

// The selectors the perp reader hardcodes, against keccak of their signatures: a stub answers
// whatever constant the code uses, so only this (or the chain) catches a typo.
func TestPerpStateSelectorsMatchTheirSignatures(t *testing.T) {
	for sig, want := range map[string]string{
		"baseMarginParams(uint256)":           sigBaseMarginParams,
		"totalPosition(address)":              sigTotalPosition,
		"whitelistedManager(address)":         sigWhitelistedManager,
		"totalPositionCap(address)":           sigTotalPositionCap,
		"adjustmentsPaused()":                 sigAdjustmentsPaused,
		"getBalance(uint256,address,uint256)": sigGetBalance,
	} {
		h := sha3.NewLegacyKeccak256()
		h.Write([]byte(sig))
		if got := "0x" + hex.EncodeToString(h.Sum(nil)[:4]); got != want {
			t.Fatalf("%s: selector %s, constant %s", sig, got, want)
		}
	}
}

func TestMarketsAndPositionsReportCngnCollateralOnceConfigured(t *testing.T) {
	rpc := stubPerpRPC(t, big.NewInt(0))
	defer rpc.Close()
	without := perpServer(t, rpc.URL)
	rec := httptest.NewRecorder()
	without.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var plain []struct {
		Perp struct {
			CollateralAssets []perpCollateralAsset `json:"collateral_assets"`
		} `json:"perp"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &plain); err != nil {
		t.Fatal(err)
	}
	if len(plain) != 1 || len(plain[0].Perp.CollateralAssets) != 0 {
		t.Fatalf("cash-only perp must list no collateral assets: %s", rec.Body.String())
	}

	s := perpServerWithCollateral(t, rpc.URL)
	rec = httptest.NewRecorder()
	s.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var markets []struct {
		Perp struct {
			CollateralAssets []perpCollateralAsset `json:"collateral_assets"`
		} `json:"perp"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &markets); err != nil {
		t.Fatal(err)
	}
	assets := markets[0].Perp.CollateralAssets
	if len(assets) != 1 || assets[0].Symbol != "cNGN" || assets[0].AssetAddress != testPerpCollateral {
		t.Fatalf("collateral asset: %+v", assets)
	}
	if assets[0].MarginFactor != "0.5" || assets[0].IMScale != "1" {
		t.Fatalf("haircut: %+v", assets[0])
	}
	if assets[0].Cap != "50000000" || assets[0].Total != "2000000" {
		t.Fatalf("cap/total: %+v", assets[0])
	}
	if assets[0].DepositsOpen {
		t.Fatalf("the escrow is configured but not yet open: deposits_open must be false: %+v", assets[0])
	}
	stubDepositsOpen = 1
	defer func() { stubDepositsOpen = 0 }()
	s.perp.cache = map[string]cachedPerpState{}
	rec = httptest.NewRecorder()
	s.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	if err := json.Unmarshal(rec.Body.Bytes(), &markets); err != nil {
		t.Fatal(err)
	}
	if !markets[0].Perp.CollateralAssets[0].DepositsOpen {
		t.Fatalf("once the escrow accepts the SRM, deposits_open must be true: %s", rec.Body.String())
	}

	rec = httptest.NewRecorder()
	s.handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=25", nil))
	var body struct {
		Accounts []presentedPerpAccount `json:"accounts"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Accounts) != 1 || len(body.Accounts[0].Collateral) != 1 {
		t.Fatalf("account must carry its collateral: %s", rec.Body.String())
	}
	row := body.Accounts[0].Collateral[0]
	// 2M cNGN at 0.00072 USDC/cNGN is $1,440; the SRM credits half of it.
	if row.Balance != "2000000" || row.ValueUSD != "1440" || row.MarginValueUSD != "720" {
		t.Fatalf("collateral row: %+v", row)
	}
}

func TestMarketsServesPerpStateWithTheFundingSignFlippedForTheUI(t *testing.T) {
	rpc := stubPerpRPC(t, big.NewInt(0))
	defer rpc.Close()
	server := perpServer(t, rpc.URL)

	recorder := httptest.NewRecorder()
	server.handleMarkets(recorder, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var markets []marketPresentation
	if err := json.Unmarshal(recorder.Body.Bytes(), &markets); err != nil {
		t.Fatalf("decode: %v", err)
	}
	var perp *marketPresentation
	for i := range markets {
		if markets[i].Market == instruments.CNGNPerpSymbol {
			perp = &markets[i]
		}
	}
	if perp == nil || perp.Perp == nil {
		t.Fatalf("the perp and its chain state must be served, got %s", recorder.Body.String())
	}
	if perp.Perp.MarkPriceUI != "1388.888889" {
		t.Fatalf("mark in cNGN per USDC = %q, want 1388.888889", perp.Perp.MarkPriceUI)
	}
	if !strings.HasPrefix(perp.Perp.UILongFunding1h, "-") || strings.HasPrefix(perp.Perp.FundingRate1h, "-") {
		t.Fatalf("NGN longs pay a positive rate, so the venue's long receives it: %+v", perp.Perp)
	}
	if perp.Perp.MaxLeverage != "3" {
		t.Fatalf("33.333%% IM is 3x, got %q", perp.Perp.MaxLeverage)
	}
	if !perp.Perp.TradingEnabled || perp.Perp.PositionCap != "50000000" {
		t.Fatalf("an allowlisted module with a positive cap is open, got %+v", perp.Perp)
	}
	if perp.Perp.TradeModule != "0x2222222222222222222222222222222222222222" {
		t.Fatal("clients sign perp orders for the perp module and must be told which it is")
	}
}

func TestPositionsReportsAnNGNShortAsTheVenuesLong(t *testing.T) {
	rpc := stubPerpRPC(t, new(big.Int).Neg(e18Int(10_000_000)))
	defer rpc.Close()
	server := perpServer(t, rpc.URL)

	recorder := httptest.NewRecorder()
	server.handlePositions(recorder, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	var body struct {
		Positions []presentedPosition `json:"positions"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v (%s)", err, recorder.Body.String())
	}
	if len(body.Positions) != 1 {
		t.Fatalf("want one position, got %s", recorder.Body.String())
	}
	got := body.Positions[0]
	if got.UISide != "long" || got.UISize != "7200" {
		t.Fatalf("10M cNGN short at 0.00072 is a $7,200 UI long, got %+v", got)
	}
	// USD must weaken for a USD long to be liquidated: its liquidation price sits below the mark.
	if got.LiquidationPriceUI != "1178.781925" {
		t.Fatalf("liquidation price = %q, want 1178.781925 cNGN/USDC (below the 1388.89 mark)", got.LiquidationPriceUI)
	}
}

func TestPositionsIsEmptyForAnAccountWithNoPerp(t *testing.T) {
	rpc := stubPerpRPC(t, big.NewInt(0))
	defer rpc.Close()
	recorder := httptest.NewRecorder()
	perpServer(t, rpc.URL).handlePositions(recorder, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	if !strings.Contains(recorder.Body.String(), `"positions":[]`) {
		t.Fatalf("want an empty list, got %s", recorder.Body.String())
	}
	// The account's margin is still served: it is what the ticket shows before the first trade.
	if !strings.Contains(recorder.Body.String(), `"initial_margin_surplus":"1540"`) {
		t.Fatalf("want the account summary, got %s", recorder.Body.String())
	}
}

func TestPositionsRequiresASubaccount(t *testing.T) {
	recorder := httptest.NewRecorder()
	(&Server{}).handlePositions(recorder, httptest.NewRequest(http.MethodGet, "/v1/positions", nil))
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", recorder.Code)
	}
}

// The guardian's pause is served as its own flag and turns trading_enabled off; lifting it turns
// it back on. The reader caches the rest of the state, but the pause is read fresh every time.
func TestMarketsReportsTheGuardianPause(t *testing.T) {
	rpc := stubPerpRPC(t, big.NewInt(0))
	defer rpc.Close()
	srv := perpServer(t, rpc.URL)
	read := func() (bool, bool) {
		rec := httptest.NewRecorder()
		srv.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
		var markets []struct {
			Market string `json:"market"`
			Perp   *struct {
				TradingEnabled bool `json:"trading_enabled"`
				Paused         bool `json:"paused"`
			} `json:"perp"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &markets); err != nil {
			t.Fatalf("decode: %v", err)
		}
		for _, m := range markets {
			if m.Market == "USDCcNGN-PERP" && m.Perp != nil {
				return m.Perp.TradingEnabled, m.Perp.Paused
			}
		}
		t.Fatalf("no perp block in %s", rec.Body.String())
		return false, false
	}
	stubPaused = 0
	if enabled, paused := read(); !enabled || paused {
		t.Fatalf("open market: trading_enabled=%v paused=%v", enabled, paused)
	}
	stubPaused = 1
	if enabled, paused := read(); enabled || !paused {
		t.Fatalf("paused market: trading_enabled=%v paused=%v", enabled, paused)
	}
	stubPaused = 0
	if enabled, paused := read(); !enabled || paused {
		t.Fatalf("unpaused market: trading_enabled=%v paused=%v", enabled, paused)
	}
}

// A pause lifted on a market that was never enabled does not open it: the cached state remembers
// which half of trading_enabled the enable action still owes.
func TestLiftingAPauseDoesNotOpenAClosedMarket(t *testing.T) {
	rpc := stubPerpRPC(t, big.NewInt(0))
	defer rpc.Close()
	stubCap = 0
	defer func() { stubCap = 50_000_000 }()
	srv := perpServer(t, rpc.URL)
	for _, step := range []int64{1, 0} {
		stubPaused = step
		rec := httptest.NewRecorder()
		srv.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
		if strings.Contains(rec.Body.String(), `"trading_enabled":true`) {
			t.Fatalf("paused=%d on a cap-0 market read as enabled: %s", step, rec.Body.String())
		}
	}
	stubPaused = 0
}

// The venue's rule for cNGN-margined accounts at order submission: long USD (an engine sell of the
// cNGN perp) up to the cNGN posted, never long naira; a USDC-margined account is untouched.
