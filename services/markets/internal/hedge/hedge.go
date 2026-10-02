// Package hedge is the venue's rule for perp accounts margined in cNGN. Such an account is a
// synthetic dollar: it may only be long USD (short the on-chain cNGN perp), never long naira, and
// its long-USD notional may not exceed the cNGN it holds, so that the hedge stays one for one and
// the account dollar-neutral. Long-naira trading is for USDC-margined accounts; this rule leaves
// them untouched.
//
// All amounts are 18dp engine units: cNGN held in the perp's collateral escrow, the signed perp
// position (positive = long naira), and the signed delta an order or fill would add (positive for
// the engine buyer).
package hedge

import (
	"fmt"
	"math/big"
)

// Check is the pure rule. cngn is the account's collateral balance; a non-positive balance means the
// rule does not apply. position is the account's perp balance now; delta is what the order adds.
func Check(cngn, position, delta *big.Int) error {
	if cngn == nil || cngn.Sign() <= 0 {
		return nil
	}
	after := new(big.Int).Add(position, delta)
	if after.Sign() > 0 {
		// A long-naira position may only be reduced toward zero, never opened or grown.
		if position.Sign() > 0 && after.Cmp(position) < 0 {
			return nil
		}
		return fmt.Errorf("cngn_margin_direction: an account margined in cNGN may only be long USD (buy USDC-cNGN); "+
			"this order would leave it long naira by %s cNGN. Deposit USDC margin, or withdraw the cNGN, to trade long naira", whole(after))
	}
	short := new(big.Int).Neg(after)
	if short.Cmp(cngn) > 0 {
		return fmt.Errorf("cngn_margin_hedge: an account margined in cNGN may hold at most as much long-USD notional as the cNGN "+
			"it posted (%s cNGN); this order would take it to %s cNGN. Reduce the size, or post more cNGN", whole(cngn), whole(short))
	}
	return nil
}

var e18 = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

func whole(value *big.Int) string {
	return new(big.Int).Quo(value, e18).String()
}
