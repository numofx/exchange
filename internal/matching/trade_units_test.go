package matching

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func TestComputeExecutionUnitsJUNUsesSignedPriceAndAmountScale(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: junSignedOrder(
			orders.SideBuy,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1782777600",
			"1391",
			"1",
			"0",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1782777600", "1391000000000000000000", "1000000000000000", true),
		),
		Maker: junSignedOrder(
			orders.SideSell,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1782777600",
			"1390",
			"1",
			"0",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1782777600", "1390000000000000000000", "1000000000000000", false),
		),
	}

	got, err := computeExecutionUnits(
		instruments.Metadata{Symbol: instruments.CNGNJun2026Symbol},
		candidate,
		"1390",
		"1",
	)
	if err != nil {
		t.Fatalf("computeExecutionUnits returned error: %v", err)
	}
	if got.FillPrice != "1390000000000000000000" {
		t.Fatalf("fill price = %s", got.FillPrice)
	}
	if got.FillAmount != "1000000000000000" {
		t.Fatalf("fill amount = %s", got.FillAmount)
	}
}

func TestComputeExecutionUnitsRejectsFillAmountAboveRemainingDesired(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: junSignedOrder(
			orders.SideBuy,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1782777600",
			"1391",
			"2",
			"1",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1782777600", "1391000000000000000000", "2000000000000000", true),
		),
		Maker: junSignedOrder(
			orders.SideSell,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1782777600",
			"1390",
			"2",
			"1",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1782777600", "1390000000000000000000", "2000000000000000", false),
		),
	}

	_, err := computeExecutionUnits(
		instruments.Metadata{Symbol: instruments.CNGNJun2026Symbol},
		candidate,
		"1390",
		"2",
	)
	if err == nil || err.Error() != "fill_amount exceeds taker remaining desired amount" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func junSignedOrder(side orders.Side, asset string, subID string, limitTicks string, desired string, filled string, tradeData string) orders.Order {
	action, _ := json.Marshal(map[string]any{
		"subaccount_id": "7",
		"nonce":         "1",
		"module":        "0x0AAE65AaA66Fe7f54486cDbD007956d3De611990",
		"data":          tradeData,
		"expiry":        "1782777600",
		"owner":         "0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310",
		"signer":        "0xC7bE60b228b997c23094DdfdD71e22E2DE6C9310",
	})

	return orders.Order{
		Side:            side,
		AssetAddress:    asset,
		SubID:           subID,
		DesiredAmount:   desired,
		FilledAmount:    filled,
		LimitPriceTicks: limitTicks,
		ActionJSON:      action,
	}
}

func tradeDataHex(asset string, subID string, limitPrice string, desiredAmount string, isBid bool) string {
	var out []byte
	out = append(out, encodeAddressWord(asset)...)
	out = append(out, encodeUnsignedWord(subID)...)
	out = append(out, encodeSignedWord(limitPrice)...)
	out = append(out, encodeSignedWord(desiredAmount)...)
	out = append(out, encodeUnsignedWord("0")...)
	out = append(out, encodeUnsignedWord("7")...)
	if isBid {
		out = append(out, encodeUnsignedWord("1")...)
	} else {
		out = append(out, encodeUnsignedWord("0")...)
	}
	return "0x" + hex.EncodeToString(out)
}

func encodeAddressWord(address string) []byte {
	raw, _ := hex.DecodeString(address[2:])
	word := make([]byte, 32)
	copy(word[12:], raw)
	return word
}

func encodeUnsignedWord(value string) []byte {
	n, _ := new(big.Int).SetString(value, 10)
	word := make([]byte, 32)
	bytes := n.Bytes()
	copy(word[32-len(bytes):], bytes)
	return word
}

func encodeSignedWord(value string) []byte {
	n, _ := new(big.Int).SetString(value, 10)
	if n.Sign() < 0 {
		mod := new(big.Int).Lsh(big.NewInt(1), 256)
		n = n.Add(n, mod)
	}
	word := make([]byte, 32)
	bytes := n.Bytes()
	copy(word[32-len(bytes):], bytes)
	return word
}
