package events

import "testing"

func TestFilterMatches(t *testing.T) {
	const mkt = "0xdd9c:0"
	const owner = "0xabc"

	book := Event{Channel: ChannelBook, MarketKey: mkt}
	trade := Event{Channel: ChannelTrades, MarketKey: mkt}
	order := Event{Channel: ChannelOrders, MarketKey: mkt, OwnerAddress: owner}

	cases := []struct {
		name string
		f    Filter
		e    Event
		want bool
	}{
		{"book same market", Filter{Channel: ChannelBook, Market: mkt}, book, true},
		{"book other market", Filter{Channel: ChannelBook, Market: "x:1"}, book, false},
		{"channel mismatch", Filter{Channel: ChannelTrades, Market: mkt}, book, false},
		{"trades same market", Filter{Channel: ChannelTrades, Market: mkt}, trade, true},
		{"orders owner match", Filter{Channel: ChannelOrders, Owner: owner}, order, true},
		{"orders owner scoped market", Filter{Channel: ChannelOrders, Owner: owner, Market: mkt}, order, true},
		{"orders owner wrong market", Filter{Channel: ChannelOrders, Owner: owner, Market: "x:1"}, order, false},
		{"orders wrong owner (no cross-owner leak)", Filter{Channel: ChannelOrders, Owner: "0xdead"}, order, false},
		{"orders empty owner never matches", Filter{Channel: ChannelOrders}, order, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.f.matches(tc.e); got != tc.want {
				t.Fatalf("matches = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestFilterValid(t *testing.T) {
	cases := []struct {
		f    Filter
		want bool
	}{
		{Filter{Channel: ChannelBook, Market: "m"}, true},
		{Filter{Channel: ChannelBook}, false},
		{Filter{Channel: ChannelTrades, Market: "m"}, true},
		{Filter{Channel: ChannelOrders, Owner: "o"}, true},
		{Filter{Channel: ChannelOrders}, false},
		{Filter{Channel: "bogus", Market: "m"}, false},
		{Filter{}, false},
	}
	for _, tc := range cases {
		if got := tc.f.valid(); got != tc.want {
			t.Fatalf("valid(%+v) = %v, want %v", tc.f, got, tc.want)
		}
	}
}
