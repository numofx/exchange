package orders

import "time"

type TradeFill struct {
	TradeID       int64
	AssetAddress  string
	SubID         string
	Price         string
	Size          string
	AggressorSide Side
	TakerOrderID  string
	MakerOrderID  string
	CreatedAt     time.Time
}

type TradeStats24h struct {
	Change string
	High   string
	Last   string
	Low    string
	// Volume is the summed fill size, in the engine's traded unit (whole cNGN on USDCcNGN-SPOT).
	Volume string
	// QuoteVolume is the summed fill notional, price × size, in the quote asset (USDC on
	// USDCcNGN-SPOT) — the volume a trader-facing ticker shows.
	QuoteVolume string
}
