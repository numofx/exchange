package api

import (
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/instruments"
	"github.com/numofx/matching-backend/internal/orders"
)

func TestPresentTradesIncludesMarketMetadata(t *testing.T) {
	items := []orders.TradeFill{{
		TradeID:       1,
		AssetAddress:  "0xf000000000000000000000000000000000000123",
		SubID:         "1789567201",
		Price:         "1605.25",
		Size:          "100000000000000000",
		AggressorSide: orders.SideBuy,
		TakerOrderID:  "taker-1",
		MakerOrderID:  "maker-1",
		CreatedAt:     time.Unix(1789567201, 0).UTC(),
	}}
	instrument := instruments.Metadata{
		Symbol:         instruments.CNGNSpotSymbol,
		ContractType:   "spot",
		SettlementType: "spot",
	}

	presented := presentTrades(items, instrument)
	if len(presented) != 1 {
		t.Fatalf("len = %d", len(presented))
	}
	if presented[0].Market != instruments.CNGNSpotSymbol {
		t.Fatalf("market = %q", presented[0].Market)
	}
	if presented[0].ContractType != "spot" {
		t.Fatalf("contract type = %q", presented[0].ContractType)
	}
	if presented[0].SettlementType != "spot" {
		t.Fatalf("settlement type = %q", presented[0].SettlementType)
	}
}
