package pricing

import (
	"fmt"
	"math/big"
	"strings"

	"github.com/numofx/matching-backend/internal/instruments"
)

var bigTen = big.NewInt(10)

type Converter struct {
	tickSize        string
	quotePrecision  int
	scale           int
	tickNumerator   *big.Int
	tickDenominator *big.Int
}

func NewConverter(instrument instruments.Metadata) (Converter, error) {
	numerator, denominator, scale, err := decimalToFraction(instrument.TickSize)
	if err != nil {
		return Converter{}, fmt.Errorf("parse tick size for %s: %w", instrument.Symbol, err)
	}

	return Converter{
		tickSize:        instrument.TickSize,
		quotePrecision:  instrument.QuotePrecision,
		scale:           scale,
		tickNumerator:   numerator,
		tickDenominator: denominator,
	}, nil
}

func (c Converter) Parse(price string) (string, string, error) {
	numerator, denominator, _, err := decimalToFraction(price)
	if err != nil {
		return "", "", fmt.Errorf("parse price %q: %w", price, err)
	}

	scaledNumerator := new(big.Int).Mul(numerator, c.tickDenominator)
	scaledDenominator := new(big.Int).Mul(denominator, c.tickNumerator)
	quotient, remainder := new(big.Int).QuoRem(scaledNumerator, scaledDenominator, new(big.Int))
	if remainder.Sign() != 0 {
		return "", "", fmt.Errorf("price must align to tick size %s", c.tickSize)
	}
	if quotient.Sign() <= 0 {
		return "", "", fmt.Errorf("price must be positive")
	}

	display, err := c.FormatTicks(quotient.String())
	if err != nil {
		return "", "", err
	}
	return quotient.String(), display, nil
}

func (c Converter) FormatTicks(ticks string) (string, error) {
	value, ok := new(big.Int).SetString(strings.TrimSpace(ticks), 10)
	if !ok {
		return "", fmt.Errorf("invalid price ticks %q", ticks)
	}
	if value.Sign() < 0 {
		return "", fmt.Errorf("price ticks must be non-negative")
	}

	numerator := new(big.Int).Mul(value, c.tickNumerator)
	integer := new(big.Int).Quo(numerator, c.tickDenominator)
	remainder := new(big.Int).Mod(numerator, c.tickDenominator)
	if remainder.Sign() == 0 {
		return integer.String(), nil
	}

	scale := max(c.scale, c.quotePrecision)
	fractionDenominator := new(big.Int).Exp(bigTen, big.NewInt(int64(scale)), nil)
	fractionNumerator := new(big.Int).Mul(remainder, fractionDenominator)
	fractionNumerator.Quo(fractionNumerator, c.tickDenominator)

	fraction := fractionNumerator.String()
	if len(fraction) < scale {
		fraction = strings.Repeat("0", scale-len(fraction)) + fraction
	}
	fraction = strings.TrimRight(fraction, "0")
	if fraction == "" {
		return integer.String(), nil
	}

	return integer.String() + "." + fraction, nil
}

func decimalToFraction(raw string) (*big.Int, *big.Int, int, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, nil, 0, fmt.Errorf("value is required")
	}
	if strings.HasPrefix(trimmed, "+") {
		trimmed = strings.TrimPrefix(trimmed, "+")
	}

	parts := strings.Split(trimmed, ".")
	if len(parts) > 2 {
		return nil, nil, 0, fmt.Errorf("invalid decimal")
	}

	intPart := parts[0]
	if intPart == "" {
		intPart = "0"
	}
	fracPart := ""
	if len(parts) == 2 {
		fracPart = parts[1]
	}

	digits := intPart + fracPart
	if digits == "" {
		return nil, nil, 0, fmt.Errorf("invalid decimal")
	}
	for _, ch := range digits {
		if ch < '0' || ch > '9' {
			return nil, nil, 0, fmt.Errorf("invalid decimal")
		}
	}

	numerator, ok := new(big.Int).SetString(digits, 10)
	if !ok {
		return nil, nil, 0, fmt.Errorf("invalid decimal")
	}
	denominator := new(big.Int).Exp(bigTen, big.NewInt(int64(len(fracPart))), nil)
	return numerator, denominator, len(fracPart), nil
}

func max(left int, right int) int {
	if left > right {
		return left
	}
	return right
}
