package matching

import (
	"math/big"
	"strings"
)

// quoteWeiToDecimal renders a quote-asset amount in wei (18 decimals, as takerFillFee returns it) as
// an exact decimal for the fill row. An unparseable or negative amount renders empty, which is
// recorded as unknown rather than as a zero fee.
func quoteWeiToDecimal(wei string) string {
	value, ok := new(big.Int).SetString(strings.TrimSpace(wei), 10)
	if !ok || value.Sign() < 0 {
		return ""
	}
	whole, frac := new(big.Int).QuoRem(value, feeQuoteScale, new(big.Int))
	if frac.Sign() == 0 {
		return whole.String()
	}
	digits := frac.String()
	digits = strings.Repeat("0", 18-len(digits)) + digits
	return whole.String() + "." + strings.TrimRight(digits, "0")
}
