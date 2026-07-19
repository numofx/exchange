package wsauth

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrBadAddress      = errors.New("address must be 0x + 40 hex")
	ErrExpired         = errors.New("auth expired")
	ErrFutureIssued    = errors.New("auth issued in the future")
	ErrTTLTooLong      = errors.New("auth validity window too long")
	ErrNoNonce         = errors.New("nonce required")
	ErrAddressMismatch = errors.New("signature does not match address")
)

// clockSkew tolerates minor client/server clock drift on issued_at.
const clockSkew = 60 * time.Second

// AuthFrame is the client's {"op":"auth", ...} payload. Times are unix seconds to avoid any
// date-format ambiguity between signer and verifier.
type AuthFrame struct {
	Address   string `json:"address"`
	Signature string `json:"signature"`
	Nonce     string `json:"nonce"`
	IssuedAt  int64  `json:"issued_at"`
	Expiry    int64  `json:"expiry"`
}

// Verifier checks AuthFrames. Domain binds a signature to this service (so a signature for
// another dapp can't be replayed here); MaxTTL bounds how long a single signed frame stays
// valid (the replay window — keep it short, e.g. 5m).
type Verifier struct {
	Domain string
	MaxTTL time.Duration
}

// Verify recovers the signer and enforces domain/expiry/window checks. On success it returns
// the lowercased owner address the connection is authorized for. The message signed must be
// exactly Message(frame) — clients build the identical string before personal_sign.
func (v Verifier) Verify(f AuthFrame, now time.Time) (string, error) {
	addr := strings.ToLower(strings.TrimSpace(f.Address))
	if !isHexAddress(addr) {
		return "", ErrBadAddress
	}
	if f.Nonce == "" {
		return "", ErrNoNonce
	}
	nowUnix := now.Unix()
	if f.Expiry <= nowUnix {
		return "", ErrExpired
	}
	if f.IssuedAt > nowUnix+int64(clockSkew.Seconds()) {
		return "", ErrFutureIssued
	}
	if v.MaxTTL > 0 && f.Expiry-f.IssuedAt > int64(v.MaxTTL.Seconds()) {
		return "", ErrTTLTooLong
	}

	sig, err := decodeSignature(f.Signature)
	if err != nil {
		return "", err
	}
	recovered, err := RecoverEIP191(v.Message(f), sig)
	if err != nil {
		return "", err
	}
	if recovered != addr {
		return "", ErrAddressMismatch
	}
	return addr, nil
}

// Message is the canonical string the client signs. Both sides MUST build it identically,
// byte-for-byte, or recovery yields a different address and auth fails.
func (v Verifier) Message(f AuthFrame) string {
	return fmt.Sprintf(
		"%s wants you to authenticate for the Numo markets WebSocket.\n"+
			"Address: %s\n"+
			"Nonce: %s\n"+
			"Issued At: %d\n"+
			"Expiration Time: %d",
		v.Domain, strings.ToLower(strings.TrimSpace(f.Address)), f.Nonce, f.IssuedAt, f.Expiry)
}

func isHexAddress(s string) bool {
	if len(s) != 42 || !strings.HasPrefix(s, "0x") {
		return false
	}
	for _, c := range s[2:] {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}
