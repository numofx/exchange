package api

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

func TestCreateOrderRequestToParamsRejectsActionJSONOwnerMismatch(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-1",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xdef",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xasset",
		SubID:         "0",
		DesiredAmount: "100",
		FilledAmount:  "0",
		LimitPrice:    "75",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xwrong","signer":"0xdef"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{})
	if err == nil || err.Error() != "action_json.owner must match owner_address" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsRejectsUnexpectedConfiguredSigner(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-1",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xdef",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xasset",
		SubID:         "0",
		DesiredAmount: "100",
		FilledAmount:  "0",
		LimitPrice:    "75",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xdef"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{ExpectedOrderSigner: "0x123"})
	if err == nil || err.Error() != "signer_address must match configured expected signer" {
		t.Fatalf("unexpected error: %v", err)
	}
}





func TestCreateOrderRequestToParamsNormalizesJUNMinimumSizeToAtomicUnits(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-apr-min-size",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xabc",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xapr",
		SubID:         "1782777600",
		DesiredAmount: "0.001",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xabc"}`),
		Signature:     "0xsig",
	}

	params, err := req.toParams(config.Config{
		CNGNJun2026FutureAssetAddress: "0xapr",
		CNGNJun2026FutureSubID:        "1782777600",
	})
	if err != nil {
		t.Fatalf("toParams returned error: %v", err)
	}
	if params.DesiredAmount != "1" {
		t.Fatalf("desired amount = %s", params.DesiredAmount)
	}
	if params.FilledAmount != "0" {
		t.Fatalf("filled amount = %s", params.FilledAmount)
	}
}

func TestCreateOrderRequestToParamsRejectsJUNSubMinimumSize(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-apr-sub-min-size",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xabc",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xapr",
		SubID:         "1782777600",
		DesiredAmount: "0.0001",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xabc"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{
		CNGNJun2026FutureAssetAddress: "0xapr",
		CNGNJun2026FutureSubID:        "1782777600",
	})
	if err == nil || err.Error() != "desired_amount must align to amount step 0.001" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsRejectsZeroNormalizedAtomicSize(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-apr-zero-size",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xabc",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xapr",
		SubID:         "1782777600",
		DesiredAmount: "0",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xabc"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{
		CNGNJun2026FutureAssetAddress: "0xapr",
		CNGNJun2026FutureSubID:        "1782777600",
	})
	if err == nil || err.Error() != "normalized atomic size is 0" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsEnforcesActionDataScaleInvariant(t *testing.T) {
	asset := "0xce2846771074e20fec739cf97a60e6075d1e464b"
	req := createOrderRequest{
		OrderID:       "order-apr-scale-check",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "7",
		RecipientID:   "7",
		Nonce:         "11",
		Side:          "buy",
		AssetAddress:  asset,
		SubID:         "1782777600",
		DesiredAmount: "0.001",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"7",
			"nonce":"11",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(asset, "1782777600", "1391000000000000000000", "1000000000000000", true) + `",
			"expiry":"1782777600",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}

	params, err := req.toParams(config.Config{
		CNGNJun2026FutureAssetAddress: asset,
		CNGNJun2026FutureSubID:        "1782777600",
		EnforceActionDataInvariants:   true,
	})
	if err != nil {
		t.Fatalf("toParams returned error: %v", err)
	}
	if params.LimitPriceTicks != "1391" || params.DesiredAmount != "1" {
		t.Fatalf("unexpected normalized params %+v", params)
	}
}

func TestCreateOrderRequestToParamsRejectsActionDataScaleMismatch(t *testing.T) {
	asset := "0xce2846771074e20fec739cf97a60e6075d1e464b"
	req := createOrderRequest{
		OrderID:       "order-apr-scale-mismatch",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "7",
		RecipientID:   "7",
		Nonce:         "12",
		Side:          "buy",
		AssetAddress:  asset,
		SubID:         "1782777600",
		DesiredAmount: "0.002",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"7",
			"nonce":"12",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(asset, "1782777600", "1391000000000000000000", "1000000000000001", true) + `",
			"expiry":"1782777600",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}

	_, err := req.toParams(config.Config{
		CNGNJun2026FutureAssetAddress: asset,
		CNGNJun2026FutureSubID:        "1782777600",
		EnforceActionDataInvariants:   true,
	})
	if err == nil || err.Error() != "action_json.data.desiredAmount is not aligned with normalized desired_amount" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsAcceptsMarketMakerRawDesiredAmountPayload(t *testing.T) {
	asset := "0xce2846771074e20fec739cf97a60e6075d1e464b"
	req := createOrderRequest{
		OrderID:       "order-apr-mm-raw-desired",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "6",
		RecipientID:   "6",
		Nonce:         "13",
		Side:          "buy",
		AssetAddress:  asset,
		SubID:         "1782777600",
		DesiredAmount: "5000000000000000000",
		FilledAmount:  "0",
		LimitPrice:    "1355",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"6",
			"nonce":"13",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(asset, "1782777600", "1355000000000000000000", "5000000000000000000", true) + `",
			"expiry":"1782777600",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}

	params, err := req.toParams(config.Config{
		CNGNJun2026FutureAssetAddress: asset,
		CNGNJun2026FutureSubID:        "1782777600",
		EnforceActionDataInvariants:   true,
	})
	if err != nil {
		t.Fatalf("toParams returned error: %v", err)
	}
	if params.LimitPriceTicks != "1355" {
		t.Fatalf("limit_price_ticks = %s", params.LimitPriceTicks)
	}
	if params.DesiredAmount != "5000000000000000000000" {
		t.Fatalf("desired_amount = %s", params.DesiredAmount)
	}
}

func mustTradeDataHex(asset string, subID string, limitPrice string, desiredAmount string, isBid bool) string {
	var out []byte
	out = append(out, encodeAddressWord(asset)...)
	out = append(out, encodeUnsignedWord(subID)...)
	out = append(out, encodeSignedWord(limitPrice)...)
	out = append(out, encodeSignedWord(desiredAmount)...)
	out = append(out, encodeUnsignedWord("0")...)
	out = append(out, encodeUnsignedWord("7")...)
	if isBid {
		out = append(out, encodeUnsignedWord("1")...)
	} else {
		out = append(out, encodeUnsignedWord("0")...)
	}
	return "0x" + hex.EncodeToString(out)
}

func encodeAddressWord(address string) []byte {
	raw, _ := hex.DecodeString(address[2:])
	word := make([]byte, 32)
	copy(word[12:], raw)
	return word
}

func encodeUnsignedWord(value string) []byte {
	n, _ := new(big.Int).SetString(value, 10)
	word := make([]byte, 32)
	bytes := n.Bytes()
	copy(word[32-len(bytes):], bytes)
	return word
}

func encodeSignedWord(value string) []byte {
	n, _ := new(big.Int).SetString(value, 10)
	if n.Sign() < 0 {
		mod := new(big.Int).Lsh(big.NewInt(1), 256)
		n = n.Add(n, mod)
	}
	word := make([]byte, 32)
	bytes := n.Bytes()
	copy(word[32-len(bytes):], bytes)
	return word
}
