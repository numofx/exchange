package ordersig

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// ErrInvalidSignature is returned when the signature does not authorize the action. It is the
// only rejection a client can act on: every other error means the check could not be completed.
var ErrInvalidSignature = errors.New("signature does not authorize this action")

// SignaturePath records how a signature was authorized, so callers can tell an EOA-signed order
// from a contract-signed one. Acceptance alone cannot distinguish them, which left the ERC-1271
// branch unobservable in production: a contract signature that verified looked exactly like an
// EOA signature that verified.
type SignaturePath string

const (
	// PathNone is returned alongside any error.
	PathNone SignaturePath = ""
	// PathEOA means the signature recovered locally to the signer, with no chain read.
	PathEOA SignaturePath = "eoa"
	// PathERC1271 means the signer is a contract and it accepted the signature on-chain.
	PathERC1271 SignaturePath = "erc1271"
)

// ERC-1271 magic value returned by isValidSignature(bytes32,bytes) for a valid signature.
const erc1271MagicValue = "0x1626ba7e"

// isValidSignature(bytes32,bytes) selector.
const erc1271Selector = "1626ba7e"

// Verifier checks that an order's signature authorizes its action.
//
// It recovers locally first, which settles every EOA-signed order without touching the network.
// Only when that fails does it consider ERC-1271: ActionVerifier uses SignatureChecker.
// isValidSignatureNow, so a contract wallet produces a signature that is valid on-chain but does
// not recover to the signer. Rejecting those locally would break smart accounts.
type Verifier struct {
	domain     Domain
	rpcURL     string
	httpClient *http.Client
}

// NewVerifier returns a Verifier, or nil if it is not configured well enough to run. A nil
// Verifier means "cannot check", which callers must not treat as "signature is valid".
func NewVerifier(chainID string, matchingAddress string, rpcURL string) *Verifier {
	chainID = strings.TrimSpace(chainID)
	matchingAddress = strings.TrimSpace(matchingAddress)
	if chainID == "" || matchingAddress == "" {
		return nil
	}
	return &Verifier{
		domain:     Domain{ChainID: chainID, VerifyingContract: matchingAddress},
		rpcURL:     strings.TrimSpace(rpcURL),
		httpClient: &http.Client{Timeout: 5 * time.Second},
	}
}

// Verify reports whether signature authorizes action on behalf of signerAddress.
//
// It deliberately does not check session-key authorization (signer != owner). That lives in
// ActionVerifier.sessionKeys and needs its own chain read; an order signed by a validly
// registered session key still passes here, and one signed by an unregistered key is caught
// on-chain as it is today.
func (v *Verifier) Verify(
	ctx context.Context,
	action Action,
	signature string,
	signerAddress string,
) (SignaturePath, error) {
	digest, err := Digest(v.domain, action)
	if err != nil {
		return PathNone, fmt.Errorf("build digest: %w", err)
	}
	return v.verifyDigest(ctx, digest, signature, signerAddress)
}

// VerifyCancel reports whether signature authorizes cancel on behalf of signerAddress. It shares
// the EOA-then-ERC-1271 path with Verify; only the digest differs. Like Verify it does not check
// that signer is authorized for owner (signer != owner): there is no on-chain session-key registry
// to consult for an off-chain-only cancel, so the caller decides who may sign for whom.
func (v *Verifier) VerifyCancel(
	ctx context.Context,
	cancel Cancel,
	signature string,
	signerAddress string,
) (SignaturePath, error) {
	digest, err := CancelDigest(v.domain, cancel)
	if err != nil {
		return PathNone, fmt.Errorf("build cancel digest: %w", err)
	}
	return v.verifyDigest(ctx, digest, signature, signerAddress)
}

// verifyDigest checks a signature against a precomputed digest, recovering locally first and
// falling back to ERC-1271 only when the signer is a contract. It is the shared core of Verify and
// VerifyCancel.
func (v *Verifier) verifyDigest(
	ctx context.Context,
	digest []byte,
	signature string,
	signerAddress string,
) (SignaturePath, error) {
	sig, err := DecodeSignature(signature)
	if err != nil {
		return PathNone, fmt.Errorf("%w: %s", ErrInvalidSignature, err)
	}

	want := strings.ToLower(strings.TrimSpace(signerAddress))

	recovered, recoverErr := Recover(digest, sig)
	if recoverErr == nil && recovered == want {
		return PathEOA, nil
	}

	// Not a plain EOA signature. It may still be a valid contract signature, but only if the
	// signer actually is a contract — an EOA whose signature did not recover is simply invalid.
	hasCode, err := v.hasCode(ctx, want)
	if err != nil {
		return PathNone, fmt.Errorf("check signer code: %w", err)
	}
	if !hasCode {
		if recoverErr != nil {
			return PathNone, fmt.Errorf("%w: %s", ErrInvalidSignature, recoverErr)
		}
		return PathNone, fmt.Errorf("%w: recovered %s", ErrInvalidSignature, recovered)
	}

	valid, err := v.isValidERC1271Signature(ctx, want, digest, sig)
	if err != nil {
		return PathNone, fmt.Errorf("erc-1271 check: %w", err)
	}
	if !valid {
		return PathNone, ErrInvalidSignature
	}
	return PathERC1271, nil
}

// hasCode reports whether address is a contract.
func (v *Verifier) hasCode(ctx context.Context, address string) (bool, error) {
	var result string
	if err := v.call(ctx, "eth_getCode", []any{address, "latest"}, &result); err != nil {
		return false, err
	}
	result = strings.TrimPrefix(strings.TrimSpace(result), "0x")
	return result != "" && strings.Trim(result, "0") != "", nil
}

// isValidERC1271Signature calls isValidSignature(bytes32,bytes) on a contract signer.
func (v *Verifier) isValidERC1271Signature(ctx context.Context, address string, digest []byte, sig []byte) (bool, error) {
	var out string
	params := []any{
		map[string]string{"to": address, "data": encodeIsValidSignatureCall(digest, sig)},
		"latest",
	}
	if err := v.call(ctx, "eth_call", params, &out); err != nil {
		return false, err
	}
	out = strings.TrimSpace(strings.ToLower(out))
	// The return is a bytes4 left-aligned in a 32-byte word.
	return strings.HasPrefix(out, erc1271MagicValue), nil
}

// encodeIsValidSignatureCall ABI-encodes isValidSignature(bytes32 hash, bytes signature).
func encodeIsValidSignatureCall(digest []byte, sig []byte) string {
	var b strings.Builder
	b.WriteString("0x")
	b.WriteString(erc1271Selector)
	b.WriteString(hex.EncodeToString(digest))         // bytes32 hash
	b.WriteString(hex.EncodeToString(word(0x40)))     // offset to the bytes argument
	b.WriteString(hex.EncodeToString(word(len(sig)))) // signature length

	padded := make([]byte, ((len(sig)+31)/32)*32)
	copy(padded, sig)
	b.WriteString(hex.EncodeToString(padded))
	return b.String()
}

func word(n int) []byte {
	out := make([]byte, 32)
	for i := 0; n > 0; i++ {
		out[31-i] = byte(n & 0xff)
		n >>= 8
	}
	return out
}

func (v *Verifier) call(ctx context.Context, method string, params []any, out *string) error {
	if v.rpcURL == "" {
		return errors.New("no chain RPC configured")
	}
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  method,
		"params":  params,
	})
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, v.rpcURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")

	resp, err := v.httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: rpc status %d", method, resp.StatusCode)
	}

	var envelope struct {
		Result string `json:"result"`
		Error  *struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return fmt.Errorf("%s: decode response: %w", method, err)
	}
	if envelope.Error != nil {
		return fmt.Errorf("%s: %s", method, envelope.Error.Message)
	}
	*out = envelope.Result
	return nil
}
