package api

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// recipientRequest builds an otherwise-valid order so the only thing under test is the
// recipient/subaccount relationship.
func recipientRequest(subaccountID, recipientID string) createOrderRequest {
	return createOrderRequest{
		OrderID:       "order-1",
		OwnerAddress:  "0xabc",
		SignerAddress: "0xabc",
		SubaccountID:  subaccountID,
		RecipientID:   recipientID,
		Nonce:         "1",
		Side:          "buy",
		AssetAddress:  "0xasset",
		SubID:         "0",
		DesiredAmount: "100",
		FilledAmount:  "0",
		LimitPrice:    "75",
		WorstFee:      "0",
		Expiry:        time.Now().Add(time.Hour).Unix(),
		ActionJSON: json.RawMessage(
			`{"subaccount_id":"` + subaccountID + `","nonce":"1","module":"0xtrade","data":"0xaaa",` +
				`"expiry":"100","owner":"0xabc","signer":"0xabc"}`),
		Signature: "0xsig",
	}
}

// A split recipient worked under a CashAsset quote leg and does not under a wrapped one: the
// CREDIT side needs an allowance, and Matching only transfers action.subaccountId accounts to the
// module, so the ask side reverts NotEnoughSubIdOrAssetAllowances. Rejecting at submit turns a
// pair that crosses, reserves both orders, reverts and retries until expiry into a legible 400.
func TestSplitRecipientIsRejectedAtSubmit(t *testing.T) {
	_, err := recipientRequest("15", "16").toParams(config.Config{})
	if err == nil {
		t.Fatal("a recipient that is not the trading account must be rejected at submit")
	}
	for _, want := range []string{"recipient_id", "subaccount_id", "15", "16"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("error must name %q so the caller can fix it: %v", want, err)
		}
	}
}

func TestMatchingRecipientIsAccepted(t *testing.T) {
	if _, err := recipientRequest("15", "15").toParams(config.Config{}); err != nil {
		t.Fatalf("recipient_id == subaccount_id is the normal case, got %v", err)
	}
}
