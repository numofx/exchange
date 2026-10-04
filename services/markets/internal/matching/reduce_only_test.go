package matching

import (
	"math/big"
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func TestReduceOnlyCapacityIsThePositionOnTheOppositeSide(t *testing.T) {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil) // 1 order unit = 1 cNGN
	long := new(big.Int).Mul(big.NewInt(1352), scale)              // long 1,352 cNGN

	if got := reduceOnlyCapacity(orders.SideSell, long, scale); got.Cmp(big.NewInt(1352)) != 0 {
		t.Fatalf("a sell against a long may fill the whole long: got %s", got)
	}
	if got := reduceOnlyCapacity(orders.SideBuy, long, scale); got.Sign() != 0 {
		t.Fatalf("a buy against a long would increase it: got %s", got)
	}
	short := new(big.Int).Neg(long)
	if got := reduceOnlyCapacity(orders.SideBuy, short, scale); got.Cmp(big.NewInt(1352)) != 0 {
		t.Fatalf("a buy against a short may fill the whole short: got %s", got)
	}
	if got := reduceOnlyCapacity(orders.SideSell, short, scale); got.Sign() != 0 {
		t.Fatalf("a sell against a short would increase it: got %s", got)
	}
}

func TestReduceOnlyCapacityIsZeroWhenFlatAndFloorsDust(t *testing.T) {
	scale := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	if got := reduceOnlyCapacity(orders.SideSell, big.NewInt(0), scale); got.Sign() != 0 {
		t.Fatalf("flat has nothing to reduce: got %s", got)
	}
	// 2.9 cNGN long: only 2 whole order units can be reduced; the dust stays.
	dusty := new(big.Int).Add(new(big.Int).Mul(big.NewInt(2), scale), new(big.Int).Quo(new(big.Int).Mul(big.NewInt(9), scale), big.NewInt(10)))
	if got := reduceOnlyCapacity(orders.SideSell, dusty, scale); got.Cmp(big.NewInt(2)) != 0 {
		t.Fatalf("2.9 units long reduces by at most 2: got %s", got)
	}
	if got := reduceOnlyCapacity(orders.SideSell, dusty, big.NewInt(0)); got.Sign() != 0 {
		t.Fatalf("a zero scale cannot produce capacity: got %s", got)
	}
}

func TestPerpLedgerCarriesTheExactScaleAndIsNilForSpot(t *testing.T) {
	perp := instruments.Metadata{Symbol: "USDCcNGN-PERP", ContractType: "perpetual", AssetAddress: "0xC74EfC8B4808803dBCF439E76Fde076d56625b8E"}
	ledger, err := perpLedger(perp, "1352", "1352000000000000000000")
	if err != nil {
		t.Fatalf("perpLedger: %v", err)
	}
	if ledger.AssetAddress != "0xc74efc8b4808803dbcf439e76fde076d56625b8e" {
		t.Fatalf("asset must be lower-cased: %s", ledger.AssetAddress)
	}
	if ledger.ChainAmount.String() != "1352000000000000000000" || ledger.AmountScale.String() != "1000000000000000000" {
		t.Fatalf("chain amount %s scale %s", ledger.ChainAmount, ledger.AmountScale)
	}
	if _, err := perpLedger(perp, "1352", "1352000000000000000001"); err == nil {
		t.Fatal("a chain amount that is not a whole multiple of the atomic amount must be refused")
	}
	spot := instruments.Metadata{Symbol: "USDCcNGN-SPOT", ContractType: "spot", AssetAddress: "0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98"}
	if ledger, err := perpLedger(spot, "1352", "1352000000000000000000"); err != nil || ledger != nil {
		t.Fatalf("spot keeps no position ledger: %v %v", ledger, err)
	}
}
