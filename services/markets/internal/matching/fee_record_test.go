package matching

import "testing"

func TestQuoteWeiToDecimalIsExact(t *testing.T) {
	for wei, want := range map[string]string{
		// Trade #343's taker fee, one of the six that sum to fee subaccount 17's balance.
		"2475414442967443":    "0.002475414442967443",
		"2500000000000000":    "0.0025",
		"1890907912666":       "0.000001890907912666",
		"1000000000000000000": "1",
		"0":                   "0",
		"not-a-number":        "",
		"-1":                  "",
	} {
		if got := quoteWeiToDecimal(wei); got != want {
			t.Fatalf("quoteWeiToDecimal(%q) = %q, want %q", wei, got, want)
		}
	}
}
