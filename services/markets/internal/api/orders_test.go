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

func TestCreateOrderRequestToParamsRejectsFractionalAmount(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-fractional-size",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xabc",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xapr",
		SubID:         "0",
		DesiredAmount: "0.0001",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xabc"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{})
	if err == nil || err.Error() != "desired_amount must align to amount step 1" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsRejectsZeroNormalizedAtomicSize(t *testing.T) {
	req := createOrderRequest{
		OrderID:       "order-zero-size",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xabc",
		SubaccountID:  "10",
		RecipientID:   "10",
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xapr",
		SubID:         "0",
		DesiredAmount: "0",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "1",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xtrade","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xabc"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{})
	if err == nil || err.Error() != "normalized atomic size is 0" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsEnforcesActionDataScaleInvariant(t *testing.T) {
	asset := "0xce2846771074e20fec739cf97a60e6075d1e464b"
	req := createOrderRequest{
		OrderID:       "order-scale-check",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "7",
		RecipientID:   "7",
		Nonce:         "11",
		Side:          "buy",
		AssetAddress:  asset,
		SubID:         "0",
		DesiredAmount: "1",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"7",
			"nonce":"11",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(asset, "0", "1391000000000000000000", "1000000000000000", true) + `",
			"expiry":"2000000000",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}

	params, err := req.toParams(config.Config{EnforceActionDataInvariants: true})
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
		OrderID:       "order-scale-mismatch",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "7",
		RecipientID:   "7",
		Nonce:         "12",
		Side:          "buy",
		AssetAddress:  asset,
		SubID:         "0",
		DesiredAmount: "2",
		FilledAmount:  "0",
		LimitPrice:    "1391",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"7",
			"nonce":"12",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(asset, "0", "1391000000000000000000", "1000000000000001", true) + `",
			"expiry":"2000000000",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}

	_, err := req.toParams(config.Config{EnforceActionDataInvariants: true})
	if err == nil || err.Error() != "action_json.data.desiredAmount is not aligned with normalized desired_amount" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestCreateOrderRequestToParamsAcceptsMarketMakerRawDesiredAmountPayload(t *testing.T) {
	asset := "0xce2846771074e20fec739cf97a60e6075d1e464b"
	req := createOrderRequest{
		OrderID:       "order-mm-raw-desired",
		OwnerAddress:  "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SignerAddress: "0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
		SubaccountID:  "6",
		RecipientID:   "6",
		Nonce:         "13",
		Side:          "buy",
		AssetAddress:  asset,
		SubID:         "0",
		DesiredAmount: "5000000000000000000",
		FilledAmount:  "0",
		LimitPrice:    "1355",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(`{
			"subaccount_id":"6",
			"nonce":"13",
			"module":"0x0aae65aaa66fe7f54486cdbd007956d3de611990",
			"data":"` + mustTradeDataHex(asset, "0", "1355000000000000000000", "5000000000000000000", true) + `",
			"expiry":"2000000000",
			"owner":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310",
			"signer":"0xc7be60b228b997c23094ddfdd71e22e2de6c9310"
		}`),
		Signature: "0xsig",
	}

	params, err := req.toParams(config.Config{EnforceActionDataInvariants: true})
	if err != nil {
		t.Fatalf("toParams returned error: %v", err)
	}
	if params.LimitPriceTicks != "1355" {
		t.Fatalf("limit_price_ticks = %s", params.LimitPriceTicks)
	}
	if params.DesiredAmount != "5000000000000000000" {
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

// A second TradeModule exists the moment the USDC leg moves to a wrapped quote asset. An order
// signed for the other module must be refused at submit time, not left to rest and cross and then
// fail at execution-service, where a module mismatch is only a generic executor error and the pair
// is retried until expiry.
func TestValidateActionModule(t *testing.T) {
	const wrappedQuote = "0x0000000000000000000000000000000000000AAA"
	const cashQuote = "0x44813ad30b2ffc1bb2871eed9b19f63c8196ed1c"

	action := func(module string) json.RawMessage {
		return json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"` + module + `","owner":"0xabc","signer":"0xdef"}`)
	}

	if err := validateActionModule(action(wrappedQuote), wrappedQuote); err != nil {
		t.Fatalf("matching module must be accepted: %v", err)
	}
	// case-insensitive: clients checksum-case their addresses
	if err := validateActionModule(action(wrappedQuote), "0x0000000000000000000000000000000000000aaa"); err != nil {
		t.Fatalf("module comparison must be case-insensitive: %v", err)
	}
	if err := validateActionModule(action(cashQuote), wrappedQuote); err == nil {
		t.Fatal("an order signed for the legacy cash-quoted module must be rejected")
	}
	if err := validateActionModule(action(""), wrappedQuote); err == nil {
		t.Fatal("a missing module must be rejected once a module is configured")
	}
	// unset config is how dev and test environments run; the check must not become a wall there
	if err := validateActionModule(action(cashQuote), ""); err != nil {
		t.Fatalf("check must be inert when TRADE_MODULE_ADDRESS is unset: %v", err)
	}
}

func TestCreateOrderRequestToParamsRejectsForeignTradeModule(t *testing.T) {
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
		ActionJSON:    json.RawMessage(`{"subaccount_id":"10","nonce":"1","module":"0xdeadbeef00000000000000000000000000000000","data":"0xaaa","expiry":"100","owner":"0xabc","signer":"0xdef"}`),
		Signature:     "0xsig",
	}

	_, err := req.toParams(config.Config{TradeModuleAddress: "0x0000000000000000000000000000000000000aaa"})
	if err == nil {
		t.Fatal("an order for a foreign trade module must not reach the book")
	}
}
