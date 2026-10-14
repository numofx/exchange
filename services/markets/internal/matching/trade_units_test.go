package matching

import (
	"encoding/hex"
	"encoding/json"
	"math/big"
	"testing"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func TestComputeExecutionUnitsUsesSignedPriceAndAmountScale(t *testing.T) {
	candidate := orders.MatchCandidate{
		Taker: signedOrder(
			orders.SideBuy,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1789567201",
			"1391",
			"1",
			"0",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1789567201", "1391000000000000000000", "1000000000000000", true),
		),
		Maker: signedOrder(
			orders.SideSell,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1789567201",
			"1390",
			"1",
			"0",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1789567201", "1390000000000000000000", "1000000000000000", false),
		),
	}

	got, err := computeExecutionUnits(
		instruments.Metadata{Symbol: instruments.CNGNSpotSymbol},
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
		Taker: signedOrder(
			orders.SideBuy,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1789567201",
			"1391",
			"2",
			"1",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1789567201", "1391000000000000000000", "2000000000000000", true),
		),
		Maker: signedOrder(
			orders.SideSell,
			"0xCE2846771074E20fEc739CF97a60E6075D1E464b",
			"1789567201",
			"1390",
			"2",
			"1",
			tradeDataHex("0xCE2846771074E20fEc739CF97a60E6075D1E464b", "1789567201", "1390000000000000000000", "2000000000000000", false),
		),
	}

	_, err := computeExecutionUnits(
		instruments.Metadata{Symbol: instruments.CNGNSpotSymbol},
		candidate,
		"1390",
		"2",
	)
	if err == nil || err.Error() != "fill_amount exceeds taker remaining desired amount" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func signedOrder(side orders.Side, asset string, subID string, limitTicks string, desired string, filled string, tradeData string) orders.Order {
	action, _ := json.Marshal(map[string]any{
		"subaccount_id": "7",
		"nonce":         "1",
		"module":        "0x0AAE65AaA66Fe7f54486cDbD007956d3De611990",
		"data":          tradeData,
		"expiry":        "1789567201",
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

// A pair the matcher can never settle as signed names the order at fault, which the venue cancels,
// instead of being released to cross the same way on every tick. On the future, which fixes its unit
// at 1e15 (1 USDC), an order still signed a whole contract per unit is the one at fault, taker or
// maker; the order at the market's unit trades on.
func TestUnmatchablePairNamesTheOrderOffTheMarketsUnit(t *testing.T) {
	const asset, subID = "0x00000000000000000000000000000000000000F0", "1796047200"
	future := instruments.Metadata{Symbol: "USDC-cNGN-30NOV26", ContractType: instruments.ContractTypeFuture, AmountScale: "1000000000000000"}
	atUnit := func(side orders.Side, desired string) orders.Order {
		signed := new(big.Int).Mul(mustBig(desired), big.NewInt(1_000_000_000_000_000))
		return signedOrder(side, asset, subID, "1380", desired, "0", tradeDataHex(asset, subID, "1380000000000000000000", signed.String(), side == orders.SideBuy))
	}
	wholeContract := func(side orders.Side) orders.Order {
		return signedOrder(side, asset, subID, "1380", "1", "0", tradeDataHex(asset, subID, "1380000000000000000000", "1000000000000000000", side == orders.SideBuy))
	}

	for _, tc := range []struct {
		name      string
		candidate orders.MatchCandidate
		want      []string
	}{
		{"stale maker", orders.MatchCandidate{Taker: atUnit(orders.SideBuy, "10"), Maker: wholeContract(orders.SideSell)}, []string{"maker"}},
		{"stale taker", orders.MatchCandidate{Taker: wholeContract(orders.SideBuy), Maker: atUnit(orders.SideSell, "1000")}, []string{"taker"}},
		{"both stale", orders.MatchCandidate{Taker: wholeContract(orders.SideBuy), Maker: wholeContract(orders.SideSell)}, []string{"taker", "maker"}},
	} {
		_, err := computeExecutionUnits(future, tc.candidate, "1380", "1")
		if got := unmatchableLegs(err); !equalStrings(got, tc.want) {
			t.Fatalf("%s: legs %v (err %v), want %v", tc.name, got, err, tc.want)
		}
	}

	// Both at the unit: it settles, 10 USDC as 1e16.
	got, err := computeExecutionUnits(future, orders.MatchCandidate{Taker: atUnit(orders.SideBuy, "10"), Maker: atUnit(orders.SideSell, "25")}, "1380", "10")
	if err != nil || got.FillAmount != "10000000000000000" {
		t.Fatalf("fill %+v, err %v; want 1e16", got, err)
	}
}

// Spot fixes its unit at one whole cNGN, so an order signed at another is the one at fault. The perp fixes
// none: of two orders at different scales the incoming one goes, never the resting one, so an odd-scale
// order cannot wipe a quote for free.
func TestUnmatchablePairOnSpotAndThePerp(t *testing.T) {
	const asset, subID = "0xCE2846771074E20fEc739CF97a60E6075D1E464b", "0"
	wholeCNGN := signedOrder(orders.SideSell, asset, subID, "1390", "1", "0", tradeDataHex(asset, subID, "1390000000000000000000", "1000000000000000000", false))
	oddTaker := signedOrder(orders.SideBuy, asset, subID, "1391", "1", "0", tradeDataHex(asset, subID, "1391000000000000000000", "1000000000000000", true))
	oddMaker := signedOrder(orders.SideSell, asset, subID, "1390", "1", "0", tradeDataHex(asset, subID, "1390000000000000000000", "1000000000000000", false))
	wholeTaker := signedOrder(orders.SideBuy, asset, subID, "1391", "1", "0", tradeDataHex(asset, subID, "1391000000000000000000", "1000000000000000000", true))
	spot := instruments.Metadata{Symbol: instruments.CNGNSpotSymbol, ContractType: instruments.ContractTypeSpot, AmountScale: instruments.SpotAmountScale}
	perp := instruments.Metadata{Symbol: "cNGN-PERP", ContractType: instruments.ContractTypePerpetual}

	for _, tc := range []struct {
		name      string
		market    instruments.Metadata
		candidate orders.MatchCandidate
		want      []string
	}{
		{"spot, odd taker", spot, orders.MatchCandidate{Taker: oddTaker, Maker: wholeCNGN}, []string{"taker"}},
		{"spot, odd maker", spot, orders.MatchCandidate{Taker: wholeTaker, Maker: oddMaker}, []string{"maker"}},
		{"perp, odd taker", perp, orders.MatchCandidate{Taker: oddTaker, Maker: wholeCNGN}, []string{"taker"}},
		{"perp, odd maker", perp, orders.MatchCandidate{Taker: wholeTaker, Maker: oddMaker}, []string{"taker"}},
	} {
		_, err := computeExecutionUnits(tc.market, tc.candidate, "1390", "1")
		if got := unmatchableLegs(err); !equalStrings(got, tc.want) {
			t.Fatalf("%s: legs %v (err %v), want %v", tc.name, got, err, tc.want)
		}
	}

	// A signature for another asset is the signer's fault alone.
	other := signedOrder(orders.SideSell, asset, subID, "1390", "1", "0", tradeDataHex("0x00000000000000000000000000000000000000F0", subID, "1390000000000000000000", "1000000000000000000", false))
	_, err := computeExecutionUnits(spot, orders.MatchCandidate{Taker: wholeTaker, Maker: other}, "1390", "1")
	if got := unmatchableLegs(err); !equalStrings(got, []string{"maker"}) {
		t.Fatalf("legs %v (err %v), want the maker", got, err)
	}
}

func mustBig(value string) *big.Int {
	n, ok := new(big.Int).SetString(value, 10)
	if !ok {
		panic(value)
	}
	return n
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
