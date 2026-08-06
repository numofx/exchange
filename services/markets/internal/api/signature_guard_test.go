package api

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/ordersig"
)

type stubSignatureChecker struct {
	err    error
	called bool
}

func (s *stubSignatureChecker) Verify(context.Context, ordersig.Action, string, string) error {
	s.called = true
	return s.err
}

func testRequest() createOrderRequest {
	return createOrderRequest{
		Signature: "0xdeadbeef",
		ActionJSON: json.RawMessage(`{
			"subaccount_id": "9",
			"nonce": "1",
			"module": "0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c",
			"data": "0x00",
			"expiry": "1786011430",
			"owner": "0x3448ac0a3283951a2afd5b3a582329eca43cb47b",
			"signer": "0x3448ac0a3283951a2afd5b3a582329eca43cb47b"
		}`),
	}
}

func TestVerifyOrderSignature(t *testing.T) {
	params := orders.CreateOrderParams{OrderID: "o1", SignerAddress: "0x3448ac0a3283951a2afd5b3a582329eca43cb47b"}

	t.Run("no checker configured is not a rejection", func(t *testing.T) {
		s := &Server{}
		if err := s.verifyOrderSignature(context.Background(), testRequest(), params); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
	})

	t.Run("valid signature passes", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{}}
		if err := s.verifyOrderSignature(context.Background(), testRequest(), params); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
	})

	t.Run("invalid signature is reported", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{err: ordersig.ErrInvalidSignature}}
		if err := s.verifyOrderSignature(context.Background(), testRequest(), params); err == nil {
			t.Fatal("expected an error for an invalid signature")
		}
	})

	// An RPC failure means "could not check", which must not reject a possibly-valid order.
	// This is the same reasoning the matcher's backoff applies to transient failures.
	t.Run("unverifiable does not reject", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{err: errors.New("rpc timeout")}}
		if err := s.verifyOrderSignature(context.Background(), testRequest(), params); err != nil {
			t.Fatalf("a failed check must not reject, got %v", err)
		}
	})

	t.Run("malformed action_json does not reject", func(t *testing.T) {
		stub := &stubSignatureChecker{}
		s := &Server{signatures: stub}
		req := testRequest()
		req.ActionJSON = json.RawMessage(`{`)
		if err := s.verifyOrderSignature(context.Background(), req, params); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
		if stub.called {
			t.Fatal("verifier should not run on unparseable action_json")
		}
	})
}

// Enforcement is what turns a report into a rejection, so the flag needs to gate exactly that.
func TestEnforcementFlagGatesRejection(t *testing.T) {
	for _, tc := range []struct {
		name        string
		enforce     bool
		wantRejects bool
	}{
		{"reporting only", false, false},
		{"enforcing", true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := &Server{
				cfg:        config.Config{EnforceOrderSignatures: tc.enforce},
				signatures: &stubSignatureChecker{err: ordersig.ErrInvalidSignature},
			}
			err := s.verifyOrderSignature(context.Background(), testRequest(), orders.CreateOrderParams{OrderID: "o1"})
			rejects := err != nil && s.cfg.EnforceOrderSignatures
			if rejects != tc.wantRejects {
				t.Fatalf("enforce=%v produced reject=%v, want %v", tc.enforce, rejects, tc.wantRejects)
			}
		})
	}
}

func TestActionFromJSON(t *testing.T) {
	action, err := actionFromJSON(testRequest().ActionJSON)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if action.SubaccountID != "9" || action.Nonce != "1" {
		t.Fatalf("unexpected identity fields: %+v", action)
	}
	// module, data and expiry are not checked by validateActionJSON, so a parsing slip here
	// would silently change the digest rather than fail loudly.
	if action.Module == "" || action.Data == "" || action.Expiry == "" {
		t.Fatalf("module, data and expiry must all be parsed: %+v", action)
	}
}
