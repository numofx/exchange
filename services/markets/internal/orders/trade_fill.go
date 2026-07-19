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
	Volume string
}
