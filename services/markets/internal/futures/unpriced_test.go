package futures

import (
	"context"
	"errors"
	"math/big"
	"testing"

	"github.com/numofx/matching-backend/internal/config"
)

func unpricedSeries(asset string, fee *int) config.FutureSeries {
	return config.FutureSeries{AssetAddress: asset, Expiry: 1798736400, ManagerAddress: "0x0705219a1594d5fc5dc2573da4082caf3e1b0950",
		Kind: config.FutureKindLinear, BaseAsset: "EURC", ContractSize: "1000", Symbol: asset, TakerFeeBps: fee}
}

// A priced series is untouched; an unpriced one is dropped when flat, and kept close-only at no fee when
// it holds positions or its positions cannot be read.
func TestResolveUnpricedSeries(t *testing.T) {
	five := 5
	cfg := config.Config{FutureSeries: []config.FutureSeries{
		unpricedSeries("priced", &five),
		unpricedSeries("flat", nil),
		unpricedSeries("held", nil),
		unpricedSeries("unreadable", nil),
	}}
	positions := map[string]*big.Int{"flat": big.NewInt(0), "held": big.NewInt(22e15)}
	read := func(_ context.Context, s config.FutureSeries) (*big.Int, error) {
		if s.AssetAddress == "priced" {
			t.Error("a priced series is never read")
		}
		if p, ok := positions[s.AssetAddress]; ok {
			return p, nil
		}
		return nil, errors.New("rpc down")
	}
	got := ResolveUnpricedSeries(context.Background(), cfg, read).FutureSeries
	if len(got) != 3 || got[0].AssetAddress != "priced" || got[1].AssetAddress != "held" || got[2].AssetAddress != "unreadable" {
		t.Fatalf("series %+v: want priced, held, unreadable (flat dropped)", got)
	}
	if got[0].CloseOnly || got[0].TakerFee() != 5 {
		t.Errorf("priced series changed: %+v", got[0])
	}
	for _, s := range got[1:] {
		if !s.CloseOnly || !s.Priced() || s.TakerFee() != 0 {
			t.Errorf("%s: want close-only at 0 bps, got close_only %v fee %v", s.AssetAddress, s.CloseOnly, s.TakerFeeBps)
		}
	}
	if cfg.FutureSeries[2].CloseOnly || cfg.FutureSeries[2].Priced() {
		t.Error("the caller's config was edited in place")
	}
}
