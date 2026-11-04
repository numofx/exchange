package api

import (
	"bytes"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
)

const rpcLeakKey = "alch_TESTKEY_must_not_leak_0123456789"

func TestPublicErrorMessageRemovesEveryURL(t *testing.T) {
	for _, raw := range []string{
		`read owner: Post "https://base-mainnet.g.alchemy.com/v2/` + rpcLeakKey + `": context deadline exceeded`,
		`dial wss://base-mainnet.g.alchemy.com/v2/` + rpcLeakKey,
		`connect postgres://numo:` + rpcLeakKey + `@db.internal:5432/markets failed`,
	} {
		if got := publicErrorMessage(errors.New(raw)); strings.Contains(got, rpcLeakKey) || strings.Contains(got, "://") {
			t.Errorf("%q kept the URL: %q", raw, got)
		}
	}
	const plain = "subaccount_id 7 is not deposited in matching custody"
	if got := publicErrorMessage(errors.New(plain)); got != plain {
		t.Errorf("a message without a URL changed: %q", got)
	}
}

func custodyRejectionBody(t *testing.T) []byte {
	t.Helper()
	expiry := time.Now().Add(time.Hour).Unix()
	body, err := json.Marshal(map[string]any{
		"order_id": "custody-leak-1", "owner_address": "0xabc", "signer_address": "0xabc", "subaccount_id": "999",
		"recipient_id": "999", "nonce": "1", "side": "buy", "asset_address": "0xf000000000000000000000000000000000000123",
		"sub_id": "0", "desired_amount": "1", "filled_amount": "0", "limit_price": "1", "worst_fee": "0",
		"expiry":      expiry,
		"action_json": map[string]any{"owner": "0xabc", "signer": "0xabc", "subaccount_id": "999", "nonce": "1", "module": "0xtrade", "data": "0xaaa", "expiry": strconv.FormatInt(expiry, 10)},
		"signature":   "0xsig",
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return body
}

// The wiring: POST /orders through the real custody checker, with an RPC that cannot be reached at a keyed URL. This
// is what makers received from production on 2026-11-04, the key in the body of a 400.
func TestAFailedCustodyReadNeverPublishesTheRPCURL(t *testing.T) {
	dead := httptest.NewServer(http.NotFoundHandler())
	dead.Close()

	cfg := config.Config{CNGNSpotAssetAddress: "0xf000000000000000000000000000000000000123"}
	server := NewServer(cfg, nil, instruments.DefaultRegistry(cfg))
	server.custody = &chainCustodyChecker{
		rpcURL:          dead.URL + "/v2/" + rpcLeakKey,
		matchingAddress: "0x1111111111111111111111111111111111111111",
		httpClient:      &http.Client{Timeout: 2 * time.Second},
	}

	rec := httptest.NewRecorder()
	server.handleCreateOrder(rec, httptest.NewRequest(http.MethodPost, "/orders", bytes.NewReader(custodyRejectionBody(t))))

	if strings.Contains(rec.Body.String(), rpcLeakKey) || strings.Contains(rec.Body.String(), "/v2/") {
		t.Fatalf("the answer carries the RPC URL: %s", rec.Body.String())
	}
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503 so the client retries: %s", rec.Code, rec.Body.String())
	}
}

// A subaccount custody does not hold is still a refusal, with its reason, and not a retry.
func TestAnUndepositedAccountIsStillRefused(t *testing.T) {
	cfg := config.Config{CNGNSpotAssetAddress: "0xf000000000000000000000000000000000000123"}
	server := NewServer(cfg, nil, instruments.DefaultRegistry(cfg))
	server.custody = fakeCustodyChecker{allow: map[string]bool{}}

	rec := httptest.NewRecorder()
	server.handleCreateOrder(rec, httptest.NewRequest(http.MethodPost, "/orders", bytes.NewReader(custodyRejectionBody(t))))
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), "not deposited in matching custody") {
		t.Fatalf("the refusal lost its reason: %s", rec.Body.String())
	}
}
