package api

import (
	"fmt"
	"math/big"
	"strings"
)

func parseDecimal(raw string) (*big.Rat, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, fmt.Errorf("decimal is required")
	}
	rat, ok := new(big.Rat).SetString(trimmed)
	if !ok {
		return nil, fmt.Errorf("invalid decimal %q", raw)
	}
	return rat, nil
}

func formatDecimal(value *big.Rat, scale int) string {
	scaledNumerator := new(big.Int).Mul(value.Num(), pow10(scale))
	quotient := new(big.Int)
	remainder := new(big.Int)
	quotient.QuoRem(scaledNumerator, value.Denom(), remainder)

	doubleRemainder := new(big.Int).Mul(remainder, big.NewInt(2))
	if doubleRemainder.Cmp(value.Denom()) >= 0 {
		quotient.Add(quotient, big.NewInt(1))
	}

	sign := ""
	if quotient.Sign() < 0 {
		sign = "-"
		quotient.Neg(quotient)
	}

	whole := new(big.Int)
	fraction := new(big.Int)
	whole.QuoRem(quotient, pow10(scale), fraction)

	fractionDigits := fraction.Text(10)
	if len(fractionDigits) < scale {
		fractionDigits = strings.Repeat("0", scale-len(fractionDigits)) + fractionDigits
	}
	fractionDigits = strings.TrimRight(fractionDigits, "0")
	if fractionDigits == "" {
		return sign + whole.Text(10)
	}
	return sign + whole.Text(10) + "." + fractionDigits
}

func normalizeDecimalString(value string) string {
	rat, err := parseDecimal(value)
	if err != nil {
		return strings.TrimSpace(value)
	}
	return formatDecimal(rat, 18)
}

func pow10(scale int) *big.Int {
	return new(big.Int).Exp(big.NewInt(10), big.NewInt(int64(scale)), nil)
}
