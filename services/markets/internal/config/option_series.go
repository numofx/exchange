package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strings"
	"time"
)

// OptionSeries is one listed expiry of an OptionAsset (risk-core deploy-cngn-options-v2.s.sol): every strike in
// Strikes is listed twice, a call and a put, each its own market. Options trade on the shared stack's TradeModule
// (CNGN_PERP_TRADE_MODULE_ADDRESS) as an asset it treats as neither perp nor dated future: a fill moves price x amount
// of its cash as the premium. They are margined by ManagerAddress, priced by its vol feed, and settle at the dated
// future's settlement price (FutureFixingSettlementFeed).
type OptionSeries struct {
	// AssetAddress is the OptionAsset (CNGN_OPTIONS_V2.json option).
	AssetAddress string `json:"asset_address"`
	// ManagerAddress is the engine that margins it (MarginEngine v2).
	ManagerAddress string `json:"manager_address"`
	// VolFeedAddress is the options' LyraVolFeed: no live surface for Expiry, no margin, so no trading.
	VolFeedAddress string `json:"vol_feed_address"`
	// BaseAsset is what one option unit is (1e18 = one cNGN) and what a strike is priced per.
	BaseAsset string `json:"base_asset"`
	// Expiry is unix seconds: the low 32 bits of every sub id in the series.
	Expiry int64 `json:"expiry"`
	// LastTradeTime is when matching stops. Zero is an hour before expiry: the vol feed refuses data stamped
	// after expiry, so margin (and so matching) stops working half an hour after it anyway.
	LastTradeTime int64 `json:"last_trade_time,omitempty"`
	// Strikes are decimal USDC per BaseAsset ("0.00072"), each a whole multiple of 1e-8 (OptionEncoding).
	Strikes []string `json:"strikes"`
	// AmountScale is the signed amount of one unit of desired_amount: 1e21 sizes orders in thousands of cNGN.
	// Required: an option has no contract size to derive one from.
	AmountScale string `json:"amount_scale"`
	// TakerFeeBps is the taker fee in bps of the premium (price x amount, the quote that moves). No default, as for
	// futures (FutureSeries.TakerFeeBps): an unpriced series is not listed.
	TakerFeeBps *int `json:"taker_fee_bps,omitempty"`
	// No close_only yet: reduce-only needs a position ledger per strike, which the venue keeps only for the perp and
	// the futures. An unknown field is refused at parse, so setting it fails loudly instead of leaving a series open.
}

// MaxOptionTakerFeeBps bounds a configured option fee: 10% of the premium. A fee on premium runs higher than one on
// notional, but a typo of a whole order of magnitude is still refused.
const MaxOptionTakerFeeBps = 1000

// strikeGranularity is OptionEncoding's: a strike is stored as strike / 1e10, so 1e-8 USDC is the finest.
var strikeGranularity = big.NewInt(10_000_000_000)

// OptionKind is a call or a put.
type OptionKind string

const (
	OptionCall OptionKind = "C"
	OptionPut  OptionKind = "P"
)

// OptionContract is one market of a series: a strike and a side.
type OptionContract struct {
	Series OptionSeries
	// Strike is the decimal as configured; StrikeWei is it in 18dp.
	Strike    string
	StrikeWei *big.Int
	Kind      OptionKind
}

// Priced reports whether the series states its taker fee.
func (s OptionSeries) Priced() bool { return s.TakerFeeBps != nil }

// TakerFee is the series' taker fee in bps (0 when unpriced; an unpriced series is never listed).
func (s OptionSeries) TakerFee() int {
	if s.TakerFeeBps == nil {
		return 0
	}
	return *s.TakerFeeBps
}

// TradingEnds is LastTradeTime, or an hour before expiry.
func (s OptionSeries) TradingEnds() int64 {
	if s.LastTradeTime > 0 {
		return s.LastTradeTime
	}
	return s.Expiry - 3600
}

// ExpiryCode is DDMONYY, as the futures' symbols.
func (s OptionSeries) ExpiryCode() string {
	return strings.ToUpper(time.Unix(s.Expiry, 0).UTC().Format("02Jan06"))
}

// Contracts is every market of the series, strikes in configured order, the call before the put.
func (s OptionSeries) Contracts() ([]OptionContract, error) {
	contracts := make([]OptionContract, 0, 2*len(s.Strikes))
	for _, strike := range s.Strikes {
		wei, err := StrikeWei(strike)
		if err != nil {
			return nil, err
		}
		for _, kind := range []OptionKind{OptionCall, OptionPut} {
			contracts = append(contracts, OptionContract{Series: s, Strike: strings.TrimSpace(strike), StrikeWei: wei, Kind: kind})
		}
	}
	return contracts, nil
}

// StrikeWei is a decimal strike in 18dp, refused unless positive and on OptionEncoding's 1e-8 grid.
func StrikeWei(strike string) (*big.Int, error) {
	rat, ok := new(big.Rat).SetString(strings.TrimSpace(strike))
	if !ok || rat.Sign() <= 0 {
		return nil, fmt.Errorf("strike %q is not a positive number", strike)
	}
	wei := new(big.Rat).Mul(rat, new(big.Rat).SetInt(wad18))
	if !wei.IsInt() || new(big.Int).Mod(wei.Num(), strikeGranularity).Sign() != 0 {
		return nil, fmt.Errorf("strike %q is finer than 1e-8: OptionEncoding stores strike / 1e10", strike)
	}
	return wei.Num(), nil
}

// SubID is OptionEncoding.toSubId: expiry | (strike / 1e10) << 32 | isCall << 95, as a decimal string.
func (c OptionContract) SubID() string {
	id := new(big.Int).SetInt64(c.Series.Expiry)
	id.Or(id, new(big.Int).Lsh(new(big.Int).Quo(c.StrikeWei, strikeGranularity), 32))
	if c.Kind == OptionCall {
		id.Or(id, new(big.Int).Lsh(big.NewInt(1), 95))
	}
	return id.String()
}

// MarketSymbol is <BASE>-<DDMONYY>-<strike>-<C|P>: cNGN-30NOV26-0.00072-C.
func (c OptionContract) MarketSymbol() string {
	return c.Series.BaseAsset + "-" + c.Series.ExpiryCode() + "-" + c.Strike + "-" + string(c.Kind)
}

// parseOptionSeries reads OPTION_SERIES: a JSON array of OptionSeries, addresses lowercased. Unknown fields are refused.
func parseOptionSeries(raw string) ([]OptionSeries, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	decoder := json.NewDecoder(bytes.NewReader([]byte(raw)))
	decoder.DisallowUnknownFields()
	var list []OptionSeries
	if err := decoder.Decode(&list); err != nil {
		return nil, fmt.Errorf("OPTION_SERIES is not a JSON array of series: %w", err)
	}
	for i := range list {
		list[i].AssetAddress = strings.ToLower(strings.TrimSpace(list[i].AssetAddress))
		list[i].ManagerAddress = strings.ToLower(strings.TrimSpace(list[i].ManagerAddress))
		list[i].VolFeedAddress = strings.ToLower(strings.TrimSpace(list[i].VolFeedAddress))
		list[i].BaseAsset = strings.TrimSpace(list[i].BaseAsset)
		list[i].AmountScale = strings.TrimSpace(list[i].AmountScale)
		for j := range list[i].Strikes {
			list[i].Strikes[j] = strings.TrimSpace(list[i].Strikes[j])
		}
	}
	return list, nil
}

func (s OptionSeries) validate() error {
	switch {
	case !isConfiguredAddress(s.AssetAddress):
		return fmt.Errorf("asset_address %q is not an address", s.AssetAddress)
	case !isConfiguredAddress(s.ManagerAddress):
		return fmt.Errorf("manager_address %q is not an address", s.ManagerAddress)
	case !isConfiguredAddress(s.VolFeedAddress):
		return fmt.Errorf("vol_feed_address %q is not an address", s.VolFeedAddress)
	case s.BaseAsset == "":
		return errors.New("base_asset is required (cNGN)")
	case s.Expiry <= 0 || s.Expiry > 0xffffffff:
		return errors.New("expiry is not a unix timestamp that fits OptionEncoding's 32 bits")
	case s.LastTradeTime < 0 || s.TradingEnds() >= s.Expiry:
		return errors.New("last_trade_time must be before expiry")
	case len(s.Strikes) == 0:
		return errors.New("strikes is empty: a series lists at least one")
	}
	seen := map[string]bool{}
	for _, strike := range s.Strikes {
		wei, err := StrikeWei(strike)
		if err != nil {
			return err
		}
		if seen[wei.String()] {
			return fmt.Errorf("strike %s is listed twice", strike)
		}
		seen[wei.String()] = true
	}
	scale, ok := new(big.Int).SetString(s.AmountScale, 10)
	if !ok || scale.Sign() <= 0 {
		return fmt.Errorf("amount_scale %q is not a positive whole number (1e21 for orders in thousands of %s)", s.AmountScale, s.BaseAsset)
	}
	if s.TakerFeeBps != nil && (*s.TakerFeeBps < 0 || *s.TakerFeeBps > MaxOptionTakerFeeBps) {
		return fmt.Errorf("taker_fee_bps %d is outside 0..%d", *s.TakerFeeBps, MaxOptionTakerFeeBps)
	}
	return nil
}

// validateOptionStack refuses a partial or ambiguous options configuration: options trade on the shared stack's
// TradeModule and cash, and their gate (cap, vol) is read from the chain. No two markets may share an (asset, sub id)
// or a symbol, across options and futures alike.
func (c Config) validateOptionStack() error {
	if len(c.OptionSeries) == 0 {
		return nil
	}
	if !c.PerpTradeStackConfigured() {
		return errors.New("OPTION_SERIES is listed without the shared stack (CNGN_PERP_TRADE_MODULE_ADDRESS, CNGN_PERP_CASH_ADDRESS, " +
			"CNGN_PERP_SRM_ADDRESS): options trade on that TradeModule and pay premium in its cash")
	}
	if strings.TrimSpace(c.ChainRPCURL) == "" {
		return errors.New("OPTION_SERIES is listed without CHAIN_RPC_URL: an option's cap and vol feed are read from the chain")
	}
	keys, symbols := map[string]bool{}, map[string]bool{}
	for _, series := range c.FutureSeriesList() {
		keys[series.AssetAddress+":"+series.SubID()], symbols[series.MarketSymbol()] = true, true
	}
	for i, series := range c.OptionSeries {
		if err := series.validate(); err != nil {
			return fmt.Errorf("OPTION_SERIES[%d]: %w", i, err)
		}
		contracts, err := series.Contracts()
		if err != nil {
			return fmt.Errorf("OPTION_SERIES[%d]: %w", i, err)
		}
		for _, contract := range contracts {
			key, symbol := series.AssetAddress+":"+contract.SubID(), contract.MarketSymbol()
			if keys[key] || symbols[symbol] {
				return fmt.Errorf("%s is listed twice", symbol)
			}
			keys[key], symbols[symbol] = true, true
		}
	}
	return nil
}
