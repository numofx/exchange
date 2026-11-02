package config

import (
	"strings"
	"testing"
)

func optionSeriesFixture() OptionSeries {
	fee := 300
	return OptionSeries{
		AssetAddress:   "0x00000000000000000000000000000000000000a1",
		ManagerAddress: "0x0705219a1594d5fc5dc2573da4082caf3e1b0950",
		VolFeedAddress: "0x00000000000000000000000000000000000000a2",
		BaseAsset:      "cNGN",
		Expiry:         1796047200,
		Strikes:        []string{"0.00072", "1.15"},
		AmountScale:    "1000000000000000000000",
		TakerFeeBps:    &fee,
	}
}

// Sub ids as the deployed OptionAsset computes them: getSubId(expiry, strike, isCall) called on the compiled
// contract on anvil, 2026-11-01. A sub id that disagrees books every order under an option that does not exist.
func TestOptionSubIDsMatchOptionAsset(t *testing.T) {
	series := optionSeriesFixture()
	series.Strikes = []string{"0.00072", "0.00072165", "1.15"}
	contracts, err := series.Contracts()
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"cNGN-30NOV26-0.00072-C":    "39614081257132478036213334368",
		"cNGN-30NOV26-0.00072-P":    "309239441359200",
		"cNGN-30NOV26-0.00072165-P": "309948110963040",
		"cNGN-30NOV26-1.15-C":       "39614081257626090037608022368",
	}
	got := map[string]string{}
	for _, c := range contracts {
		got[c.MarketSymbol()] = c.SubID()
	}
	for symbol, subID := range want {
		if got[symbol] != subID {
			t.Errorf("%s: sub id %s, OptionAsset computes %s", symbol, got[symbol], subID)
		}
	}
	if len(contracts) != 6 {
		t.Fatalf("3 strikes are 6 markets, got %d", len(contracts))
	}
}

func TestOptionStrikeGrid(t *testing.T) {
	for _, strike := range []string{"0.000720000000000001", "0", "-1", "abc", "0.000000001"} {
		if _, err := StrikeWei(strike); err == nil {
			t.Errorf("strike %q accepted", strike)
		}
	}
	if wei, err := StrikeWei("0.00000001"); err != nil || wei.String() != "10000000000" {
		t.Errorf("1e-8 is the finest strike: %v %v", wei, err)
	}
}

func TestOptionSeriesValidation(t *testing.T) {
	if err := optionSeriesFixture().validate(); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	for name, mutate := range map[string]func(*OptionSeries){
		"no vol feed":          func(s *OptionSeries) { s.VolFeedAddress = "" },
		"no strikes":           func(s *OptionSeries) { s.Strikes = nil },
		"duplicate strike":     func(s *OptionSeries) { s.Strikes = []string{"0.00072", "0.000720"} },
		"granular strike":      func(s *OptionSeries) { s.Strikes = []string{"0.000720000001"} },
		"no amount scale":      func(s *OptionSeries) { s.AmountScale = "" },
		"last trade at expiry": func(s *OptionSeries) { s.LastTradeTime = s.Expiry },
		"expiry past 32 bits":  func(s *OptionSeries) { s.Expiry = 1 << 33 },
		"fee out of range":     func(s *OptionSeries) { fee := MaxOptionTakerFeeBps + 1; s.TakerFeeBps = &fee },
		"no base":              func(s *OptionSeries) { s.BaseAsset = "" },
	} {
		s := optionSeriesFixture()
		mutate(&s)
		if err := s.validate(); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	s := optionSeriesFixture()
	if s.TradingEnds() != s.Expiry-3600 {
		t.Errorf("trading ends an hour before expiry by default, got %d", s.TradingEnds())
	}
}

func TestParseOptionSeriesRefusesUnknownFields(t *testing.T) {
	if _, err := parseOptionSeries(`[{"asset_address":"0x00000000000000000000000000000000000000A1","close_onyl":true}]`); err == nil {
		t.Fatal("a misspelt field was accepted")
	}
	if _, err := parseOptionSeries(`[{"asset_address":"0x00000000000000000000000000000000000000A1","close_only":true}]`); err == nil {
		t.Fatal("close_only is not supported on options yet, and must not be silently ignored")
	}
	list, err := parseOptionSeries(`[{"asset_address":" 0x00000000000000000000000000000000000000A1 ","strikes":[" 0.00072 "]}]`)
	if err != nil || list[0].AssetAddress != "0x00000000000000000000000000000000000000a1" || list[0].Strikes[0] != "0.00072" {
		t.Fatalf("normalised: %+v %v", list, err)
	}
}

func TestOptionStackNeedsTheSharedStackAndUniqueMarkets(t *testing.T) {
	cfg := Config{OptionSeries: []OptionSeries{optionSeriesFixture()}}
	if err := cfg.validateOptionStack(); err == nil || !strings.Contains(err.Error(), "shared stack") {
		t.Fatalf("no shared stack: %v", err)
	}
	cfg.CNGNPerpTradeModuleAddress = "0x00000000000000000000000000000000000000b1"
	cfg.CNGNPerpCashAddress = "0x00000000000000000000000000000000000000b2"
	cfg.CNGNPerpSRMAddress = "0x00000000000000000000000000000000000000b3"
	if err := cfg.validateOptionStack(); err == nil || !strings.Contains(err.Error(), "CHAIN_RPC_URL") {
		t.Fatalf("no RPC: %v", err)
	}
	cfg.ChainRPCURL = "http://rpc"
	if err := cfg.validateOptionStack(); err != nil {
		t.Fatalf("complete: %v", err)
	}
	cfg.OptionSeries = append(cfg.OptionSeries, optionSeriesFixture())
	if err := cfg.validateOptionStack(); err == nil || !strings.Contains(err.Error(), "listed twice") {
		t.Fatalf("the same series twice: %v", err)
	}
}
