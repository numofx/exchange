package orders

import (
	"encoding/json"
	"time"
)

type Side string
type Status string

const (
	SideBuy  Side = "buy"
	SideSell Side = "sell"

	StatusActive    Status = "active"
	StatusMatching  Status = "matching"
	StatusFilled    Status = "filled"
	StatusCancelled Status = "cancelled"
	StatusExpired   Status = "expired"
)

type Order struct {
	OrderID         string
	OwnerAddress    string
	SignerAddress   string
	SubaccountID    string
	RecipientID     string
	Nonce           string
	Side            Side
	AssetAddress    string
	SubID           string
	DesiredAmount   string
	FilledAmount    string
	LimitPrice      string
	LimitPriceTicks string `json:"-"`
	WorstFee        string
	Expiry          int64
	ActionJSON      json.RawMessage
	Signature       string
	Status          Status
	CreatedAt       time.Time
	// PostOnly is read back so the matcher can refuse to make this order the taker. Submit-time
	// rejection alone cannot promise that: it evaluates against the book as it was, and a crossing
	// order committing concurrently still leaves a post-only order able to take.
	PostOnly bool
}
