// Package wsauth authenticates a WebSocket connection's control of an Ethereum address so it
// can subscribe to the private 'orders' channel. It uses SIWE-style (EIP-4361) messages signed
// via personal_sign (EIP-191) — the right tool for off-chain auth (proving key control), as
// opposed to EIP-712 typed data, which is for authorizing on-chain payloads. Public channels
// need no auth; this is only the gate for per-owner order streams.
package wsauth

import (
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
	"golang.org/x/crypto/sha3"
)

var (
	ErrBadSignature = errors.New("signature must be 65 bytes")
	ErrBadRecovery  = errors.New("invalid recovery id")
)

// RecoverEIP191 recovers the signing address of a personal_sign (EIP-191) message. sig is the
// 65-byte [R||S||V] Ethereum signature (V in {0,1} or {27,28}). The returned address is
// lowercased "0x…". This mirrors the wallet-side eth personal_sign / SIWE convention.
func RecoverEIP191(message string, sig []byte) (string, error) {
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

	// decred's RecoverCompact wants [recoveryCode || R || S] with recoveryCode = 27 + recid
	// (no +4: we derive the address from the uncompressed key regardless).
	compact := make([]byte, 65)
	compact[0] = 27 + v
	copy(compact[1:33], sig[0:32])
	copy(compact[33:65], sig[32:64])

	pub, _, err := ecdsa.RecoverCompact(compact, eip191Hash(message))
	if err != nil {
		return "", err
	}
	return pubkeyToAddress(pub), nil
}

// eip191Hash is keccak256("\x19Ethereum Signed Message:\n" + len(message) + message).
func eip191Hash(message string) []byte {
	h := sha3.NewLegacyKeccak256()
	fmt.Fprintf(h, "\x19Ethereum Signed Message:\n%d", len(message))
	h.Write([]byte(message))
	return h.Sum(nil)
}

// pubkeyToAddress = "0x" + last 20 bytes of keccak256(uncompressed pubkey without the 0x04 tag).
func pubkeyToAddress(pub *secp256k1.PublicKey) string {
	uncompressed := pub.SerializeUncompressed() // 0x04 || X(32) || Y(32)
	h := sha3.NewLegacyKeccak256()
	h.Write(uncompressed[1:])
	sum := h.Sum(nil)
	return "0x" + hex.EncodeToString(sum[12:])
}

// decodeSignature parses a hex signature (with or without 0x) into 65 bytes.
func decodeSignature(s string) ([]byte, error) {
	s = strings.TrimPrefix(strings.TrimSpace(s), "0x")
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, fmt.Errorf("decode signature hex: %w", err)
	}
	return b, nil
}
