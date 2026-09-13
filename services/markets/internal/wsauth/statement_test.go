package wsauth

import (
	"bytes"
	"encoding/hex"
	"testing"
	"time"

	"github.com/decred/dcrd/dcrec/secp256k1/v4"
	"github.com/decred/dcrd/dcrec/secp256k1/v4/ecdsa"
)

// signPersonal produces the 65-byte [R || S || V] personal_sign signature a wallet emits.
func signPersonal(t *testing.T, key []byte, message string) string {
	t.Helper()
	priv := secp256k1.PrivKeyFromBytes(key)
	// SignCompact returns [recoveryCode || R || S]; the wallet convention is [R || S || V].
	compact := ecdsa.SignCompact(priv, eip191Hash(message), false)
	sig := make([]byte, 65)
	copy(sig[0:32], compact[1:33])
	copy(sig[32:64], compact[33:65])
	sig[64] = compact[0]
	return "0x" + hex.EncodeToString(sig)
}

// The WebSocket message is a wire contract with every client that already authenticates. Adding a
// statement must leave the default byte-for-byte what they sign today.
func TestDefaultStatementIsTheMessageExistingClientsSign(t *testing.T) {
	v := Verifier{Domain: vecDom}
	want := "markets.numo.xyz wants you to authenticate for the Numo markets WebSocket.\n" +
		"Address: " + vecAddr + "\n" +
		"Nonce: testnonce123\n" +
		"Issued At: 1700000000\n" +
		"Expiration Time: 1700000300"

	if got := v.Message(vecFrame()); got != want {
		t.Fatalf("default message changed:\n got %q\nwant %q", got, want)
	}
}

// A long-lived order-history frame must not be accepted as a WebSocket login, and a short WebSocket
// frame must not read order history: the statement is signed, so each verifier recovers a
// different address from the other's signature.
func TestStatementBindsWhatTheSignatureAuthorizes(t *testing.T) {
	key := bytes.Repeat([]byte{0x11}, 32)
	now := time.Unix(1_800_000_000, 0)
	address := pubkeyToAddress(secp256k1.PrivKeyFromBytes(key).PubKey())
	frame := AuthFrame{
		Address:  address,
		Nonce:    "history-1",
		IssuedAt: now.Unix(),
		Expiry:   now.Add(time.Hour).Unix(),
	}

	history := Verifier{Domain: vecDom, MaxTTL: 24 * time.Hour, Statement: OrderHistoryStatement}
	websocket := Verifier{Domain: vecDom, MaxTTL: 24 * time.Hour}

	historyFrame := frame
	historyFrame.Signature = signPersonal(t, key, history.Message(frame))
	owner, err := history.Verify(historyFrame, now)
	if err != nil {
		t.Fatalf("history verifier rejected its own frame: %v", err)
	}
	if owner != address {
		t.Fatalf("owner %s, want %s", owner, address)
	}
	if _, err := websocket.Verify(historyFrame, now); err != ErrAddressMismatch {
		t.Fatalf("websocket verifier accepted a history frame: err=%v", err)
	}

	websocketFrame := frame
	websocketFrame.Signature = signPersonal(t, key, websocket.Message(frame))
	if _, err := history.Verify(websocketFrame, now); err != ErrAddressMismatch {
		t.Fatalf("history verifier accepted a websocket frame: err=%v", err)
	}
}
