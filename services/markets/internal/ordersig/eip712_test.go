package ordersig

import (
	"strings"
	"testing"
)

// The load-bearing test. Digest is only useful if it reproduces what ActionVerifier computes
// on-chain, and the cheapest independent check of that is a signature a real wallet produced
// for an order the venue accepted.
func TestDigestMatchesWalletSignature(t *testing.T) {
	digest, err := Digest(liveDomain, liveAction)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	sig, err := DecodeSignature(liveSignature)
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}

	got, err := Recover(digest, sig)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if got != strings.ToLower(liveSigner) {
		t.Fatalf("recovered %s, want %s — the digest no longer matches ActionVerifier", got, liveSigner)
	}
}

// Every field is bound into the digest, so tampering with any of them must break recovery. A
// field that could be altered without changing the digest would let a signature be replayed
// onto a different order.
func TestTamperedFieldsBreakRecovery(t *testing.T) {
	sig, err := DecodeSignature(liveSignature)
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}

	tamper := map[string]func(a *Action){
		"subaccount_id": func(a *Action) { a.SubaccountID = "10" },
		"nonce":         func(a *Action) { a.Nonce = "1" },
		"module":        func(a *Action) { a.Module = "0x0000000000000000000000000000000000000001" },
		"data":          func(a *Action) { a.Data = a.Data[:len(a.Data)-1] + "0" },
		"expiry":        func(a *Action) { a.Expiry = "1786011431" },
		"owner":         func(a *Action) { a.Owner = "0x0000000000000000000000000000000000000002" },
		"signer":        func(a *Action) { a.Signer = "0x0000000000000000000000000000000000000003" },
	}

	for field, mutate := range tamper {
		t.Run(field, func(t *testing.T) {
			action := liveAction
			mutate(&action)

			digest, err := Digest(liveDomain, action)
			if err != nil {
				t.Fatalf("digest: %v", err)
			}
			got, err := Recover(digest, sig)
			if err != nil {
				return // a recovery failure is also a rejection
			}
			if got == strings.ToLower(liveSigner) {
				t.Fatalf("tampering with %s still recovered the signer: %s is not bound into the digest", field, field)
			}
		})
	}
}

// The domain binds a signature to this contract on this chain, so a signature cannot be replayed
// against another deployment.
func TestDomainIsBound(t *testing.T) {
	sig, err := DecodeSignature(liveSignature)
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}

	for name, domain := range map[string]Domain{
		"wrong chain":    {ChainID: "84532", VerifyingContract: liveDomain.VerifyingContract},
		"wrong contract": {ChainID: liveDomain.ChainID, VerifyingContract: "0x0000000000000000000000000000000000000004"},
	} {
		t.Run(name, func(t *testing.T) {
			digest, err := Digest(domain, liveAction)
			if err != nil {
				t.Fatalf("digest: %v", err)
			}
			got, err := Recover(digest, sig)
			if err != nil {
				return
			}
			if got == strings.ToLower(liveSigner) {
				t.Fatalf("%s still recovered the signer", name)
			}
		})
	}
}

func TestMalformedInputsAreRejected(t *testing.T) {
	if _, err := DecodeSignature("0xnothex"); err == nil {
		t.Fatal("expected an error for non-hex signature")
	}
	if _, err := Recover(make([]byte, 32), make([]byte, 10)); err != ErrBadSignature {
		t.Fatalf("expected ErrBadSignature for a short signature, got %v", err)
	}

	short := make([]byte, 65)
	short[64] = 9 // not a valid recovery id
	if _, err := Recover(make([]byte, 32), short); err != ErrBadRecovery {
		t.Fatalf("expected ErrBadRecovery, got %v", err)
	}

	bad := []struct {
		name   string
		action Action
	}{
		{"non-numeric subaccount", Action{SubaccountID: "abc"}},
		{"short address", Action{SubaccountID: "1", Nonce: "1", Module: "0x1234"}},
	}
	for _, tc := range bad {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := Digest(liveDomain, tc.action); err == nil {
				t.Fatal("expected an error")
			}
		})
	}
}
