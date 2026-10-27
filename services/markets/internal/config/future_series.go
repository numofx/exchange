package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"time"
)

// The two FutureAsset generations a series can be (risk-core docs/margin-engine-v2.md). They differ in
// what the chain's numbers mean, so every reader of a series asks which it is.
const (
	// FutureKindInverse is MarginEngine v1's USDC-cNGN-<expiry> (src/legacy/v1): priced in cNGN per USDC,
	// the index 1e36 / the feed, one contract a fixed number of USDC, variation margin in cNGN.
	FutureKindInverse = "inverse"
	// FutureKindLinear is MarginEngine v2's <BASE>-<expiry> (src/assets/FutureAsset): priced in USDC per
	// base, the index the feed as is, one contract a number of base units, variation margin in USDC.
	FutureKindLinear = "linear"
)

// LegacyFutureContractSize is one contract of the v1 series, in USDC: what CNGN_FUTURE_* lists.
const LegacyFutureContractSize = "1000"

// FutureSeries is one listed FutureAsset series. A series is keyed by (AssetAddress, Expiry), never by
// expiry alone: v1's and v2's 30NOV26 share an expiry on different assets and engines.
type FutureSeries struct {
	AssetAddress string `json:"asset_address"`
	// Expiry is unix seconds, and the series' sub id on its FutureAsset (getSubId(expiry) is the expiry).
	Expiry int64 `json:"expiry"`
	// ManagerAddress is the engine whose accounts hold the series (FutureAsset whitelists it).
	ManagerAddress string `json:"manager_address"`
	// Kind is FutureKindInverse or FutureKindLinear.
	Kind string `json:"kind"`
	// BaseAsset is the asset a contract is a number of, and what a linear series is priced per: cNGN,
	// EURC. An inverse series is always cNGN (its contract is USDC, priced in cNGN per USDC).
	BaseAsset string `json:"base_asset"`
	// ContractSize is FutureAsset.contractSize() in whole units, a decimal: 1000 (USDC) for v1, 1000000
	// (cNGN) for v2's cNGN-30NOV26. The matcher refuses to start when the chain disagrees.
	ContractSize string `json:"contract_size"`
	// AmountScale is the signed amount of one unit of desired_amount, 1e18 per contract. Empty is one
	// whole unit of the contract's denomination, 1e18 / ContractSize: v1's 1e15 (1 USDC), 1e12 (1 cNGN)
	// for a 1,000,000 cNGN contract.
	AmountScale string `json:"amount_scale,omitempty"`
	// Symbol overrides the derived name (USDC-cNGN-<DDMONYY> inverse, <BASE>-<DDMONYY> linear).
	Symbol string `json:"symbol,omitempty"`
	// CloseOnly takes every order on the series as reduce-only, resting ones included at match time:
	// the engine is being run out and no position may open or grow on it.
	CloseOnly bool `json:"close_only,omitempty"`
}

// SubID is the series' sub id: its expiry.
func (s FutureSeries) SubID() string {
	return strconv.FormatInt(s.Expiry, 10)
}

// Linear reports whether the series is a v2 FutureAsset (USDC per base, VM in USDC).
func (s FutureSeries) Linear() bool {
	return s.Kind == FutureKindLinear
}

// MarketSymbol is the series' market identifier: USDC-cNGN-30NOV26 for v1 (the name the app routes
// and the makers use, unchanged), cNGN-30NOV26 or EURC-30NOV26 for v2.
func (s FutureSeries) MarketSymbol() string {
	if symbol := strings.TrimSpace(s.Symbol); symbol != "" {
		return symbol
	}
	date := strings.ToUpper(time.Unix(s.Expiry, 0).UTC().Format("02Jan06"))
	if s.Linear() {
		return s.BaseAsset + "-" + date
	}
	return "USDC-cNGN-" + date
}

// ScaledAmount is AmountScale, or its default.
func (s FutureSeries) ScaledAmount() string {
	if scale := strings.TrimSpace(s.AmountScale); scale != "" {
		return scale
	}
	size, ok := new(big.Rat).SetString(strings.TrimSpace(s.ContractSize))
	if !ok || size.Sign() <= 0 {
		return ""
	}
	scale := new(big.Rat).Quo(new(big.Rat).SetInt(wad18), size)
	if !scale.IsInt() {
		return ""
	}
	return scale.Num().String()
}

var wad18 = new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)

// FutureEnabled reports whether any futures series is listed.
func (c Config) FutureEnabled() bool {
	return len(c.FutureSeriesList()) != 0
}

// FutureSubID is the CNGN_FUTURE_* series' sub id on its FutureAsset: getSubId(expiry) is the expiry.
func (c Config) FutureSubID() string {
	return strconv.FormatInt(c.CNGNFutureExpiry, 10)
}

// FutureSeriesList is every listed series: the CNGN_FUTURE_* one first, as it always was, then
// FUTURE_SERIES in order.
func (c Config) FutureSeriesList() []FutureSeries {
	var list []FutureSeries
	if strings.TrimSpace(c.CNGNFutureAssetAddress) != "" {
		list = append(list, FutureSeries{
			AssetAddress:   strings.ToLower(strings.TrimSpace(c.CNGNFutureAssetAddress)),
			Expiry:         c.CNGNFutureExpiry,
			ManagerAddress: strings.ToLower(strings.TrimSpace(c.CNGNFutureManagerAddress)),
			Kind:           FutureKindInverse,
			BaseAsset:      "cNGN",
			ContractSize:   LegacyFutureContractSize,
			CloseOnly:      c.CNGNFutureCloseOnly,
		})
	}
	return append(list, c.FutureSeries...)
}

// parseFutureSeries reads FUTURE_SERIES: a JSON array of FutureSeries, addresses lowercased. Empty is
// none. An unknown field is refused, so a misspelt close_only cannot leave a series open.
func parseFutureSeries(raw string) ([]FutureSeries, error) {
	if strings.TrimSpace(raw) == "" {
		return nil, nil
	}
	decoder := json.NewDecoder(bytes.NewReader([]byte(raw)))
	decoder.DisallowUnknownFields()
	var list []FutureSeries
	if err := decoder.Decode(&list); err != nil {
		return nil, fmt.Errorf("FUTURE_SERIES is not a JSON array of series: %w", err)
	}
	for i := range list {
		list[i].AssetAddress = strings.ToLower(strings.TrimSpace(list[i].AssetAddress))
		list[i].ManagerAddress = strings.ToLower(strings.TrimSpace(list[i].ManagerAddress))
		list[i].Kind = strings.TrimSpace(list[i].Kind)
		list[i].BaseAsset = strings.TrimSpace(list[i].BaseAsset)
		list[i].ContractSize = strings.TrimSpace(list[i].ContractSize)
		list[i].AmountScale = strings.TrimSpace(list[i].AmountScale)
		list[i].Symbol = strings.TrimSpace(list[i].Symbol)
	}
	return list, nil
}

// validateFutureStack refuses a partial or ambiguous futures configuration. Every series trades on the
// perp's TradeModule and settles in its cash, so it needs the shared stack (not the perp's listing: it
// runs with the perp delisted); without its expiry the venue would book orders under a series that does
// not exist, and without its manager it could not tell a paused engine from an open one. The fill band
// is read from the chain, so CHAIN_RPC_URL is required too: a future whose band cannot be read is a
// future whose fills cannot be checked. Two series may share an expiry, not an (asset, expiry) or a
// symbol: the book, the reader and the ledger are keyed by the one, the routes by the other.
func (c Config) validateFutureStack() error {
	if err := c.validateLegacyFuture(); err != nil {
		return err
	}
	for i, series := range c.FutureSeries {
		if err := series.validate(); err != nil {
			return fmt.Errorf("FUTURE_SERIES[%d]: %w", i, err)
		}
	}
	list := c.FutureSeriesList()
	if len(list) == 0 {
		return nil
	}
	if !c.PerpTradeStackConfigured() {
		return errors.New("a futures series is listed (CNGN_FUTURE_ASSET_ADDRESS or FUTURE_SERIES) without the shared stack (CNGN_PERP_TRADE_MODULE_ADDRESS, " +
			"CNGN_PERP_CASH_ADDRESS, CNGN_PERP_SRM_ADDRESS): the future trades on that TradeModule and settles in its cash")
	}
	if strings.TrimSpace(c.ChainRPCURL) == "" {
		return errors.New("a futures series is listed (CNGN_FUTURE_ASSET_ADDRESS or FUTURE_SERIES) without CHAIN_RPC_URL: the future's fill band is read from the chain")
	}
	keys, symbols := map[string]bool{}, map[string]bool{}
	for _, series := range list {
		symbol := series.MarketSymbol()
		if c.PerpEnabled() && strings.EqualFold(series.AssetAddress, c.CNGNPerpAssetAddress) {
			return fmt.Errorf("%s: CNGN_FUTURE_ASSET_ADDRESS is the perp's asset", symbol)
		}
		key := series.AssetAddress + ":" + series.SubID()
		if keys[key] {
			return fmt.Errorf("%s: two series are listed on asset %s at expiry %d", symbol, series.AssetAddress, series.Expiry)
		}
		if symbols[symbol] {
			return fmt.Errorf("two series are listed as %s: name one with symbol", symbol)
		}
		keys[key], symbols[symbol] = true, true
	}
	return nil
}

// validateLegacyFuture is the CNGN_FUTURE_* series: all three or none.
func (c Config) validateLegacyFuture() error {
	set := map[string]bool{
		"CNGN_FUTURE_ASSET_ADDRESS":   isConfiguredAddress(c.CNGNFutureAssetAddress),
		"CNGN_FUTURE_EXPIRY":          c.CNGNFutureExpiry > 0,
		"CNGN_FUTURE_MANAGER_ADDRESS": isConfiguredAddress(c.CNGNFutureManagerAddress),
	}
	var present, missing []string
	for _, name := range []string{"CNGN_FUTURE_ASSET_ADDRESS", "CNGN_FUTURE_EXPIRY", "CNGN_FUTURE_MANAGER_ADDRESS"} {
		if set[name] {
			present = append(present, name)
		} else {
			missing = append(missing, name)
		}
	}
	if len(present) != 0 && len(missing) != 0 {
		return fmt.Errorf("the future is configured partially: %s set but %s missing; set all three or none",
			strings.Join(present, ", "), strings.Join(missing, ", "))
	}
	if len(present) == 0 && c.CNGNFutureCloseOnly {
		return errors.New("CNGN_FUTURE_CLOSE_ONLY is set without the series it closes (CNGN_FUTURE_ASSET_ADDRESS)")
	}
	return nil
}

func (s FutureSeries) validate() error {
	switch {
	case !isConfiguredAddress(s.AssetAddress):
		return fmt.Errorf("asset_address %q is not an address", s.AssetAddress)
	case s.Expiry <= 0:
		return errors.New("expiry is not a unix timestamp")
	case !isConfiguredAddress(s.ManagerAddress):
		return fmt.Errorf("manager_address %q is not an address", s.ManagerAddress)
	case s.Kind != FutureKindInverse && s.Kind != FutureKindLinear:
		return fmt.Errorf("kind %q is neither %q (v1) nor %q (v2)", s.Kind, FutureKindInverse, FutureKindLinear)
	case s.BaseAsset == "":
		return errors.New("base_asset is required: the asset a contract is a number of (cNGN, EURC)")
	case s.Kind == FutureKindInverse && s.BaseAsset != "cNGN":
		return fmt.Errorf("an inverse series is cNGN's, not %s", s.BaseAsset)
	}
	size, ok := new(big.Rat).SetString(s.ContractSize)
	if !ok || size.Sign() <= 0 {
		return fmt.Errorf("contract_size %q is not a positive number", s.ContractSize)
	}
	scale, ok := new(big.Int).SetString(s.ScaledAmount(), 10)
	if !ok || scale.Sign() <= 0 {
		return fmt.Errorf("amount_scale %q is not a positive whole number, and 1e18 / contract_size is not one either: set it", s.AmountScale)
	}
	return nil
}
