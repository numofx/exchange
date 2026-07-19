package matching

import (
	"encoding/json"
	"net/http"
	"testing"

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

	req, err := buildExecutorRequest("USDCcNGN-SEP16-2026", candidate, "0xfeed", "75", "3")
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



func TestBuildExecutorRequestForFutureMarket(t *testing.T) {
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

	req, err := buildExecutorRequest("USDCcNGN-SEP16-2026", candidate, "0x", "1602", "3000000")
	if err != nil {
		t.Fatalf("buildExecutorRequest returned error: %v", err)
	}

	if req.Market != "USDCcNGN-SEP16-2026" {
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

	_, err := buildExecutorRequest("USDCcNGN-SEP16-2026", candidate, "0x", "75", "3")
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

	req, err := buildExecutorRequest("USDCcNGN-SEP16-2026", candidate, "", "75", "3")
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

	_, err := buildExecutorRequest("USDCcNGN-SEP16-2026", candidate, "0x", "75", "3")
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

	_, err := buildExecutorRequest("USDCcNGN-SEP16-2026", candidate, "0x", "75", "3")
	if err == nil || err.Error() != "maker module address mismatch: taker=0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa maker=0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
		t.Fatalf("unexpected error: %v", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(req *http.Request) (*http.Response, error) {
	return f(req)
}
