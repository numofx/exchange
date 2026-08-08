package ordersig

import (
	"context"
	"encoding/hex"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

// These tests exercise the ERC-1271 branch against a real deployed contract instead of a stubbed
// RPC, so they cover what the httptest stubs cannot: real `eth_getCode` bytecode, a real
// `eth_call` into `isValidSignature`, and the ABI encoding round-tripping through an actual EVM.
//
// They are skipped unless a chain is pointed at, because the package's other tests must stay
// hermetic. To run them:
//
//	anvil --port 8555 &
//	forge create OwnerSignerWallet.sol:OwnerSignerWallet --rpc-url http://127.0.0.1:8555 \
//	  --private-key <anvil key 0> --broadcast --constructor-args <anvil address 0>
//	ORDERSIG_TEST_RPC_URL=http://127.0.0.1:8555 \
//	ORDERSIG_TEST_WALLET=<deployed address> \
//	ORDERSIG_TEST_OWNER_KEY=<anvil key 0> \
//	  go test ./internal/ordersig -run ERC1271Live -v
//
// The contract under test validates that the signature is plain ECDSA from its owner, which is
// how a 1-of-1 Safe or a Privy smart account behaves.
const liveTestChainID = "31337"

func liveTestConfig(t *testing.T) (rpcURL string, wallet string, ownerKey string) {
	t.Helper()
	rpcURL = os.Getenv("ORDERSIG_TEST_RPC_URL")
	wallet = os.Getenv("ORDERSIG_TEST_WALLET")
	ownerKey = os.Getenv("ORDERSIG_TEST_OWNER_KEY")
	if rpcURL == "" || wallet == "" || ownerKey == "" {
		t.Skip("set ORDERSIG_TEST_RPC_URL, ORDERSIG_TEST_WALLET and ORDERSIG_TEST_OWNER_KEY to run")
	}
	return rpcURL, wallet, ownerKey
}

// signDigest produces the 65-byte [R || S || V] signature an EVM wallet emits, with V as 27/28.
func signDigest(t *testing.T, hexKey string, digest []byte) string {
	t.Helper()
	raw, err := hex.DecodeString(trimHexPrefix(hexKey))
	if err != nil {
		t.Fatalf("decode key: %v", err)
	}
	priv := secp256k1.PrivKeyFromBytes(raw)

	// SignCompact returns [recoveryCode || R || S]; the EVM convention is [R || S || V].
	compact := ecdsa.SignCompact(priv, digest, false)
	sig := make([]byte, 65)
	copy(sig[0:32], compact[1:33])
	copy(sig[32:64], compact[33:65])
	sig[64] = compact[0]
	return "0x" + hex.EncodeToString(sig)
}

func trimHexPrefix(s string) string {
	if len(s) >= 2 && (s[:2] == "0x" || s[:2] == "0X") {
		return s[2:]
	}
	return s
}

func liveTestAction() Action {
	action := liveAction
	// A nonce distinct from the production fixture, so a pass here cannot come from the
	// EOA fast path recovering the fixture's real signer.
	action.Nonce = "424242"
	return action
}

// The gap every other test leaves open: a signature that is valid on-chain but does not recover
// to the signer must be accepted, because that is exactly what a smart account produces.
func TestERC1271LiveContractSignerAccepted(t *testing.T) {
	rpcURL, wallet, ownerKey := liveTestConfig(t)

	domain := Domain{ChainID: liveTestChainID, VerifyingContract: liveDomain.VerifyingContract}
	action := liveTestAction()

	digest, err := Digest(domain, action)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	signature := signDigest(t, ownerKey, digest)

	// The local recover must miss: the signature recovers to the owner EOA, not to the wallet.
	sig, err := DecodeSignature(signature)
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}
	recovered, err := Recover(digest, sig)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if recovered == strings.ToLower(strings.TrimSpace(wallet)) {
		t.Fatal("signature recovered to the wallet itself; the ERC-1271 branch would not run")
	}

	v := NewVerifier(domain.ChainID, domain.VerifyingContract, rpcURL)
	if v == nil {
		t.Fatal("NewVerifier returned nil")
	}
	path, err := v.Verify(context.Background(), action, signature, wallet)
	if err != nil {
		t.Fatalf("contract signature rejected: %v", err)
	}
	// Against a real deployed contract, not a stub: this is what proves the production log line
	// would report "erc1271" rather than silently taking the EOA path.
	if path != PathERC1271 {
		t.Fatalf("want path %q against a real contract signer, got %q", PathERC1271, path)
	}
}

// A signature the contract refuses must be a rejection, not a pass.
func TestERC1271LiveWrongSignerRejected(t *testing.T) {
	rpcURL, wallet, _ := liveTestConfig(t)
	otherKey := os.Getenv("ORDERSIG_TEST_OTHER_KEY")
	if otherKey == "" {
		t.Skip("set ORDERSIG_TEST_OTHER_KEY to run")
	}

	domain := Domain{ChainID: liveTestChainID, VerifyingContract: liveDomain.VerifyingContract}
	action := liveTestAction()

	digest, err := Digest(domain, action)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	signature := signDigest(t, otherKey, digest)

	v := NewVerifier(domain.ChainID, domain.VerifyingContract, rpcURL)
	_, err = v.Verify(context.Background(), action, signature, wallet)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("want ErrInvalidSignature, got %v", err)
	}
}

// Tampering with the action after signing must not survive the on-chain check either: the digest
// changes, so the contract sees a hash its owner never signed.
func TestERC1271LiveTamperedActionRejected(t *testing.T) {
	rpcURL, wallet, ownerKey := liveTestConfig(t)

	domain := Domain{ChainID: liveTestChainID, VerifyingContract: liveDomain.VerifyingContract}
	action := liveTestAction()

	digest, err := Digest(domain, action)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}
	signature := signDigest(t, ownerKey, digest)

	tampered := action
	tampered.Expiry = "1999999999"

	v := NewVerifier(domain.ChainID, domain.VerifyingContract, rpcURL)
	_, err = v.Verify(context.Background(), tampered, signature, wallet)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("want ErrInvalidSignature for a tampered action, got %v", err)
	}
}
