package matching

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

func TestBuildExecutorRequest(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-1",
			OwnerAddress:  "0x1111111111111111111111111111111111111111",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			SubaccountID:  "10",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"0x1111111111111111111111111111111111111111","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
			Nonce:         "1",
		},
		Maker: orders.Order{
			OrderID:       "maker-1",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "11",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"11","nonce":"2","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
			Nonce:         "2",
		},
	}

	req, err := buildExecutorRequest("USDCcNGN-SPOT", candidate, "0xfeed", "75", "3")
	if err != nil {
		t.Fatalf("buildExecutorRequest returned error: %v", err)
	}

	if req.TakerOrderID != "taker-1" {
		t.Fatalf("taker order id = %s", req.TakerOrderID)
	}
	if req.MakerOrderID != "maker-1" {
		t.Fatalf("maker order id = %s", req.MakerOrderID)
	}
	if len(req.Actions) != 2 {
		t.Fatalf("actions length = %d", len(req.Actions))
	}
	if req.OrderData.TakerAccount != "10" {
		t.Fatalf("taker account = %s", req.OrderData.TakerAccount)
	}
	if req.OrderData.FillDetails[0].FilledAccount != "11" {
		t.Fatalf("filled account = %s", req.OrderData.FillDetails[0].FilledAccount)
	}
	if req.OrderData.FillDetails[0].Price != "75" {
		t.Fatalf("price = %s", req.OrderData.FillDetails[0].Price)
	}
	if req.OrderData.ManagerData != "0xfeed" {
		t.Fatalf("manager data = %s", req.OrderData.ManagerData)
	}
}

func TestBuildExecutorRequestForSpotMarket(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-future",
			OwnerAddress:  "0x1111111111111111111111111111111111111111",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0x3333333333333333333333333333333333333333",
			SubaccountID:  "601",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"601","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"0x1111111111111111111111111111111111111111","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
			Nonce:         "1",
		},
		Maker: orders.Order{
			OrderID:       "maker-future",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "602",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"602","nonce":"2","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
			Nonce:         "2",
		},
	}

	req, err := buildExecutorRequest("USDCcNGN-SPOT", candidate, "0x", "1602", "3000000")
	if err != nil {
		t.Fatalf("buildExecutorRequest returned error: %v", err)
	}

	if req.Market != "USDCcNGN-SPOT" {
		t.Fatalf("market = %s", req.Market)
	}
	if req.AssetAddress != "0x3333333333333333333333333333333333333333" {
		t.Fatalf("asset address = %s", req.AssetAddress)
	}
	if req.OrderData.FillDetails[0].Price != "1602" || req.OrderData.FillDetails[0].AmountFilled != "3000000" {
		t.Fatalf("unexpected fill details %+v", req.OrderData.FillDetails[0])
	}
}

func TestBuildExecutorRequestRejectsActionOwnerMismatch(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-1",
			OwnerAddress:  "0x1111111111111111111111111111111111111111",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			SubaccountID:  "10",
			Nonce:         "1",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"0x5555555555555555555555555555555555555555","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
		},
		Maker: orders.Order{
			OrderID:       "maker-1",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "11",
			Nonce:         "2",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"11","nonce":"2","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
		},
	}

	_, err := buildExecutorRequest("USDCcNGN-SPOT", candidate, "0x", "75", "3")
	if err == nil || err.Error() != "parse taker action_json: owner mismatch" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBuildExecutorRequestDefaultsEmptyManagerData(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-1",
			OwnerAddress:  "0x1111111111111111111111111111111111111111",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			SubaccountID:  "10",
			Nonce:         "1",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"0x1111111111111111111111111111111111111111","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
		},
		Maker: orders.Order{
			OrderID:       "maker-1",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "11",
			Nonce:         "2",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"11","nonce":"2","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
		},
	}

	req, err := buildExecutorRequest("USDCcNGN-SPOT", candidate, "", "75", "3")
	if err != nil {
		t.Fatalf("buildExecutorRequest returned error: %v", err)
	}
	if req.OrderData.ManagerData != "0x" {
		t.Fatalf("manager data = %s", req.OrderData.ManagerData)
	}
}

func TestBuildExecutorRequestRejectsNonAddressActionOwner(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-1",
			OwnerAddress:  "owner-not-address",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			SubaccountID:  "10",
			Nonce:         "1",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"owner-not-address","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
		},
		Maker: orders.Order{
			OrderID:       "maker-1",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "11",
			Nonce:         "2",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"11","nonce":"2","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
		},
	}

	_, err := buildExecutorRequest("USDCcNGN-SPOT", candidate, "0x", "75", "3")
	if err == nil || err.Error() != "parse taker action_json: owner must be a 20-byte 0x address" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBuildExecutorRequestRejectsMismatchedActionModules(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-1",
			OwnerAddress:  "0x1111111111111111111111111111111111111111",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			SubaccountID:  "10",
			Nonce:         "1",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"0x1111111111111111111111111111111111111111","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
		},
		Maker: orders.Order{
			OrderID:       "maker-1",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "11",
			Nonce:         "2",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"11","nonce":"2","module":"0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
		},
	}

	_, err := buildExecutorRequest("USDCcNGN-SPOT", candidate, "0x", "75", "3")
	if err == nil || err.Error() != "maker module address mismatch: taker=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa maker=0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Fatalf("unexpected error: %v", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}

// testCandidate is a minimal well-formed pair: enough for buildExecutorRequest to
// succeed so the tests below exercise response handling rather than validation.
func testCandidate() orders.MatchCandidate {
	return orders.MatchCandidate{
		Taker: orders.Order{
			OrderID:       "taker-1",
			OwnerAddress:  "0x1111111111111111111111111111111111111111",
			SignerAddress: "0x3333333333333333333333333333333333333333",
			AssetAddress:  "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
			SubaccountID:  "10",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xaaa","expiry":"100","owner":"0x1111111111111111111111111111111111111111","signer":"0x3333333333333333333333333333333333333333"}`),
			Signature:     "0x01",
			Nonce:         "1",
		},
		Maker: orders.Order{
			OrderID:       "maker-1",
			OwnerAddress:  "0x2222222222222222222222222222222222222222",
			SignerAddress: "0x4444444444444444444444444444444444444444",
			SubaccountID:  "11",
			ActionJSON:    json.RawMessage(`{"subaccount_id":"11","nonce":"2","module":"0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","data":"0xbbb","expiry":"100","owner":"0x2222222222222222222222222222222222222222","signer":"0x4444444444444444444444444444444444444444"}`),
			Signature:     "0x02",
			Nonce:         "2",
		},
	}
}

func submitAgainstBody(t *testing.T, body string) (ExecutorResponse, error) {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(server.Close)

	client := NewExecutorClient(server.URL, "0xfeed", 5*time.Second)
	return client.SubmitMatchForMarket(context.Background(), "USDCcNGN-SPOT", testCandidate(), "75", "3")
}

// A transaction that mined and reverted moved nothing on chain. It must not reach
// the caller as a success, or the matcher records a fill that settlement never made.
func TestSubmitMatchRejectsRevertedReceipt(t *testing.T) {
	resp, err := submitAgainstBody(t, `{"accepted":false,"tx_hash":"0xdead","receipt_status":"reverted","block_number":"42"}`)
	if err == nil {
		t.Fatalf("expected an error for a reverted receipt, got response %+v", resp)
	}
	if !strings.Contains(err.Error(), "reverted") {
		t.Fatalf("error should name the receipt status, got %q", err)
	}
	if !strings.Contains(err.Error(), "0xdead") {
		t.Fatalf("error should name the transaction, got %q", err)
	}

	// The reconciliation path finalizes only for TM_FillLimitCrossed, which means an
	// already-settled fill. A revert is the opposite and must not take that branch.
	if shouldFinalizeAfterExecutorError(err) {
		t.Fatal("a reverted transaction must not be reconciled as a completed fill")
	}
}

func TestSubmitMatchAcceptsSuccessfulReceipt(t *testing.T) {
	resp, err := submitAgainstBody(t, `{"accepted":true,"tx_hash":"0xbeef","receipt_status":"success","block_number":"43"}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resp.Accepted {
		t.Fatal("accepted should be true")
	}
	if resp.ReceiptStatus != "success" || resp.BlockNumber != "43" {
		t.Fatalf("receipt fields dropped: %+v", resp)
	}
}

// The older execution-service replied {} to mean "submitted, not waiting". With no
// transaction hash there is nothing on chain to contradict, so this stays accepted.
func TestSubmitMatchKeepsLegacyEmptyAcceptance(t *testing.T) {
	resp, err := submitAgainstBody(t, `{}`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resp.Accepted {
		t.Fatal("an empty response should still count as accepted")
	}
}

func TestNewExecutorClientTimeout(t *testing.T) {
	if got := NewExecutorClient("http://x", "0x", 90*time.Second).httpClient.Timeout; got != 90*time.Second {
		t.Fatalf("timeout = %v, want 90s", got)
	}
	if got := NewExecutorClient("http://x", "0x", 0).httpClient.Timeout; got != 5*time.Second {
		t.Fatalf("zero timeout should fall back to 5s, got %v", got)
	}
}
