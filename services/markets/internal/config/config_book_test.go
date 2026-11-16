package config

import "testing"

func TestOnchainBookNeedsItsDeployBlock(t *testing.T) {
	const book = "0x1111111111111111111111111111111111111111"
	for _, c := range []struct {
		address, start string
		ok             bool
	}{
		{"", "", true},
		{book, "58000000", true},
		{book, "", false},  // started from the head, the fills before the first run would never be on the tape
		{book, "0", false}, // likewise
		{book, "x", false},
		{"", "58000000", false},
		{"0x123", "1", false},
		{"0x" + "zz" + book[4:], "1", false},
		{"0x0000000000000000000000000000000000000000", "1", false},
	} {
		var cfg Config
		err := cfg.loadOnchainBook(c.address, c.start)
		if (err == nil) != c.ok {
			t.Errorf("%q %q: err %v, want ok %v", c.address, c.start, err, c.ok)
		}
		if c.ok && c.address != "" && (!cfg.OnchainBookEnabled() || cfg.OnchainBookStartBlock != 58000000) {
			t.Errorf("%q %q: loaded %+v", c.address, c.start, cfg.OnchainBookAddress)
		}
	}
}
