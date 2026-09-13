package matching

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

// The executor error the matcher logged for the 2026-09-13 self-trade on subaccount 19 (#50),
// trimmed after the selector. The newline is still JSON-escaped.
const selfTradeExecutorError = `executor returned status 500: {"error":"The contract function \"verifyAndMatch\" reverted with the following signature:\n0x786025f5\n\nUnable to decode signature \"0x786025f5\" as it was not found on the provided ABI.`

func TestClassifiesTheProductionSelfTradeRevertAsPermanent(t *testing.T) {
	got := classifySettlementRevert(errors.New(selfTradeExecutorError))

	if got.Selector != "0x786025f5" || got.Name != "AC_CannotTransferAssetToOneself" {
		t.Fatalf("classified as %+v", got)
	}
	if got.Class != revertPermanentForPair {
		t.Fatalf("class = %s, want permanent_for_pair", got.Class)
	}
}

// WERC_CannotBeNegative cannot say which leg is short, and a deposit can clear it.
func TestBalanceRevertsAreRetriedNotParked(t *testing.T) {
	err := errors.New(strings.ReplaceAll(selfTradeExecutorError, "0x786025f5", "0xe5b25796"))

	if got := classifySettlementRevert(err); got.Class != revertBalanceDependent || got.Name != "WERC_CannotBeNegative" {
		t.Fatalf("classified as %+v, want balance-dependent WERC_CannotBeNegative", got)
	}
}

func TestDecodedCustomErrorNamesAreRecognised(t *testing.T) {
	err := errors.New(`executor returned status 500: {"error":"The contract function \"verifyAndMatch\" reverted.\n\nError: TM_FeeTooHigh()"}`)

	if got := classifySettlementRevert(err); got.Class != revertPermanentForPair || got.Selector != "0x02c7ec25" {
		t.Fatalf("classified as %+v", got)
	}
}

// Guessing "permanent" for something unrecognised would stop a pair that might settle next time.
func TestUnrecognisedFailuresStayUnknown(t *testing.T) {
	for _, err := range []error{
		nil,
		errors.New("executor returned status 502"),
		errors.New(strings.ReplaceAll(selfTradeExecutorError, "0x786025f5", "0xdeadbeef")),
		errors.New(`reverted. Error: ZZ_SomethingNew()`),
	} {
		if got := classifySettlementRevert(err); got.Class != revertUnknown {
			t.Fatalf("%v classified as %+v, want unknown", err, got)
		}
	}
}

// Selectors are derived, never typed. When foundry is installed, recompute each one from its name;
// the signatures are all argument-less except AC_CannotTransferAssetToOneself.
func TestKnownRevertSelectorsMatchTheirNames(t *testing.T) {
	cast, err := exec.LookPath("cast")
	if err != nil {
		t.Skip("cast (foundry) not installed")
	}
	signatures := map[string]string{"AC_CannotTransferAssetToOneself": "AC_CannotTransferAssetToOneself(address,uint256)"}
	for selector, known := range knownReverts {
		signature, ok := signatures[known.Name]
		if !ok {
			signature = known.Name + "()"
		}
		out, err := exec.Command(cast, "sig", signature).Output()
		if err != nil {
			t.Fatalf("cast sig %s: %v", signature, err)
		}
		if got := strings.TrimSpace(string(out)); got != selector {
			t.Fatalf("%s: cast sig = %s, map says %s", signature, got, selector)
		}
	}
}
