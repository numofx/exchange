package api

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
)

type positionsBody struct {
	Positions      []presentedPosition       `json:"positions"`
	Accounts       []presentedPerpAccount    `json:"accounts"`
	Futures        []presentedFuturePosition `json:"futures"`
	FuturesAccount *presentedFuturesAccount  `json:"futures_account"`
}

func getPositions(t *testing.T, server *Server, subaccount string) (positionsBody, string) {
	t.Helper()
	rec := httptest.NewRecorder()
	server.handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id="+subaccount, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var body positionsBody
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode: %v (%s)", err, rec.Body.String())
	}
	return body, rec.Body.String()
}

func contractsWad(whole, tenths int64) *big.Int {
	return new(big.Int).Div(new(big.Int).Mul(big.NewInt(whole*10+tenths), testWad), big.NewInt(10))
}

var testFutureSymbol = instruments.FutureSymbol(testFutureExpiry)
var testFutureSubID = strconv.FormatInt(testFutureExpiry, 10)

// A futures position is on /v1/positions under "futures", read from the series at its expiry: a short
// of 2.5 contracts is 2,500 USDC of notional at the series' mark. The engine's margin is the
// account's, so it is reported once under futures_account, not on the position.
func TestPositionsListsTheFuturesPosition(t *testing.T) {
	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": new(big.Int).Neg(contractsWad(2, 5))}
	rpc := stub.server(t)
	defer rpc.Close()

	body, raw := getPositions(t, futureServer(t, rpc.URL), "42")
	if len(body.Positions) != 0 || len(body.Futures) != 1 {
		t.Fatalf("want one futures position and no perp, got %s", raw)
	}
	updated := time.Unix(testFutureLastMark, 0).UTC()
	want := presentedFuturePosition{
		Market: testFutureSymbol, SubID: testFutureSubID, Status: futureStatusTrading,
		Contracts: "-2.5", Side: "short", NotionalUSDC: "2500", MarkPrice: "1400", MarkUpdatedAt: &updated, PendingVMCNGN: "0",
	}
	if got := body.Futures[0]; !futurePositionEqual(got, want) {
		t.Fatalf("got %s\nwant %s", show(got), show(want))
	}
	if strings.Contains(show(body.Futures), "surplus") {
		t.Fatalf("margin surplus is the account's, not the position's: %s", raw)
	}
	wantAccount := presentedFuturesAccount{SubaccountID: "42", Manager: testFutureEngine, IMSurplusUSD: "500", MMSurplusUSD: "800"}
	if body.FuturesAccount == nil || *body.FuturesAccount != wantAccount {
		t.Fatalf("futures_account = %+v, want %+v", body.FuturesAccount, wantAccount)
	}

	// Flat in the series: nothing listed, and still an array.
	body, raw = getPositions(t, futureServer(t, rpc.URL), "7")
	if body.Futures == nil || len(body.Futures) != 0 || !strings.Contains(raw, `"futures":[]`) {
		t.Fatalf("a flat account lists no futures position: %s", raw)
	}
}

// A long is long USDC: it gains when the naira weakens, and its contracts are positive.
func TestPositionsReportsAFuturesLong(t *testing.T) {
	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": contractsWad(3, 0)}
	rpc := stub.server(t)
	defer rpc.Close()

	body, raw := getPositions(t, futureServer(t, rpc.URL), "42")
	if len(body.Futures) != 1 {
		t.Fatalf("want one futures position, got %s", raw)
	}
	got := body.Futures[0]
	if got.Side != "long" || got.Contracts != "3" || got.NotionalUSDC != "3000" {
		t.Fatalf("3 contracts long is a long of 3 contracts, 3,000 USDC: %s", show(got))
	}
}

// Every listed series is read, each at its own expiry: an account holding two is shown both.
func TestPositionsListsEverySeriesHeld(t *testing.T) {
	const secondExpiry = testFutureExpiry + 28*24*3600
	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": contractsWad(1, 0)}
	stub.more = map[int64]*futureSeriesStub{secondExpiry: {
		lastTrade: time.Now().Add(48 * time.Hour).Unix(), lastMark: testFutureLastMark + 60,
		mark: new(big.Int).Mul(big.NewInt(1450), testWad), positions: map[string]*big.Int{"42": new(big.Int).Neg(contractsWad(4, 0))},
	}}
	rpc := stub.server(t)
	defer rpc.Close()

	server := futureServer(t, rpc.URL)
	var first instruments.Metadata
	for _, market := range server.instruments.Enabled() {
		if market.IsFuture() {
			first = market
		}
	}
	second := first
	second.Symbol, second.DisplayName = instruments.FutureSymbol(secondExpiry), instruments.FutureSymbol(secondExpiry)
	second.SubID, second.ExpiryTimestamp = strconv.FormatInt(secondExpiry, 10), secondExpiry
	server.instruments = instruments.NewRegistry(append(server.instruments.Enabled(), second))
	server.futureSeries = newFutureSeriesReaders(server.cfg, server.instruments, server.future)

	body, raw := getPositions(t, server, "42")
	if len(body.Futures) != 2 {
		t.Fatalf("want both series, got %s", raw)
	}
	bySub := map[string]presentedFuturePosition{}
	for _, position := range body.Futures {
		bySub[position.SubID] = position
	}
	if got := bySub[testFutureSubID]; got.Contracts != "1" || got.MarkPrice != "1400" || got.Market != testFutureSymbol {
		t.Fatalf("first series: %s", show(got))
	}
	if got := bySub[second.SubID]; got.Contracts != "-4" || got.MarkPrice != "1450" || got.Market != second.Symbol {
		t.Fatalf("second series is read at its own expiry: %s", show(got))
	}
}

// A series past last trade but not settled still holds its position, and says it is closing; once
// settled it says so.
func TestPositionsShowsAClosingAndASettledSeries(t *testing.T) {
	for _, tc := range []struct {
		name    string
		settled bool
		want    string
	}{
		{"past last trade, not settled", false, futureStatusClosing},
		{"settled", true, futureStatusSettled},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stub := newFutureRPC()
			stub.lastTrade = time.Now().Add(-time.Minute).Unix()
			stub.settled = tc.settled
			stub.positions = map[string]*big.Int{"42": contractsWad(1, 0)}
			rpc := stub.server(t)
			defer rpc.Close()

			body, raw := getPositions(t, futureServer(t, rpc.URL), "42")
			if len(body.Futures) != 1 || body.Futures[0].Status != tc.want {
				t.Fatalf("want one position, status %q: %s", tc.want, raw)
			}
		})
	}
}

// Variation margin accrued at a new mark and not yet settled is the chain's getPendingVM for the
// account and series, signed: a 2.5 contract short through a 50 cNGN rise owes 125,000 cNGN.
func TestPositionsShowsPendingVMAfterAMarkWithNoSettlement(t *testing.T) {
	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": new(big.Int).Neg(contractsWad(2, 5))}
	stub.mark = new(big.Int).Mul(big.NewInt(1450), testWad)
	stub.lastMark = testFutureLastMark + 3600
	stub.pendingVM = map[string]*big.Int{"42": new(big.Int).Mul(big.NewInt(-125_000), testWad), "43": big.NewInt(1)}
	rpc := stub.server(t)
	defer rpc.Close()

	body, raw := getPositions(t, futureServer(t, rpc.URL), "42")
	if len(body.Futures) != 1 {
		t.Fatalf("want one position: %s", raw)
	}
	got := body.Futures[0]
	if got.PendingVMCNGN != "-125000" || got.MarkPrice != "1450" || got.MarkUpdatedAt == nil || got.MarkUpdatedAt.Unix() != testFutureLastMark+3600 {
		t.Fatalf("pending VM is the account's own, at the new mark: %s", show(got))
	}
}

// A futures read that fails leaves its own fields out: absent is unknown, never zero, and the rest of
// the response is still served.
func TestPositionsLeavesOutWhatItCouldNotRead(t *testing.T) {
	for _, tc := range []struct {
		name  string
		fail  string
		check func(t *testing.T, body positionsBody, raw string)
	}{
		{"pending vm", "0x22b97c45", func(t *testing.T, body positionsBody, raw string) {
			if strings.Contains(raw, "pending_vm_cngn") || body.Futures[0].Contracts != "-2.5" || body.Futures[0].MarkPrice != "1400" {
				t.Fatalf("pending VM absent, the rest present: %s", raw)
			}
		}},
		{"series state", "0xc3c74b34", func(t *testing.T, body positionsBody, raw string) {
			got := body.Futures[0]
			if got.Status != "" || got.MarkPrice != "" || got.MarkUpdatedAt != nil || got.Contracts != "-2.5" || got.PendingVMCNGN != "0" {
				t.Fatalf("status and mark absent, the rest present: %s", raw)
			}
		}},
		{"position", "0x0806e640", func(t *testing.T, body positionsBody, raw string) {
			got := body.Futures[0]
			if got.Market != testFutureSymbol || got.SubID != testFutureSubID || got.Contracts != "" || got.Side != "" || got.NotionalUSDC != "" {
				t.Fatalf("the series is listed with its position absent: %s", raw)
			}
		}},
		{"margin", "0x623bb445", func(t *testing.T, body positionsBody, raw string) {
			if body.FuturesAccount == nil || body.FuturesAccount.IMSurplusUSD != "" || body.FuturesAccount.MMSurplusUSD != "" {
				t.Fatalf("surpluses absent: %s", raw)
			}
			if strings.Contains(raw, "surplus_usd") || body.Futures[0].Contracts != "-2.5" {
				t.Fatalf("surpluses absent, position present: %s", raw)
			}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			stub := newFutureRPC()
			stub.positions = map[string]*big.Int{"42": new(big.Int).Neg(contractsWad(2, 5))}
			stub.fail = map[string]bool{tc.fail: true}
			rpc := stub.server(t)
			defer rpc.Close()

			body, raw := getPositions(t, futureServer(t, rpc.URL), "42")
			if len(body.Futures) != 1 {
				t.Fatalf("want the series listed: %s", raw)
			}
			tc.check(t, body, raw)
		})
	}
}

// An account under another manager has no futures margin to show.
func TestPositionsOmitsTheFuturesAccountUnderAnotherManager(t *testing.T) {
	stub := newFutureRPC()
	stub.managers = map[string]string{"42": "0x00000000000000000000000000000000000000aa"}
	rpc := stub.server(t)
	defer rpc.Close()

	_, raw := getPositions(t, futureServer(t, rpc.URL), "42")
	if strings.Contains(raw, "futures_account") {
		t.Fatalf("an account under another manager has no futures_account: %s", raw)
	}
}

// The perp keys keep the shape they had: empty arrays (not absent, not null) when no perp is
// configured, whether or not a future is.
func TestPositionsKeepsThePerpKeysWithoutAPerp(t *testing.T) {
	rec := httptest.NewRecorder()
	(&Server{}).handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	if got := strings.TrimSpace(rec.Body.String()); rec.Code != http.StatusOK || got != `{"accounts":[],"futures":[],"positions":[]}` {
		t.Fatalf("nothing configured: %d %s", rec.Code, got)
	}

	stub := newFutureRPC()
	rpc := stub.server(t)
	defer rpc.Close()
	_, raw := getPositions(t, futureServer(t, rpc.URL), "42")
	if !strings.Contains(raw, `"positions":[]`) || !strings.Contains(raw, `"accounts":[]`) {
		t.Fatalf("a future without a perp: %s", raw)
	}
}

func futurePositionEqual(a, b presentedFuturePosition) bool {
	if (a.MarkUpdatedAt == nil) != (b.MarkUpdatedAt == nil) || (a.MarkUpdatedAt != nil && !a.MarkUpdatedAt.Equal(*b.MarkUpdatedAt)) {
		return false
	}
	a.MarkUpdatedAt, b.MarkUpdatedAt = nil, nil
	return a == b
}

func show(v any) string {
	out, _ := json.Marshal(v)
	return string(out)
}

// deadRPC is a chain endpoint that refuses every connection.
func deadRPC(t *testing.T) string {
	t.Helper()
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()
	return dead.URL
}

// A perp read that fails does not hide the futures: they are served, and the perp keys are absent
// (not empty, which would say the account is flat) with the failure named in perp_error.
func TestPositionsServesTheFuturesWhenThePerpCannotBeRead(t *testing.T) {
	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": new(big.Int).Neg(contractsWad(2, 5))}
	rpc := stub.server(t)
	defer rpc.Close()

	server := perpAndFutureServer(t, deadRPC(t), rpc.URL)

	body, raw := getPositions(t, server, "42")
	if len(body.Futures) != 1 || body.Futures[0].Contracts != "-2.5" || body.FuturesAccount == nil {
		t.Fatalf("the futures are served despite the perp: %s", raw)
	}
	if strings.Contains(raw, `"positions"`) || strings.Contains(raw, `"accounts"`) {
		t.Fatalf("the perp keys are absent, not empty, when the perp could not be read: %s", raw)
	}
	// With the chain unreachable the first perp read to fail is the account's manager.
	if !strings.Contains(raw, `"perp_error":"could not read the account's manager from chain"`) {
		t.Fatalf("the perp failure is named: %s", raw)
	}
}

// With no future listed a perp failure leaves nothing to serve, and it is the 502 it always was.
func TestPositionsIsA502WhenThePerpCannotBeReadAndNoFutureIsListed(t *testing.T) {
	server := perpServer(t, deadRPC(t))
	rec := httptest.NewRecorder()
	server.handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	if rec.Code != http.StatusBadGateway || !strings.Contains(rec.Body.String(), "could not read the account's manager from chain") {
		t.Fatalf("want the 502 as before, got %d %s", rec.Code, rec.Body.String())
	}
}

// perpAndFutureServer lists the perp, read at perpRPC, beside the future, read at futureRPC.
func perpAndFutureServer(t *testing.T, perpRPC, futureRPC string) *Server {
	t.Helper()
	cfg := futureConfig(futureRPC)
	cfg.MatchingAddress = "0x1111111111111111111111111111111111111111"
	cfg.CNGNPerpAssetAddress, cfg.CNGNPerpSRMAddress = testPerpAsset, testPerpSRM
	registry := instruments.DefaultRegistry(cfg)
	future := newFutureStateReader(cfg)
	perpCfg := cfg
	perpCfg.ChainRPCURL = perpRPC
	perpListed := false
	for _, market := range registry.Enabled() {
		perpListed = perpListed || market.IsPerpetual()
	}
	if !perpListed {
		t.Fatal("the registry lists no perp, so its read is never attempted")
	}
	return &Server{cfg: cfg, instruments: registry, perp: newPerpStateReader(perpCfg), future: future,
		futureSeries: newFutureSeriesReaders(cfg, registry, future)}
}

// An RPC URL carries its provider's API key (Alchemy: /v2/<key>), and Go's HTTP client puts the URL in
// its errors. A failed perp read must log that detail on the server and never put it in the response:
// perp_error and the 502 are fixed messages. The log is checked too, so the test cannot pass because
// the error happened not to carry the URL.
func TestPositionsNeverPutsTheRPCURLInTheResponse(t *testing.T) {
	const key = "alch_TESTKEY_must_not_leak_0123456789"
	keyed := deadRPC(t) + "/v2/" + key

	var logs bytes.Buffer
	previous := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&logs, nil)))
	t.Cleanup(func() { slog.SetDefault(previous) })

	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": contractsWad(1, 0)}
	rpc := stub.server(t)
	defer rpc.Close()

	_, withFutures := getPositions(t, perpAndFutureServer(t, keyed, rpc.URL), "42")
	if !strings.Contains(withFutures, `"perp_error"`) {
		t.Fatalf("the perp read was meant to fail: %s", withFutures)
	}

	rec := httptest.NewRecorder()
	perpServer(t, keyed).handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("want the 502 without a future, got %d %s", rec.Code, rec.Body.String())
	}

	for name, body := range map[string]string{"200 with futures": withFutures, "502": rec.Body.String()} {
		if strings.Contains(body, key) || strings.Contains(body, "/v2/") || strings.Contains(body, "127.0.0.1") {
			t.Fatalf("%s response carries the RPC URL: %s", name, body)
		}
	}
	if !strings.Contains(logs.String(), key) {
		t.Fatalf("the failure was not logged with its detail, or the error did not carry the URL; logs:\n%s", logs.String())
	}
}

// moveAccount puts subaccount 42 under manager for one test, and optionally fails any SRM margin read.
func moveAccount(t *testing.T, manager string, forbidSRM bool) {
	t.Helper()
	stubManagerOf["42"] = manager
	stubForbidSRMReads = forbidSRM
	t.Cleanup(func() { delete(stubManagerOf, "42"); stubForbidSRMReads = false })
}

// A futures holder sits under the MarginEngine, not the perp's SRM: it has no perp account, so the perp
// keys are empty, not an error, and the SRM is never asked to price it (that read reverts on chain for an
// account holding a dated future, which is how every futures holder got perp_error).
func TestPositionsSkipsThePerpForAFuturesHolderUnderTheEngine(t *testing.T) {
	moveAccount(t, testFutureEngine, true)
	perpRPC := stubPerpRPC(t, big.NewInt(0))
	defer perpRPC.Close()
	stub := newFutureRPC()
	stub.positions = map[string]*big.Int{"42": contractsWad(3, 0)}
	rpc := stub.server(t)
	defer rpc.Close()

	body, raw := getPositions(t, perpAndFutureServer(t, perpRPC.URL, rpc.URL), "42")
	if strings.Contains(raw, "perp_error") {
		t.Fatalf("an account the perp's SRM does not manage is not a perp read failure: %s", raw)
	}
	if body.Positions == nil || len(body.Positions) != 0 || body.Accounts == nil || len(body.Accounts) != 0 {
		t.Fatalf("the perp keys are present and empty: %s", raw)
	}
	if len(body.Futures) != 1 || body.Futures[0].Contracts != "3" || body.FuturesAccount == nil {
		t.Fatalf("the futures are served: %s", raw)
	}
}

// The same for a flat account under the engine, with no future listed: a 200 with empty perp keys.
func TestPositionsIsEmptyForAnAccountUnderAnotherManager(t *testing.T) {
	moveAccount(t, testFutureEngine, true)
	rpc := stubPerpRPC(t, big.NewInt(0))
	defer rpc.Close()
	rec := httptest.NewRecorder()
	perpServer(t, rpc.URL).handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	if got := strings.TrimSpace(rec.Body.String()); rec.Code != http.StatusOK || got != `{"accounts":[],"futures":[],"positions":[]}` {
		t.Fatalf("want an empty 200, got %d %s", rec.Code, got)
	}
}

// An account under the close-only manager (the SRM its accounts are moving off) can still hold the perp.
func TestPositionsReadsThePerpUnderTheCloseOnlyManager(t *testing.T) {
	const closeOnly = "0x9999999999999999999999999999999999999999"
	moveAccount(t, closeOnly, false)
	rpc := stubPerpRPC(t, e18Int(10_000_000))
	defer rpc.Close()
	server := perpServer(t, rpc.URL)
	server.cfg.CNGNPerpCloseOnlyManager = closeOnly
	rec := httptest.NewRecorder()
	server.handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	var body positionsBody
	_ = json.Unmarshal(rec.Body.Bytes(), &body)
	if rec.Code != http.StatusOK || len(body.Positions) != 1 || len(body.Accounts) != 1 {
		t.Fatalf("an account under the close-only manager is read: %d %s", rec.Code, rec.Body.String())
	}
}

// Failing to read the manager is a real read failure: perp_error beside the futures, a 502 without them.
func TestPositionsReportsAFailedManagerRead(t *testing.T) {
	moveAccount(t, "fail", false)
	perpRPC := stubPerpRPC(t, big.NewInt(0))
	defer perpRPC.Close()
	stub := newFutureRPC()
	rpc := stub.server(t)
	defer rpc.Close()

	_, raw := getPositions(t, perpAndFutureServer(t, perpRPC.URL, rpc.URL), "42")
	if !strings.Contains(raw, `"perp_error":"could not read the account's manager from chain"`) || strings.Contains(raw, `"positions"`) {
		t.Fatalf("a failed manager read is a perp_error with the perp keys absent: %s", raw)
	}
	rec := httptest.NewRecorder()
	perpServer(t, perpRPC.URL).handlePositions(rec, httptest.NewRequest(http.MethodGet, "/v1/positions?subaccount_id=42", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("without a future it is the 502: %d %s", rec.Code, rec.Body.String())
	}
}
