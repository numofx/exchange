package wsauth

import (
	"testing"
	"time"
)

// Ground-truth vector produced by foundry `cast wallet sign` (independent oracle) for the
// canonical message Verifier.Message builds — proves RecoverEIP191 matches the Ethereum
// personal_sign / SIWE convention exactly, not just round-trips against itself.
const (
	vecAddr  = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
	vecSig   = "0x821949307bfaa6b0a646f390c94d23ca93444537ab48266775489fc7cd5e1f7e1fae7eb64f8b3daff6b4f359823f0f99bd0dfe1dbb87524bcb99717eab7cafd41b"
	vecNonce = "testnonce123"
	vecIAT   = int64(1700000000)
	vecExp   = int64(1700000300)
	vecDom   = "markets.numo.xyz"
)

func vecFrame() AuthFrame {
	return AuthFrame{Address: vecAddr, Signature: vecSig, Nonce: vecNonce, IssuedAt: vecIAT, Expiry: vecExp}
}

func TestRecoverEIP191_CastVector(t *testing.T) {
	v := Verifier{Domain: vecDom}
	sig, err := decodeSignature(vecSig)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	got, err := RecoverEIP191(v.Message(vecFrame()), sig)
	if err != nil {
		t.Fatalf("recover: %v", err)
	}
	if got != vecAddr {
		t.Fatalf("recovered %s, want %s", got, vecAddr)
	}
}

func TestVerify_Valid(t *testing.T) {
	v := Verifier{Domain: vecDom, MaxTTL: 10 * time.Minute}
	now := time.Unix(vecIAT+100, 0) // inside [issuedAt, expiry]
	owner, err := v.Verify(vecFrame(), now)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if owner != vecAddr {
		t.Fatalf("owner %s, want %s", owner, vecAddr)
	}
}

func TestVerify_Rejects(t *testing.T) {
	v := Verifier{Domain: vecDom, MaxTTL: 10 * time.Minute}
	inWindow := time.Unix(vecIAT+100, 0)

	t.Run("expired", func(t *testing.T) {
		if _, err := v.Verify(vecFrame(), time.Unix(vecExp+1, 0)); err != ErrExpired {
			t.Fatalf("want ErrExpired, got %v", err)
		}
	})
	t.Run("wrong domain -> address mismatch", func(t *testing.T) {
		bad := Verifier{Domain: "evil.example", MaxTTL: 10 * time.Minute}
		if _, err := bad.Verify(vecFrame(), inWindow); err != ErrAddressMismatch {
			t.Fatalf("want ErrAddressMismatch, got %v", err)
		}
	})
	t.Run("tampered address -> mismatch", func(t *testing.T) {
		f := vecFrame()
		f.Address = "0x0000000000000000000000000000000000000001"
		if _, err := v.Verify(f, inWindow); err != ErrAddressMismatch {
			t.Fatalf("want ErrAddressMismatch, got %v", err)
		}
	})
	t.Run("tampered nonce -> mismatch", func(t *testing.T) {
		f := vecFrame()
		f.Nonce = "different"
		if _, err := v.Verify(f, inWindow); err != ErrAddressMismatch {
			t.Fatalf("want ErrAddressMismatch, got %v", err)
		}
	})
	t.Run("ttl too long", func(t *testing.T) {
		short := Verifier{Domain: vecDom, MaxTTL: time.Minute}
		if _, err := short.Verify(vecFrame(), inWindow); err != ErrTTLTooLong {
			t.Fatalf("want ErrTTLTooLong, got %v", err)
		}
	})
	t.Run("missing nonce", func(t *testing.T) {
		f := vecFrame()
		f.Nonce = ""
		if _, err := v.Verify(f, inWindow); err != ErrNoNonce {
			t.Fatalf("want ErrNoNonce, got %v", err)
		}
	})
	t.Run("bad address format", func(t *testing.T) {
		f := vecFrame()
		f.Address = "not-an-address"
		if _, err := v.Verify(f, inWindow); err != ErrBadAddress {
			t.Fatalf("want ErrBadAddress, got %v", err)
		}
	})
}
