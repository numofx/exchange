// Package events is the read side of the real-time pipeline: it tails the market_events
// append-only log (written by DB triggers, see migrations/000008 + docs/realtime-api-design.md)
// over LISTEN/NOTIFY and fans rows out to in-process subscribers. Transport-agnostic — the
// WebSocket handler adapts Sub into client frames.
package events

import (
	"encoding/json"
	"time"
)

// Channel names — must match the market_events.channel CHECK constraint.
const (
	ChannelBook   = "book"
	ChannelTrades = "trades"
	ChannelOrders = "orders"
)

// pgChannel is the Postgres LISTEN/NOTIFY channel carrying market_events seq numbers.
const pgChannel = "market_events"

// Event is one row of the market_events log. Seq is globally monotonic; per-market ordering
// is the subsequence filtered by MarketKey. Payload is the trigger-built delta/snapshot JSON.
type Event struct {
	Seq          int64           `json:"seq"`
	MarketKey    string          `json:"market"`
	Channel      string          `json:"channel"`
	EventType    string          `json:"type"`
	OwnerAddress string          `json:"-"` // set for ChannelOrders; private-routing key, never emitted cross-owner
	Payload      json.RawMessage `json:"data"`
	CreatedAt    time.Time       `json:"-"`
}

// Filter selects which events a subscriber receives. The zero value matches nothing.
//   - book/trades: Channel + Market (public).
//   - orders:      Channel + Owner (private); Market optional to scope to one market.
type Filter struct {
	Channel string
	Market  string // market_key: lower(asset_address) + ":" + sub_id
	Owner   string // lowercased owner address; required for ChannelOrders
}

// matches reports whether e should be delivered to a subscriber holding f. For the private
// orders channel, a non-matching or empty Owner never matches, so one owner's order events
// can never leak to another.
func (f Filter) matches(e Event) bool {
	if f.Channel != e.Channel {
		return false
	}
	if e.Channel == ChannelOrders {
		if f.Owner == "" || f.Owner != e.OwnerAddress {
			return false
		}
		return f.Market == "" || f.Market == e.MarketKey
	}
	return f.Market == e.MarketKey
}

// valid reports whether the filter is well-formed enough to subscribe with.
func (f Filter) valid() bool {
	switch f.Channel {
	case ChannelBook, ChannelTrades:
		return f.Market != ""
	case ChannelOrders:
		return f.Owner != ""
	default:
		return false
	}
}
