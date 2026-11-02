package options

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"strings"
)

const (
	sigGetAccountBalances = "0xc7569701" // getAccountBalances(uint256)
	sigBorrowingEnabled   = "0xa35d1300" // borrowingEnabled()
)

// Leg is one account's side of an option fill, as the engine will see it.
type Leg struct {
	// Surplus is engine.getMargin(account, true) before the fill.
	Surplus *big.Int
	// Cash is the account's balance of the premium's cash before the fill.
	Cash *big.Int
	// Delta is the option balance change, 18dp: +amount for the buyer, -amount for the writer.
	Delta *big.Int
	// CashDelta is the premium: -price x amount for the buyer, +price x amount for the writer.
	CashDelta *big.Int
	// Fee is the taker's fee in the cash (0 for the maker).
	Fee *big.Int
	// IsoBefore and IsoAfter are the strike's isolated IM requirement (<= 0) at the balance before and after.
	IsoBefore *big.Int
	IsoAfter  *big.Int
	// Borrowing is the engine's borrowingEnabled: without it, cash may not end below zero.
	Borrowing bool
}

// Shortfall is the engine's own test for an option fill, MarginEngine.handleAdjustment: every option fill adds risk
// there (a short grows, or cash leaves), so the account must end at or above initial margin, and with borrowing off,
// with no negative cash. The estimate replaces the strike's isolated requirement and adds the cash that moves:
//
//	post = surplus + cashDelta - fee + (isoAfter - isoBefore)
//
// It is exact for an account holding no long option of the expiry, where the engine's margin for the expiry is the
// sum of isolated requirements (a max-loss bound below it needs a long to pair with). Callers defer to the chain for
// any other account rather than refuse on a requirement the engine would not charge.
func Shortfall(leg Leg) (short bool, reason string, post *big.Int) {
	cashAfter := new(big.Int).Add(leg.Cash, leg.CashDelta)
	cashAfter.Sub(cashAfter, leg.Fee)
	if !leg.Borrowing && cashAfter.Sign() < 0 {
		return true, "negative_cash", cashAfter
	}
	post = new(big.Int).Add(leg.Surplus, leg.CashDelta)
	post.Sub(post, leg.Fee)
	post.Add(post, new(big.Int).Sub(leg.IsoAfter, leg.IsoBefore))
	if post.Sign() < 0 {
		return true, "insufficient_margin", post
	}
	return false, "", post
}

// Premium is price x amount / 1e18, the cash a fill moves: what the TradeModule pays buyer to writer.
func Premium(price, amount *big.Int) *big.Int {
	p := new(big.Int).Mul(price, amount)
	return p.Quo(p, oneE18)
}

var oneE18 = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

// HoldsLong reports whether the account holds a long option of this series' asset and expiry, at any strike: then the
// engine's max-loss bound may pair it with a short, and an isolated estimate overstates the requirement.
func (r *Reader) HoldsLong(ctx context.Context, account *big.Int) (bool, error) {
	ledger, err := r.ledger(ctx)
	if err != nil {
		return false, err
	}
	raw, err := r.call(ctx, ledger, sigGetAccountBalances+uintWord(account))
	if err != nil {
		return false, err
	}
	// (address asset, uint256 subId, int256 balance)[]: offset, length, then three words each.
	length, err := word(raw, 1)
	if err != nil {
		return false, fmt.Errorf("getAccountBalances: %w", err)
	}
	if !length.IsInt64() || length.Int64() > 1024 {
		return false, errors.New("getAccountBalances: implausible length")
	}
	for i := range int(length.Int64()) {
		assetWord, err := word(raw, 2+3*i)
		if err != nil {
			return false, fmt.Errorf("getAccountBalances: %w", err)
		}
		if !strings.EqualFold(fmt.Sprintf("0x%040x", assetWord), r.option) {
			continue
		}
		subID, err := word(raw, 3+3*i)
		if err != nil {
			return false, err
		}
		balance, err := word(raw, 4+3*i)
		if err != nil {
			return false, err
		}
		if new(big.Int).And(subID, big.NewInt(0xffffffff)).Int64() == r.expiry && signed(balance).Sign() > 0 {
			return true, nil
		}
	}
	return false, nil
}

// Borrowing is the engine's borrowingEnabled().
func (r *Reader) Borrowing(ctx context.Context) (bool, error) {
	return r.boolCall(ctx, r.manager, sigBorrowingEnabled)
}
