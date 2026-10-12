package futures

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"
)

const (
	sigGetMargin                = "0x623bb445" // getMargin(uint256,bool)
	sigAssetDetails             = "0xd21415a3" // assetDetails(address)
	sigFutureMarginRequirements = "0x84033e5e" // futureMarginRequirements(uint256)
	sigGetBalance               = "0x0806e640" // SubAccounts.getBalance(uint256,address,uint256)

	imRateTTL = time.Minute
)

// IMSurplus is engine.getMargin(account, true): the account's initial-margin surplus in USD, 18dp, signed.
// Not cached: it moves with every fill, deposit and mark.
func (r *Reader) IMSurplus(ctx context.Context, engine string, account *big.Int) (*big.Int, error) {
	raw, err := r.call(ctx, engine, sigGetMargin+uintWord(account)+uintWord(big.NewInt(1)))
	if err != nil {
		return nil, err
	}
	value, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("getMargin: %w", err)
	}
	return signed(value), nil
}

// Position is the account's balance of the series, 18dp contracts, signed.
func (r *Reader) Position(ctx context.Context, account *big.Int) (*big.Int, error) {
	ledger, err := r.ledger(ctx)
	if err != nil {
		return nil, err
	}
	raw, err := r.call(ctx, ledger, sigGetBalance+uintWord(account)+addressWord(r.future)+uintWord(big.NewInt(r.expiry)))
	if err != nil {
		return nil, err
	}
	value, err := word(raw, 0)
	if err != nil {
		return nil, fmt.Errorf("getBalance: %w", err)
	}
	return signed(value), nil
}

// FutureIMRate is engine.futureMarginRequirements(marketId).imReq for the future's market, 18dp. The
// engine adds a depeg penalty to it while cNGN is depegged; this does not, so it is never above the
// engine's own rate.
func (r *Reader) FutureIMRate(ctx context.Context, engine string) (*big.Int, error) {
	r.mu.Lock()
	if r.imRate != nil && r.now().Sub(r.imRateAt) < imRateTTL {
		rate := new(big.Int).Set(r.imRate)
		r.mu.Unlock()
		return rate, nil
	}
	r.mu.Unlock()
	details, err := r.call(ctx, engine, sigAssetDetails+addressWord(r.future))
	if err != nil {
		return nil, err
	}
	whitelisted, err := word(details, 0)
	if err != nil {
		return nil, fmt.Errorf("assetDetails: %w", err)
	}
	if whitelisted.Sign() == 0 {
		return nil, errors.New("the future is not whitelisted on the engine")
	}
	marketID, err := word(details, 2)
	if err != nil {
		return nil, fmt.Errorf("assetDetails: %w", err)
	}
	reqs, err := r.call(ctx, engine, sigFutureMarginRequirements+uintWord(marketID))
	if err != nil {
		return nil, err
	}
	rate, err := word(reqs, 1)
	if err != nil {
		return nil, fmt.Errorf("futureMarginRequirements: %w", err)
	}
	if rate.Sign() == 0 {
		return nil, errors.New("the engine has no futures IM requirement for the market")
	}
	r.mu.Lock()
	r.imRate, r.imRateAt = rate, r.now()
	r.mu.Unlock()
	return new(big.Int).Set(rate), nil
}

var two256 = new(big.Int).Lsh(big.NewInt(1), 256)

func signed(value *big.Int) *big.Int {
	if value.Bit(255) == 1 {
		return new(big.Int).Sub(value, two256)
	}
	return value
}
