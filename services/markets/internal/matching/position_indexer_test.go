package matching

import (
	"fmt"
	"math/big"
	"testing"

	"golang.org/x/crypto/sha3"
)

func TestBalanceAdjustedTopicMatchesItsSignature(t *testing.T) {
	hash := sha3.NewLegacyKeccak256()
	hash.Write([]byte("BalanceAdjusted(uint256,address,bytes32,int256,int256,int256,uint256)"))
	if got := fmt.Sprintf("0x%x", hash.Sum(nil)); got != balanceAdjustedTopic {
		t.Fatalf("topic %s, want %s", got, balanceAdjustedTopic)
	}
}

func TestAssetAndSubIDTopicPacksTheAddressHigh(t *testing.T) {
	got := assetAndSubIDTopic("0xC74EfC8B4808803dBCF439E76Fde076d56625b8E", 0)
	want := "0xc74efc8b4808803dbcf439e76fde076d56625b8e000000000000000000000000"
	if got != want {
		t.Fatalf("topic %s, want %s", got, want)
	}
	if len(got) != 66 {
		t.Fatalf("topic must be 32 bytes: %d chars", len(got))
	}
}

func TestDecodeBalanceAdjustedLogsReadsAccountAndPostBalance(t *testing.T) {
	word := func(v *big.Int) string {
		if v.Sign() < 0 {
			v = new(big.Int).Add(v, new(big.Int).Lsh(big.NewInt(1), 256))
		}
		return fmt.Sprintf("%064x", v)
	}
	e18 := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	post := new(big.Int).Neg(new(big.Int).Mul(big.NewInt(978_700), e18)) // short 978,700 after a partial liquidation
	logs := []rawLog{
		{
			Topics:          []string{balanceAdjustedTopic, "0x" + word(big.NewInt(25)), "0x" + word(big.NewInt(0xde04)), assetAndSubIDTopic("0xC74EfC8B4808803dBCF439E76Fde076d56625b8E", 0)},
			Data:            "0x" + word(new(big.Int).Mul(big.NewInt(408_300), e18)) + word(new(big.Int).Neg(new(big.Int).Mul(big.NewInt(1_387_000), e18))) + word(post) + word(big.NewInt(7)),
			TransactionHash: "0xABCDEF",
			BlockNumber:     "0x31c2a40",
		},
		{Removed: true, Topics: []string{balanceAdjustedTopic, "0x" + word(big.NewInt(26)), "", ""}, Data: "0x" + word(big.NewInt(0)) + word(big.NewInt(0)) + word(big.NewInt(0)) + word(big.NewInt(0))},
	}
	adjustments, err := decodeBalanceAdjustedLogs(logs)
	if err != nil {
		t.Fatal(err)
	}
	if len(adjustments) != 1 {
		t.Fatalf("a removed (reorged) log must be skipped: %d adjustments", len(adjustments))
	}
	got := adjustments[0]
	if got.SubaccountID != "25" || got.PostBalance.Cmp(post) != 0 || got.TxHash != "0xabcdef" || got.BlockNumber != 0x31c2a40 {
		t.Fatalf("decoded %+v", got)
	}
}
