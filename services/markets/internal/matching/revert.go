package matching

import (
	"regexp"
	"strings"
)

// revertClass says whether a settlement that reverted could ever succeed for the same pair.
type revertClass int

const (
	// revertUnknown: the executor error carried no revert this code recognises. Treated like a
	// transient failure — retried on the backoff schedule — because guessing "permanent" would stop
	// a pair that might settle on the next attempt.
	revertUnknown revertClass = iota
	// revertBalanceDependent: the revert depends on account state that can change without either
	// order changing — a deposit, a fill elsewhere, a raised cap. Retried, slowly.
	revertBalanceDependent
	// revertPermanentForPair: the two signed orders can never settle against each other — the
	// revert is a property of what was signed, not of balances. Retrying only repeats it.
	revertPermanentForPair
)

func (c revertClass) String() string {
	switch c {
	case revertBalanceDependent:
		return "balance_dependent"
	case revertPermanentForPair:
		return "permanent_for_pair"
	default:
		return "unknown"
	}
}

// settlementRevert is what the matcher could learn about why a settlement reverted.
type settlementRevert struct {
	Selector string
	Name     string
	Class    revertClass
}

// knownReverts maps custom-error selectors to what they mean for retrying the pair. Selectors are
// derived with `cast sig` from the contract sources (contracts/execution, contracts/risk-core), never
// by hand.
//
// WERC_CannotBeNegative has no arguments and both legs of USDCcNGN-SPOT are WrappedERC20Assets, so it
// cannot say which side is short; it is balance-dependent, not attributable.
var knownReverts = map[string]settlementRevert{
	// Can never succeed for the pair.
	"0x786025f5": {Name: "AC_CannotTransferAssetToOneself", Class: revertPermanentForPair},
	"0xdfad89e3": {Name: "BM_NonceAlreadyUsed", Class: revertPermanentForPair},
	"0x3ada085b": {Name: "M_MismatchedModule", Class: revertPermanentForPair},
	"0xc07382c5": {Name: "M_OnlyAllowedModule", Class: revertPermanentForPair},
	"0x315523d5": {Name: "TM_AssetMismatch", Class: revertPermanentForPair},
	"0xef0644bd": {Name: "TM_AssetSubIdMismatch", Class: revertPermanentForPair},
	"0x02c7ec25": {Name: "TM_FeeTooHigh", Class: revertPermanentForPair},
	"0x15b2a441": {Name: "TM_InvalidNonce", Class: revertPermanentForPair},
	"0x0f508934": {Name: "TM_InvalidRecipientId", Class: revertPermanentForPair},
	"0xc916ff99": {Name: "TM_IsBidMismatch", Class: revertPermanentForPair},
	"0xba0e3964": {Name: "TM_PriceTooHigh", Class: revertPermanentForPair},
	"0xe30b762a": {Name: "TM_PriceTooLow", Class: revertPermanentForPair},
	"0xa5e66cdd": {Name: "TM_SignedAccountMismatch", Class: revertPermanentForPair},
	// Depend on account or venue state that can change while both orders rest.
	"0x703701fb": {Name: "SRM_NoNegativeCash", Class: revertBalanceDependent},
	"0x09598580": {Name: "SRM_PortfolioBelowMargin", Class: revertBalanceDependent},
	"0xe5b25796": {Name: "WERC_CannotBeNegative", Class: revertBalanceDependent},
	"0x8102bcdc": {Name: "BM_AssetCapExceeded", Class: revertBalanceDependent},
	"0x83d3980b": {Name: "BM_AdjustmentsPaused", Class: revertBalanceDependent},
}

// execution-service returns viem's message verbatim. The form seen in production is
//
//	The contract function "verifyAndMatch" reverted with the following signature:\n0x786025f5
//
// with the newline still JSON-escaped, since the body is embedded in the error unparsed. A decoded
// custom error reads `Error: TM_FeeTooHigh()` instead.
var (
	revertSignaturePattern = regexp.MustCompile(`reverted with the following signature:(?:\\n|\s)*(0x[0-9a-fA-F]{8})`)
	revertNamePattern      = regexp.MustCompile(`Error: ([A-Z]+_[A-Za-z0-9]+)\(`)
)

// classifySettlementRevert reads the revert out of an executor error. A nil error, or one that is
// not a recognised revert, classifies as revertUnknown.
func classifySettlementRevert(err error) settlementRevert {
	if err == nil {
		return settlementRevert{}
	}
	text := err.Error()

	if match := revertSignaturePattern.FindStringSubmatch(text); match != nil {
		selector := strings.ToLower(match[1])
		if known, ok := knownReverts[selector]; ok {
			known.Selector = selector
			return known
		}
		return settlementRevert{Selector: selector}
	}

	if match := revertNamePattern.FindStringSubmatch(text); match != nil {
		for selector, known := range knownReverts {
			if known.Name == match[1] {
				known.Selector = selector
				return known
			}
		}
		return settlementRevert{Name: match[1]}
	}

	return settlementRevert{}
}
