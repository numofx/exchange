package instruments

import "time"

const (
	PricingModelLinear   = "linear"
	PricingModelVariance = "variance"
	PricingModelVol      = "volatility"

	DisplayPriceDirect     = "direct"
	DisplayPriceVolPercent = "vol_percent"
)

type Metadata struct {
	Symbol             string        `json:"symbol"`
	AssetAddress       string        `json:"asset_address"`
	SubID              string        `json:"sub_id"`
	ContractType       string        `json:"contract_type,omitempty"`
	SettlementType     string        `json:"settlement_type,omitempty"`
	BaseAssetSymbol    string        `json:"base_asset_symbol,omitempty"`
	QuoteAssetSymbol   string        `json:"quote_asset_symbol,omitempty"`
	ExpiryTimestamp    int64         `json:"expiry_timestamp,omitempty"`
	LastTradeTimestamp int64         `json:"last_trade_timestamp,omitempty"`
	TickSize           string        `json:"tick_size"`
	MinSize            string        `json:"min_size"`
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
	Enabled            bool          `json:"enabled"`
}

type Registry struct {
	items           []Metadata
	bySymbol        map[string]Metadata
	byAssetAndSubID map[string]Metadata
}

func NewRegistry(items []Metadata) *Registry {
	registry := &Registry{
		items:           append([]Metadata(nil), items...),
		bySymbol:        make(map[string]Metadata, len(items)),
		byAssetAndSubID: make(map[string]Metadata, len(items)),
	}

	for _, item := range items {
		registry.bySymbol[item.Symbol] = item
		if alias := symbolAlias(item.Symbol); alias != "" {
			registry.bySymbol[alias] = item
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

func assetAndSubIDKey(assetAddress, subID string) string {
	return assetAddress + "|" + subID
}

func symbolAlias(symbol string) string {
	switch symbol {
	case CNGNJun2026Symbol:
		return CNGNJun2026LegacySymbol
	case CNGNNov2026Symbol:
		return CNGNNov2026LegacySymbol
	case CNGNMay2027Symbol:
		return CNGNMay2027LegacySymbol
	default:
		return ""
	}
}
