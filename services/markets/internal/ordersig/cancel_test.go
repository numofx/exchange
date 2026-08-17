package ordersig

import (
	"context"
	"encoding/hex"
	"testing"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"golang.org/x/crypto/sha3"
)

// A fixed key so the test is deterministic. Its address is derived, never hardcoded, so the two
// can never drift.
const cancelTestKey = "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

// eoaAddress reproduces pubkeyToAddress independently: keccak256 of the uncompressed pubkey minus
// its 0x04 tag, last 20 bytes.
func eoaAddress(t *testing.T, hexKey string) string {
	t.Helper()
	raw, err := hex.DecodeString(trimHexPrefix(hexKey))
	if err != nil {
		t.Fatalf("decode key: %v", err)
	}
	priv := secp256k1.PrivKeyFromBytes(raw)
	uncompressed := priv.PubKey().SerializeUncompressed()
	h := sha3.NewLegacyKeccak256()
	h.Write(uncompressed[1:])
	sum := h.Sum(nil)
	return "0x" + hex.EncodeToString(sum[12:])
}

// The load-bearing test for the cancel path: a signature over CancelDigest recovers the signer,
// so the digest the server checks is the one a wallet would produce over the same Cancel.
func TestCancelDigestRoundTripsEOASignature(t *testing.T) {
	signer := eoaAddress(t, cancelTestKey)
	cancel := Cancel{
		Owner:  signer,
		Signer: signer,
		Nonce:  "7319532056794814",
		Expiry: "1786995431",
	}
	digest, err := CancelDigest(liveDomain, cancel)
	if err != nil {
		t.Fatalf("CancelDigest: %v", err)
	}

	sig, err := DecodeSignature(signDigest(t, cancelTestKey, digest))
	if err != nil {
		t.Fatalf("DecodeSignature: %v", err)
	}
	got, err := Recover(digest, sig)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if got != signer {
		t.Fatalf("recovered %s, want %s", got, signer)
	}
}

// Every field is bound into the digest: changing any one makes a signature over the original stop
// recovering to the signer. This is what stops a captured cancel signature being replayed against
// a different order (nonce), owner, or validity window (expiry).
func TestCancelTamperedFieldsBreakRecovery(t *testing.T) {
	signer := eoaAddress(t, cancelTestKey)
	base := Cancel{Owner: signer, Signer: signer, Nonce: "7319532056794814", Expiry: "1786995431"}

	baseDigest, err := CancelDigest(liveDomain, base)
	if err != nil {
		t.Fatalf("CancelDigest: %v", err)
	}
	sig, err := DecodeSignature(signDigest(t, cancelTestKey, baseDigest))
	if err != nil {
		t.Fatalf("DecodeSignature: %v", err)
	}

	other := "0x000000000000000000000000000000000000dead"
	for _, tc := range []struct {
		name    string
		mutated Cancel
	}{
		{"nonce", Cancel{Owner: signer, Signer: signer, Nonce: "7319532056794815", Expiry: "1786995431"}},
		{"expiry", Cancel{Owner: signer, Signer: signer, Nonce: "7319532056794814", Expiry: "1786995432"}},
		{"owner", Cancel{Owner: other, Signer: signer, Nonce: "7319532056794814", Expiry: "1786995431"}},
		{"signer", Cancel{Owner: signer, Signer: other, Nonce: "7319532056794814", Expiry: "1786995431"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			digest, err := CancelDigest(liveDomain, tc.mutated)
			if err != nil {
				t.Fatalf("CancelDigest: %v", err)
			}
			got, err := Recover(digest, sig)
			if err == nil && got == signer {
				t.Fatalf("tampering %s still recovered the signer", tc.name)
			}
		})
	}
}

// VerifyCancel routes to the shared EOA path: a valid signature returns PathEOA without any RPC,
// so a cancel signed by the owner is authorized offline exactly like an EOA order.
func TestVerifyCancelAcceptsEOASignatureWithoutRPC(t *testing.T) {
	signer := eoaAddress(t, cancelTestKey)
	// Empty rpcURL: the EOA branch must return before any chain read.
	verifier := NewVerifier(liveDomain.ChainID, liveDomain.VerifyingContract, "")
	if verifier == nil {
		t.Fatal("NewVerifier returned nil")
	}

	cancel := Cancel{Owner: signer, Signer: signer, Nonce: "7319532056794814", Expiry: "1786995431"}
	digest, err := CancelDigest(liveDomain, cancel)
	if err != nil {
		t.Fatalf("CancelDigest: %v", err)
	}

	path, err := verifier.VerifyCancel(context.Background(), cancel, signDigest(t, cancelTestKey, digest), signer)
	if err != nil {
		t.Fatalf("VerifyCancel: %v", err)
	}
	if path != PathEOA {
		t.Fatalf("path = %q, want %q", path, PathEOA)
	}
}
