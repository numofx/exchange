package api

import (
	"encoding/json"
	"strings"
	"testing"
)

const (
	cashQuoteModule    = "0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c"
	wrappedQuoteModule = "0x1111111111111111111111111111111111111111"
)

func actionForModule(module string) json.RawMessage {
	return json.RawMessage(`{
		"subaccount_id": "9",
		"nonce": "1",
		"module": "` + module + `",
		"data": "0x00",
		"expiry": "1786011430",
		"owner": "0x3448ac0a3283951a2afd5b3a582329eca43cb47b",
		"signer": "0x3448ac0a3283951a2afd5b3a582329eca43cb47b"
	}`)
}

// A venue settles on exactly one TradeModule. Orders naming any other one cannot settle here and
// must not be allowed to rest -- see validateActionModule for why the on-chain rejection is not
// enough on its own.
func TestValidateActionModulePinsTheConfiguredModule(t *testing.T) {
	if err := validateActionModule(actionForModule(cashQuoteModule), cashQuoteModule); err != nil {
		t.Fatalf("the configured module must be accepted: %v", err)
	}
}

// Address comparison must be case-insensitive: action_json carries an EIP-55 checksummed address,
// config is normalised to lower case, and a case-sensitive compare would reject every real order.
func TestValidateActionModuleIsCaseInsensitive(t *testing.T) {
	if err := validateActionModule(actionForModule(cashQuoteModule), strings.ToLower(cashQuoteModule)); err != nil {
		t.Fatalf("checksummed vs lowercase must match: %v", err)
	}
	if err := validateActionModule(actionForModule(strings.ToLower(cashQuoteModule)), cashQuoteModule); err != nil {
		t.Fatalf("lowercase vs checksummed must match: %v", err)
	}
}

// THE MIGRATION CASE. While both a cash-quoted and a wrapped-quote module are allowlisted on
// chain, the book must not hold orders for both: the matcher only requires the taker and maker to
// agree with each other, so a cross-module pair crosses, is locked into 'matching', and then fails
// downstream -- after the book has already moved.
func TestValidateActionModuleRejectsTheOtherQuoteModule(t *testing.T) {
	err := validateActionModule(actionForModule(cashQuoteModule), wrappedQuoteModule)
	if err == nil {
		t.Fatal("an order for the old cash-quoted module must be rejected by a wrapped-quote venue")
	}
	if !strings.Contains(err.Error(), strings.ToLower(cashQuoteModule)) {
		t.Fatalf("error must name the offending module, got: %v", err)
	}

	// and symmetrically, so neither direction relies on which module happens to be configured
	if err := validateActionModule(actionForModule(wrappedQuoteModule), cashQuoteModule); err == nil {
		t.Fatal("an order for the wrapped-quote module must be rejected by a cash-quoted venue")
	}
}

func TestValidateActionModuleRejectsAMissingModule(t *testing.T) {
	raw := json.RawMessage(`{"subaccount_id":"9","nonce":"1"}`)
	if err := validateActionModule(raw, cashQuoteModule); err == nil {
		t.Fatal("an action with no module must be rejected when a module is configured")
	}
}

// Inert when unconfigured, so dev and test environments are unaffected. Production cannot reach
// this state: config.validateTradeModule refuses to start without TRADE_MODULE_ADDRESS.
func TestValidateActionModuleIsInertWhenUnconfigured(t *testing.T) {
	for _, unset := range []string{"", "   "} {
		if err := validateActionModule(actionForModule(cashQuoteModule), unset); err != nil {
			t.Fatalf("unconfigured module must not reject, got: %v", err)
		}
	}
}
