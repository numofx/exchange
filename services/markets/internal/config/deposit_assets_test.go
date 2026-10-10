package config

import (
	"math/big"
	"testing"
)

func TestDepositAssetsGiveEachAssetItsSymbolAndMinimum(t *testing.T) {
	got, err := parseDepositAssets("0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272:USDC:10000000, 0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98:cNGN:15000000000", nil, big.NewInt(1))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Address != "0xa74e49b4ed7cb176bc02ef4d8a1a3240c9ad4272" || got[0].Symbol != "USDC" || got[0].MinAmount.Int64() != 10_000_000 ||
		got[1].Symbol != "cNGN" || got[1].MinAmount.Int64() != 15_000_000_000 {
		t.Fatalf("parsed %+v", got)
	}
}

func TestWithoutDepositAssetsTheOlderPairStillMeansUSDC(t *testing.T) {
	got, err := parseDepositAssets("", []string{"0xa74e49b4ed7cb176bc02ef4d8a1a3240c9ad4272"}, big.NewInt(10_000_000))
	if err != nil || len(got) != 1 || got[0].Symbol != "USDC" || got[0].MinAmount.Int64() != 10_000_000 {
		t.Fatalf("got %+v %v", got, err)
	}
}

func TestAMalformedDepositAssetsEntryStopsTheProcess(t *testing.T) {
	cash := "0xa74e49b4ed7cb176bc02ef4d8a1a3240c9ad4272"
	for _, spec := range []string{cash + ":USDC", "nope:USDC:1", cash + "::1", cash + ":USDC:0", cash + ":USDC:1.5", cash + ":USDC:1," + cash + ":USDC:2"} {
		if _, err := parseDepositAssets(spec, nil, big.NewInt(1)); err == nil {
			t.Fatalf("%q was accepted", spec)
		}
	}
}
