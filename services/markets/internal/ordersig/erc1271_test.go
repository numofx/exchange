package ordersig

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A 32-byte word holding the ERC-1271 magic value, left-aligned, as isValidSignature returns it.
const magicValueWord = "0x1626ba7e00000000000000000000000000000000000000000000000000000000"

// contractSigner is any address other than the one liveSignature recovers to, so the local
// recover misses and the ERC-1271 path runs.
const contractSigner = "0x00000000000000000000000000000000000c0de5"

type rpcCall struct {
	Method string        `json:"method"`
	Params []interface{} `json:"params"`
}

// stubRPC serves eth_getCode and eth_call, and records the calls it received.
func stubRPC(t *testing.T, code string, callResult string, callErr string) (*Verifier, *[]rpcCall) {
	t.Helper()
	var seen []rpcCall

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req rpcCall
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("decode rpc request: %v", err)
		}
		seen = append(seen, req)

		w.Header().Set("content-type", "application/json")
		switch req.Method {
		case "eth_getCode":
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"` + code + `"}`))
		case "eth_call":
			if callErr != "" {
				_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"message":"` + callErr + `"}}`))
				return
			}
			_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"result":"` + callResult + `"}`))
		default:
			t.Errorf("unexpected rpc method %q", req.Method)
		}
	}))
	t.Cleanup(server.Close)

	v := NewVerifier(liveDomain.ChainID, liveDomain.VerifyingContract, server.URL)
	if v == nil {
		t.Fatal("NewVerifier returned nil")
	}
	return v, &seen
}

// Anchors the selector and magic value against their definition rather than against each other.
// ERC-1271 defines both as bytes4(keccak256("isValidSignature(bytes32,bytes)")), so deriving it
// here catches a typo in the constants that a test comparing against those constants cannot.
func TestERC1271SelectorMatchesItsDefinition(t *testing.T) {
	want := hex.EncodeToString(keccak([]byte("isValidSignature(bytes32,bytes)"))[:4])

	if erc1271Selector != want {
		t.Fatalf("erc1271Selector is %s, want %s", erc1271Selector, want)
	}
	if erc1271MagicValue != "0x"+want {
		t.Fatalf("erc1271MagicValue is %s, want 0x%s", erc1271MagicValue, want)
	}
}

func TestERC1271ContractSignerAccepted(t *testing.T) {
	v, calls := stubRPC(t, "0x60806040", magicValueWord, "")

	if err := v.Verify(context.Background(), liveAction, liveSignature, contractSigner); err != nil {
		t.Fatalf("a contract signer returning the magic value must be accepted, got %v", err)
	}
	if len(*calls) != 2 || (*calls)[0].Method != "eth_getCode" || (*calls)[1].Method != "eth_call" {
		t.Fatalf("expected eth_getCode then eth_call, got %+v", *calls)
	}
}

func TestERC1271ContractSignerRejected(t *testing.T) {
	// Any return other than the magic value is a rejection.
	zeroWord := "0x" + strings.Repeat("0", 64)
	v, _ := stubRPC(t, "0x60806040", zeroWord, "")

	err := v.Verify(context.Background(), liveAction, liveSignature, contractSigner)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature, got %v", err)
	}
}

// An EOA whose signature does not recover is simply invalid — no ERC-1271 call should be made.
func TestNonContractSignerSkipsERC1271(t *testing.T) {
	v, calls := stubRPC(t, "0x", magicValueWord, "")

	err := v.Verify(context.Background(), liveAction, liveSignature, contractSigner)
	if !errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("expected ErrInvalidSignature, got %v", err)
	}
	for _, c := range *calls {
		if c.Method == "eth_call" {
			t.Fatal("must not call isValidSignature on an address with no code")
		}
	}
}

// A failed check must not masquerade as an invalid signature, or an RPC outage would reject
// valid orders once enforcement is on.
func TestERC1271RPCFailureIsNotARejection(t *testing.T) {
	v, _ := stubRPC(t, "0x60806040", "", "execution reverted")

	err := v.Verify(context.Background(), liveAction, liveSignature, contractSigner)
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrInvalidSignature) {
		t.Fatalf("an RPC failure must not be reported as an invalid signature: %v", err)
	}
}

// The part most likely to be wrong in a from-spec implementation: the call data layout.
// isValidSignature(bytes32 hash, bytes signature) encodes as
//
//	selector | hash | offset(0x40) | length | signature padded to a 32-byte multiple
func TestERC1271CallDataEncoding(t *testing.T) {
	v, calls := stubRPC(t, "0x60806040", magicValueWord, "")

	if err := v.Verify(context.Background(), liveAction, liveSignature, contractSigner); err != nil {
		t.Fatalf("verify: %v", err)
	}

	var data string
	for _, c := range *calls {
		if c.Method != "eth_call" {
			continue
		}
		params, ok := c.Params[0].(map[string]interface{})
		if !ok {
			t.Fatalf("unexpected eth_call params: %+v", c.Params)
		}
		if to, _ := params["to"].(string); !strings.EqualFold(to, contractSigner) {
			t.Fatalf("eth_call sent to %v, want the signer %s", params["to"], contractSigner)
		}
		data, _ = params["data"].(string)
	}
	if data == "" {
		t.Fatal("no eth_call data captured")
	}

	raw, err := hex.DecodeString(strings.TrimPrefix(data, "0x"))
	if err != nil {
		t.Fatalf("call data is not hex: %v", err)
	}

	sig, err := DecodeSignature(liveSignature)
	if err != nil {
		t.Fatalf("decode signature: %v", err)
	}
	digest, err := Digest(liveDomain, liveAction)
	if err != nil {
		t.Fatalf("digest: %v", err)
	}

	// 4 selector + 32 hash + 32 offset + 32 length + 96 padded signature (65 rounded up).
	if want := 4 + 32 + 32 + 32 + 96; len(raw) != want {
		t.Fatalf("call data is %d bytes, want %d", len(raw), want)
	}
	if got := hex.EncodeToString(raw[0:4]); got != erc1271Selector {
		t.Fatalf("selector %s, want %s", got, erc1271Selector)
	}
	if got := raw[4:36]; hex.EncodeToString(got) != hex.EncodeToString(digest) {
		t.Fatalf("hash argument is not the EIP-712 digest")
	}
	if got := raw[36:68]; hex.EncodeToString(got) != hex.EncodeToString(word(0x40)) {
		t.Fatalf("bytes offset is %x, want 0x40", got)
	}
	if got := raw[68:100]; hex.EncodeToString(got) != hex.EncodeToString(word(len(sig))) {
		t.Fatalf("signature length word is %x, want %d", got, len(sig))
	}
	if got := raw[100 : 100+len(sig)]; hex.EncodeToString(got) != hex.EncodeToString(sig) {
		t.Fatal("signature bytes were not copied verbatim")
	}
	for i, b := range raw[100+len(sig):] {
		if b != 0 {
			t.Fatalf("padding byte %d is %#x, want zero", i, b)
		}
	}
}

// A valid EOA signature must never reach the network.
func TestValidEOASignatureMakesNoRPCCall(t *testing.T) {
	v, calls := stubRPC(t, "0x", magicValueWord, "")

	if err := v.Verify(context.Background(), liveAction, liveSignature, liveSigner); err != nil {
		t.Fatalf("the live signature must verify locally, got %v", err)
	}
	if len(*calls) != 0 {
		t.Fatalf("expected no RPC calls, got %+v", *calls)
	}
}

func TestVerifierRequiresDomainConfig(t *testing.T) {
	if NewVerifier("", "0x00000000000000000000000000000000000c0de5", "http://localhost") != nil {
		t.Fatal("a missing chain id must yield no verifier")
	}
	if NewVerifier("8453", "", "http://localhost") != nil {
		t.Fatal("a missing matching address must yield no verifier")
	}
}
