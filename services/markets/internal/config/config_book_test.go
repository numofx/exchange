package config

import (
	"strings"
	"testing"
)

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
		for _, name := range onchainBookEnvNames {
			var cfg Config
			env := map[string]string{name + "_ADDRESS": c.address, name + "_START_BLOCK": c.start}
			err := cfg.loadOnchainBooks(func(k string) string { return env[k] })
			if (err == nil) != c.ok {
				t.Errorf("%s %q %q: err %v, want ok %v", name, c.address, c.start, err, c.ok)
			}
			if c.ok && c.address != "" && (!cfg.OnchainBookEnabled() || len(cfg.OnchainBooks) != 1 ||
				cfg.OnchainBooks[0].StartBlock != 58000000) {
				t.Errorf("%s %q %q: loaded %+v", name, c.address, c.start, cfg.OnchainBooks)
			}
		}
	}
}

// v1 and v2 side by side, in order; the same book under both names is refused (two indexers, one cursor).
func TestBothBooksAreIndexedAndNeverTwice(t *testing.T) {
	const v1, v2 = "0x1111111111111111111111111111111111111111", "0x2222222222222222222222222222222222222222"
	env := map[string]string{"ONCHAIN_BOOK_ADDRESS": v1, "ONCHAIN_BOOK_START_BLOCK": "58358413",
		"ONCHAIN_BOOK_V2_ADDRESS": v2, "ONCHAIN_BOOK_V2_START_BLOCK": "58700000"}
	var cfg Config
	if err := cfg.loadOnchainBooks(func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
	want := []OnchainBookSource{{v1, 58358413}, {v2, 58700000}}
	if len(cfg.OnchainBooks) != 2 || cfg.OnchainBooks[0] != want[0] || cfg.OnchainBooks[1] != want[1] {
		t.Fatalf("%+v", cfg.OnchainBooks)
	}
	env["ONCHAIN_BOOK_V2_ADDRESS"] = strings.ToUpper(v1[:2]) + v1[2:]
	if err := cfg.loadOnchainBooks(func(k string) string { return env[k] }); err == nil {
		t.Fatal("the same book twice was accepted")
	}
	// only v2 configured: one book
	delete(env, "ONCHAIN_BOOK_ADDRESS")
	delete(env, "ONCHAIN_BOOK_START_BLOCK")
	env["ONCHAIN_BOOK_V2_ADDRESS"] = v2
	if err := cfg.loadOnchainBooks(func(k string) string { return env[k] }); err != nil || len(cfg.OnchainBooks) != 1 {
		t.Fatalf("v2 alone: %v %+v", err, cfg.OnchainBooks)
	}
}
