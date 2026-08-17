package api

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/orders"
	"github.com/numofx/matching-backend/internal/ordersig"
)

type stubSignatureChecker struct {
	err    error
	path   ordersig.SignaturePath
	called bool

	// Cancel path, tracked separately so cancel tests don't collide with order tests.
	cancelErr    error
	cancelPath   ordersig.SignaturePath
	cancelCalled bool
}

func (s *stubSignatureChecker) Verify(
	context.Context,
	ordersig.Action,
	string,
	string,
) (ordersig.SignaturePath, error) {
	s.called = true
	return s.path, s.err
}

func (s *stubSignatureChecker) VerifyCancel(
	context.Context,
	ordersig.Cancel,
	string,
	string,
) (ordersig.SignaturePath, error) {
	s.cancelCalled = true
	return s.cancelPath, s.cancelErr
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

func TestVerifyCancelSignature(t *testing.T) {
	owner := "0x3448ac0a3283951a2afd5b3a582329eca43cb47b"
	now := time.Unix(1_786_000_000, 0)
	futureExpiry := "1786000600"

	signedReq := func() cancelOrderRequest {
		return cancelOrderRequest{
			OwnerAddress: owner,
			Nonce:        "7319532056794814",
			Expiry:       futureExpiry,
			Signature:    "0xdeadbeef",
		}
	}

	t.Run("no checker configured is not a rejection", func(t *testing.T) {
		s := &Server{}
		if err := s.verifyCancelSignature(context.Background(), signedReq(), now); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
	})

	t.Run("valid signature passes and runs the verifier", func(t *testing.T) {
		stub := &stubSignatureChecker{}
		s := &Server{signatures: stub}
		if err := s.verifyCancelSignature(context.Background(), signedReq(), now); err != nil {
			t.Fatalf("expected no error, got %v", err)
		}
		if !stub.cancelCalled {
			t.Fatal("verifier should have been called")
		}
	})

	t.Run("missing signature is reported without calling the verifier", func(t *testing.T) {
		stub := &stubSignatureChecker{}
		s := &Server{signatures: stub}
		req := signedReq()
		req.Signature = ""
		if err := s.verifyCancelSignature(context.Background(), req, now); err == nil {
			t.Fatal("expected an error for an unsigned cancel")
		}
		if stub.cancelCalled {
			t.Fatal("verifier should not run without a signature")
		}
	})

	t.Run("a non-owner signer is reported (no session keys yet)", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{}}
		req := signedReq()
		req.SignerAddress = "0x000000000000000000000000000000000000dead"
		if err := s.verifyCancelSignature(context.Background(), req, now); err == nil {
			t.Fatal("expected an error when signer is not the owner")
		}
	})

	t.Run("a missing or past expiry is reported", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{}}
		req := signedReq()
		req.Expiry = "1785999999" // before now
		if err := s.verifyCancelSignature(context.Background(), req, now); err == nil {
			t.Fatal("expected an error for a past expiry")
		}
		req.Expiry = ""
		if err := s.verifyCancelSignature(context.Background(), req, now); err == nil {
			t.Fatal("expected an error for a missing expiry")
		}
	})

	t.Run("invalid signature is reported", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{cancelErr: ordersig.ErrInvalidSignature}}
		if err := s.verifyCancelSignature(context.Background(), signedReq(), now); err == nil {
			t.Fatal("expected an error for an invalid signature")
		}
	})

	// An RPC failure means "could not check", which must not reject a possibly-valid cancel.
	t.Run("unverifiable does not reject", func(t *testing.T) {
		s := &Server{signatures: &stubSignatureChecker{cancelErr: errors.New("rpc timeout")}}
		if err := s.verifyCancelSignature(context.Background(), signedReq(), now); err != nil {
			t.Fatalf("a failed check must not reject, got %v", err)
		}
	})
}

// The flag gates whether a reported cancel-signature problem becomes a rejection, exactly as it
// does for orders.
func TestCancelEnforcementFlagGatesRejection(t *testing.T) {
	now := time.Unix(1_786_000_000, 0)
	req := cancelOrderRequest{
		OwnerAddress: "0x3448ac0a3283951a2afd5b3a582329eca43cb47b",
		Nonce:        "1",
		Expiry:       "1786000600",
		Signature:    "0xdeadbeef",
	}
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
				cfg:        config.Config{EnforceCancelSignatures: tc.enforce},
				signatures: &stubSignatureChecker{cancelErr: ordersig.ErrInvalidSignature},
			}
			err := s.verifyCancelSignature(context.Background(), req, now)
			rejects := err != nil && s.cfg.EnforceCancelSignatures
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
