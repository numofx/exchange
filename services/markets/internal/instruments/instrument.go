package instruments

import (
	"strings"
	"time"
)

const (
	ContractTypeSpot      = "spot"
	ContractTypePerpetual = "perpetual"
)

// IsPerpetual reports whether the market is the perp, whose fills move margin, not balances.
func (m Metadata) IsPerpetual() bool {
	return m.ContractType == ContractTypePerpetual
}

const (
	PricingModelLinear   = "linear"
	PricingModelVariance = "variance"
	PricingModelVol      = "volatility"

	DisplayPriceDirect     = "direct"
	DisplayPriceVolPercent = "vol_percent"
)

type Metadata struct {
	Symbol string `json:"symbol"`
	// Aliases are deprecated identifiers for this market, accepted on input by exact match and
	// never emitted: a response always names the market by Symbol.
	Aliases            []string `json:"-"`
	AssetAddress       string   `json:"asset_address"`
	SubID              string   `json:"sub_id"`
	ContractType       string   `json:"contract_type,omitempty"`
	SettlementType     string   `json:"settlement_type,omitempty"`
	BaseAssetSymbol    string   `json:"base_asset_symbol,omitempty"`
	QuoteAssetSymbol   string   `json:"quote_asset_symbol,omitempty"`
	ExpiryTimestamp    int64    `json:"expiry_timestamp,omitempty"`
	LastTradeTimestamp int64    `json:"last_trade_timestamp,omitempty"`
	TickSize           string   `json:"tick_size"`
	MinSize            string   `json:"min_size"`
	// TakerFeeBps and MakerFeeBps are THE fee schedule for this market, in basis points of the
	// quote notional. Everything downstream reads them from here: the matcher charges them, the
	// funding check reserves them, and /v1/markets serves them so the UI never carries its own
	// copy. A fee that lives in two repos disagrees the first time one of them changes.
	TakerFeeBps        int           `json:"taker_fee_bps"`
	MakerFeeBps        int           `json:"maker_fee_bps"`
	ContractMultiplier string        `json:"contract_multiplier"`
	QuotePrecision     int           `json:"quote_precision"`
	PricingModel       string        `json:"pricing_model,omitempty"`
	PriceSemantics     string        `json:"price_semantics,omitempty"`
	DisplayPriceKind   string        `json:"display_price_kind,omitempty"`
	DisplaySemantics   string        `json:"display_semantics,omitempty"`
	DisplayLabel       string        `json:"display_label,omitempty"`
	DisplayName        string        `json:"display_name,omitempty"`
	SettlementNote     string        `json:"settlement_note,omitempty"`
	OrderEntrySpec     string        `json:"order_entry_spec,omitempty"`
	UIPriceUnit        string        `json:"ui_price_unit,omitempty"`
	UISizeUnit         string        `json:"ui_size_unit,omitempty"`
	UISideMeaning      string        `json:"ui_side_meaning,omitempty"`
	EnginePriceUnit    string        `json:"engine_price_unit,omitempty"`
	EngineAmountUnit   string        `json:"engine_amount_unit,omitempty"`
	EngineSidePolicy   string        `json:"engine_side_policy,omitempty"`
	UIPriceToEngine    string        `json:"ui_price_to_engine,omitempty"`
	UISizeToEngine     string        `json:"ui_size_to_engine,omitempty"`
	FundingInterval    time.Duration `json:"-"`
	// Where this market settles. Per market because the perp runs on its own stack: its orders name
	// its own TradeModule, which settles in its own CashAsset, margined by its own SRM. Spot's are
	// the process-wide TRADE_MODULE_ADDRESS / QUOTE_ASSET_ADDRESS, exactly as before.
	TradeModuleAddress   string `json:"trade_module_address,omitempty"`
	QuoteAssetAddress    string `json:"quote_asset_address,omitempty"`
	MarginManagerAddress string `json:"margin_manager_address,omitempty"`
	// CollateralAssetAddress is a base asset the margin manager credits besides cash (the perp's
	// cNGN escrow); empty when margin is cash only.
	CollateralAssetAddress string `json:"collateral_asset_address,omitempty"`
	Enabled                bool   `json:"enabled"`
}

type Registry struct {
	items           []Metadata
	bySymbol        map[string]Metadata
	byAlias         map[string]Metadata
	byAssetAndSubID map[string]Metadata
}

func NewRegistry(items []Metadata) *Registry {
	registry := &Registry{
		items:           append([]Metadata(nil), items...),
		bySymbol:        make(map[string]Metadata, len(items)),
		byAlias:         make(map[string]Metadata),
		byAssetAndSubID: make(map[string]Metadata, len(items)),
	}

	for _, item := range items {
		registry.bySymbol[item.Symbol] = item
		for _, alias := range item.Aliases {
			registry.byAlias[alias] = item
		}
		if item.AssetAddress != "" && item.SubID != "" {
			registry.byAssetAndSubID[assetAndSubIDKey(item.AssetAddress, item.SubID)] = item
		}
	}

	return registry
}

func (r *Registry) Enabled() []Metadata {
	if r == nil {
		return nil
	}

	items := make([]Metadata, 0, len(r.items))
	for _, item := range r.items {
		if item.Enabled {
			items = append(items, item)
		}
	}
	return items
}

func (r *Registry) BySymbol(symbol string) (Metadata, bool) {
	if r == nil {
		return Metadata{}, false
	}
	item, ok := r.bySymbol[symbol]
	return item, ok
}

func (r *Registry) ByAssetAddress(assetAddress string) (Metadata, bool) {
	if r == nil {
		return Metadata{}, false
	}
	item, ok := r.byAssetAndSubID[assetAndSubIDKey(assetAddress, "0")]
	return item, ok
}

func (r *Registry) ByAssetAndSubID(assetAddress, subID string) (Metadata, bool) {
	if r == nil {
		return Metadata{}, false
	}
	item, ok := r.byAssetAndSubID[assetAndSubIDKey(assetAddress, subID)]
	return item, ok
}

// Resolve maps a client-supplied market identifier to an enabled instrument by exact match: the
// instrument's symbol as listed, one of its deprecated aliases, or the "asset_address:sub_id"
// form. Nothing else matches -- no prefix, no case-folding of the symbol, and no default market --
// so an identifier the venue does not list is refused rather than answered with another market's
// data. Every endpoint that takes a symbol, market or ticker_id resolves it here. (The address half
// of the asset form is lower-cased: a hex address has no case of its own.)
func (r *Registry) Resolve(identifier string) (Metadata, bool) {
	item, _, ok := r.ResolveIdentifier(identifier)
	return item, ok
}

// ResolveIdentifier is Resolve, also reporting whether the identifier was a deprecated alias, so
// the caller can say so (a Deprecation header) while answering under the canonical name.
func (r *Registry) ResolveIdentifier(identifier string) (item Metadata, deprecated bool, ok bool) {
	if r == nil {
		return Metadata{}, false, false
	}
	identifier = strings.TrimSpace(identifier)
	if identifier == "" {
		return Metadata{}, false, false
	}
	if item, ok := r.bySymbol[identifier]; ok && item.servable() {
		return item, false, true
	}
	if item, ok := r.byAlias[identifier]; ok && item.servable() {
		return item, true, true
	}
	if i := strings.Index(identifier, ":"); i > 0 {
		key := assetAndSubIDKey(strings.ToLower(identifier[:i]), identifier[i+1:])
		if item, ok := r.byAssetAndSubID[key]; ok && item.servable() {
			return item, false, true
		}
	}
	return Metadata{}, false, false
}

// Identifiers lists the canonical symbols Resolve accepts, in listing order, for the error that
// refuses an unknown one. Deprecated aliases are accepted but not advertised.
func (r *Registry) Identifiers() []string {
	if r == nil {
		return nil
	}
	out := make([]string, 0, len(r.items))
	for _, item := range r.items {
		if item.servable() {
			out = append(out, item.Symbol)
		}
	}
	return out
}

// servable reports whether the market can answer a request: enabled, with an asset to read.
func (m Metadata) servable() bool {
	return m.Enabled && m.AssetAddress != ""
}

func assetAndSubIDKey(assetAddress, subID string) string {
	return assetAddress + "|" + subID
}
