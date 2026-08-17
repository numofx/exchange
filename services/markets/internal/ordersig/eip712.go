// Package ordersig verifies the EIP-712 signature on a submitted order against the same digest
// ActionVerifier computes on-chain, so an order that can never settle is rejected at submission
// rather than resting on the book until expiry.
//
// The digest must match ActionVerifier byte for byte: it is built from EIP712("Matching", "1.0")
// and ACTION_TYPEHASH in contracts/execution/src/ActionVerifier.sol. A mismatch here rejects
// every valid order, so eip712_test.go pins it against real signatures produced by wallets.
//
// This duplicates a little of wsauth's recovery code on purpose. wsauth recovers EIP-191
// (personal_sign) messages for WebSocket auth; orders are EIP-712 typed data over a different
// digest, and the two schemes should not share a code path that could blur them.
package ordersig

import (
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"strings"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

// These strings mirror ActionVerifier. Changing either without changing the contract breaks
// every signature.
const (
	domainName    = "Matching"
	domainVersion = "1.0"

	actionTypeString = "Action(uint256 subaccountId,uint256 nonce,address module,bytes data," +
		"uint256 expiry,address owner,address signer)"
	domainTypeString = "EIP712Domain(string name,string version,uint256 chainId," +
		"address verifyingContract)"

	// cancelTypeString is this venue's own type: unlike Action it never reaches a contract, so it
	// carries no module or data — just the identity of the order being cancelled (owner, nonce),
	// the authorizing signer, and a short expiry that bounds how long the signature can be replayed.
	// It is signed against the same "Matching" domain as an order, so a cancel is bound to one chain
	// and one verifying contract and cannot be replayed onto another venue.
	cancelTypeString = "Cancel(address owner,address signer,uint256 nonce,uint256 expiry)"
)

var (
	ErrBadSignature = errors.New("signature must be 65 bytes")
	ErrBadRecovery  = errors.New("invalid recovery id")
)

// Domain is the EIP-712 domain the action was signed against. VerifyingContract is the deployed
// Matching contract, which inherits ActionVerifier.
type Domain struct {
	ChainID           string
	VerifyingContract string
}

// Action mirrors the Action struct in IActionVerifier. All numeric fields are base-10 strings and
// Data is hex, matching how they arrive in an order's action_json.
type Action struct {
	SubaccountID string
	Nonce        string
	Module       string
	Data         string
	Expiry       string
	Owner        string
	Signer       string
}

// Digest returns the 32-byte EIP-712 digest that ActionVerifier checks the signature against:
// keccak256("\x19\x01" || domainSeparator || structHash).
func Digest(d Domain, a Action) ([]byte, error) {
	separator, err := domainSeparator(d)
	if err != nil {
		return nil, err
	}
	structHash, err := actionStructHash(a)
	if err != nil {
		return nil, err
	}

	h := sha3.NewLegacyKeccak256()
	h.Write([]byte{0x19, 0x01})
	h.Write(separator)
	h.Write(structHash)
	return h.Sum(nil), nil
}

// Cancel is the off-chain authorization to cancel the resting order identified by (Owner, Nonce).
// Signer is who authorized it — the owner today, a session key once those are supported. All
// fields are base-10 strings, matching how they arrive on the wire.
type Cancel struct {
	Owner  string
	Signer string
	Nonce  string
	Expiry string
}

// CancelDigest returns the 32-byte EIP-712 digest a Cancel signature is checked against:
// keccak256("\x19\x01" || domainSeparator || structHash), over the same Matching domain as an order.
func CancelDigest(d Domain, c Cancel) ([]byte, error) {
	separator, err := domainSeparator(d)
	if err != nil {
		return nil, err
	}
	structHash, err := cancelStructHash(c)
	if err != nil {
		return nil, err
	}

	h := sha3.NewLegacyKeccak256()
	h.Write([]byte{0x19, 0x01})
	h.Write(separator)
	h.Write(structHash)
	return h.Sum(nil), nil
}

func cancelStructHash(c Cancel) ([]byte, error) {
	owner, err := encodeAddress(c.Owner)
	if err != nil {
		return nil, fmt.Errorf("owner: %w", err)
	}
	signer, err := encodeAddress(c.Signer)
	if err != nil {
		return nil, fmt.Errorf("signer: %w", err)
	}
	nonce, err := encodeUint(c.Nonce)
	if err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	expiry, err := encodeUint(c.Expiry)
	if err != nil {
		return nil, fmt.Errorf("expiry: %w", err)
	}

	h := sha3.NewLegacyKeccak256()
	h.Write(keccak([]byte(cancelTypeString)))
	h.Write(owner)
	h.Write(signer)
	h.Write(nonce)
	h.Write(expiry)
	return h.Sum(nil), nil
}

// Recover returns the lowercased "0x…" address that produced sig over digest. sig is the 65-byte
// [R||S||V] Ethereum signature, V in {0,1} or {27,28}.
func Recover(digest []byte, sig []byte) (string, error) {
	if len(sig) != 65 {
		return "", ErrBadSignature
	}
	v := sig[64]
	if v >= 27 {
		v -= 27
	}
	if v != 0 && v != 1 {
		return "", ErrBadRecovery
	}

	// decred's RecoverCompact wants [recoveryCode || R || S] with recoveryCode = 27 + recid.
	compact := make([]byte, 65)
	compact[0] = 27 + v
	copy(compact[1:33], sig[0:32])
	copy(compact[33:65], sig[32:64])

	pub, _, err := ecdsa.RecoverCompact(compact, digest)
	if err != nil {
		return "", err
	}
	return pubkeyToAddress(pub), nil
}

// DecodeSignature parses a hex signature, with or without the 0x prefix.
func DecodeSignature(s string) ([]byte, error) {
	b, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(s), "0x"))
	if err != nil {
		return nil, fmt.Errorf("decode signature hex: %w", err)
	}
	return b, nil
}

func domainSeparator(d Domain) ([]byte, error) {
	chainID, err := encodeUint(d.ChainID)
	if err != nil {
		return nil, fmt.Errorf("chain id: %w", err)
	}
	verifying, err := encodeAddress(d.VerifyingContract)
	if err != nil {
		return nil, fmt.Errorf("verifying contract: %w", err)
	}

	h := sha3.NewLegacyKeccak256()
	h.Write(keccak([]byte(domainTypeString)))
	h.Write(keccak([]byte(domainName)))
	h.Write(keccak([]byte(domainVersion)))
	h.Write(chainID)
	h.Write(verifying)
	return h.Sum(nil), nil
}

func actionStructHash(a Action) ([]byte, error) {
	subaccountID, err := encodeUint(a.SubaccountID)
	if err != nil {
		return nil, fmt.Errorf("subaccount id: %w", err)
	}
	nonce, err := encodeUint(a.Nonce)
	if err != nil {
		return nil, fmt.Errorf("nonce: %w", err)
	}
	module, err := encodeAddress(a.Module)
	if err != nil {
		return nil, fmt.Errorf("module: %w", err)
	}
	data, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(a.Data), "0x"))
	if err != nil {
		return nil, fmt.Errorf("data: decode hex: %w", err)
	}
	expiry, err := encodeUint(a.Expiry)
	if err != nil {
		return nil, fmt.Errorf("expiry: %w", err)
	}
	owner, err := encodeAddress(a.Owner)
	if err != nil {
		return nil, fmt.Errorf("owner: %w", err)
	}
	signer, err := encodeAddress(a.Signer)
	if err != nil {
		return nil, fmt.Errorf("signer: %w", err)
	}

	h := sha3.NewLegacyKeccak256()
	h.Write(keccak([]byte(actionTypeString)))
	h.Write(subaccountID)
	h.Write(nonce)
	h.Write(module)
	// abi.encode hashes dynamic `bytes` rather than inlining them.
	h.Write(keccak(data))
	h.Write(expiry)
	h.Write(owner)
	h.Write(signer)
	return h.Sum(nil), nil
}

// encodeUint renders a base-10 integer string as a 32-byte big-endian word.
func encodeUint(s string) ([]byte, error) {
	n, ok := new(big.Int).SetString(strings.TrimSpace(s), 10)
	if !ok || n.Sign() < 0 {
		return nil, fmt.Errorf("%q is not a non-negative base-10 integer", s)
	}
	if n.BitLen() > 256 {
		return nil, fmt.Errorf("%q does not fit in uint256", s)
	}
	out := make([]byte, 32)
	n.FillBytes(out)
	return out, nil
}

// encodeAddress renders a 20-byte address as a 32-byte word, left-padded with zeroes.
func encodeAddress(s string) ([]byte, error) {
	raw, err := hex.DecodeString(strings.TrimPrefix(strings.TrimSpace(s), "0x"))
	if err != nil {
		return nil, fmt.Errorf("decode address hex: %w", err)
	}
	if len(raw) != 20 {
		return nil, fmt.Errorf("address must be 20 bytes, got %d", len(raw))
	}
	out := make([]byte, 32)
	copy(out[12:], raw)
	return out, nil
}

func keccak(b []byte) []byte {
	h := sha3.NewLegacyKeccak256()
	h.Write(b)
	return h.Sum(nil)
}

// pubkeyToAddress = "0x" + last 20 bytes of keccak256(uncompressed pubkey without the 0x04 tag).
func pubkeyToAddress(pub *secp256k1.PublicKey) string {
	uncompressed := pub.SerializeUncompressed()
	sum := keccak(uncompressed[1:])
	return "0x" + hex.EncodeToString(sum[12:])
}
