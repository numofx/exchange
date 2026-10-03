package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

// The index-lag gate. The perp's on-chain index is a TWAP republished on an interval, so for a
// while after a real move the venue's quotes rest at a price the market has left. Anyone who sees
// spot move first can open against those quotes and close once the index catches up: a transfer
// from the maker, made cheaper by leverage. The publisher (perp-feeds) therefore reports every
// spot sample it takes here, and while the latest good sample is more than INDEX_LAG_MAX_BPS from
// the on-chain index, new perp orders are refused until the index has caught up. Resting orders,
// cancels and liquidations are untouched: only new exposure waits.
//
// A sample the venue has not heard for INDEX_STATUS_MAX_AGE_SEC reads as blind, and a blind venue
// refuses new perp orders too: an index it cannot check is the condition the gate exists for.
//
// Enforcement is a separate switch (INDEX_LAG_GATE) from the status endpoint, so the publisher can
// be seen pushing and the lag watched on /v1/markets before anything is refused.

type indexStatusReport struct {
	// AtMs is the sample's time, Unix ms, from the publisher's clock.
	AtMs int64 `json:"at_ms"`
	// UsdcPerCngn is the sample's spot in the engine's orientation, 18dp decimal string, or empty
	// when the sample failed (the publisher still reports, so the venue knows it is alive but blind).
	UsdcPerCngn string `json:"usdc_per_cngn"`
	SampleOk    bool   `json:"sample_ok"`
}

type indexSample struct {
	usdcPerCngn *big.Int
	at          time.Time
}

// indexLagGate holds the latest good spot sample and decides whether new perp orders may open.
type indexLagGate struct {
	token   string
	maxBps  int64
	maxAge  time.Duration
	enforce bool
	now     func() time.Time

	mu       sync.Mutex
	latest   *indexSample
	lastSeen time.Time // any report, good or failed: whether the publisher is alive
}

func newIndexLagGate(cfg config.Config) *indexLagGate {
	if strings.TrimSpace(cfg.IndexStatusToken) == "" {
		return nil
	}
	return &indexLagGate{
		token:   strings.TrimSpace(cfg.IndexStatusToken),
		maxBps:  int64(cfg.IndexLagMaxBps),
		maxAge:  cfg.IndexStatusMaxAge,
		enforce: cfg.IndexLagGate,
		now:     time.Now,
	}
}

var (
	errIndexBlind = errors.New("index_status_stale: the venue has no fresh spot sample to check the perp index against; new perp orders resume when the index publisher reports")
)

// record stores a report. A failed sample marks the publisher alive without moving the latest good sample.
func (g *indexLagGate) record(report indexStatusReport) error {
	at := time.UnixMilli(report.AtMs)
	g.mu.Lock()
	defer g.mu.Unlock()
	g.lastSeen = g.now()
	if !report.SampleOk {
		return nil
	}
	spot, err := parseE18(report.UsdcPerCngn)
	if err != nil || spot.Sign() <= 0 {
		return fmt.Errorf("usdc_per_cngn must be a positive 18dp decimal")
	}
	if g.latest == nil || at.After(g.latest.at) {
		g.latest = &indexSample{usdcPerCngn: spot, at: at}
	}
	return nil
}

// lag is the latest good sample's distance from the on-chain index in bps (positive: spot above
// the index, i.e. cNGN stronger than the index says), and its age; ok is false when the venue is
// blind (no sample, or one older than maxAge).
func (g *indexLagGate) lag(onChainIndex *big.Int) (bps int64, age time.Duration, ok bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.latest == nil || onChainIndex == nil || onChainIndex.Sign() <= 0 {
		return 0, 0, false
	}
	age = g.now().Sub(g.latest.at)
	if age > g.maxAge {
		return 0, age, false
	}
	diff := new(big.Int).Sub(g.latest.usdcPerCngn, onChainIndex)
	diff.Mul(diff, big.NewInt(10_000))
	diff.Quo(diff, onChainIndex)
	return diff.Int64(), age, true
}

// allows is the gate's answer for a new perp order against the on-chain index. Nil when not
// enforcing, or when spot is within the bound.
func (g *indexLagGate) allows(onChainIndex *big.Int) error {
	if !g.enforce {
		return nil
	}
	bps, _, ok := g.lag(onChainIndex)
	if !ok {
		return errIndexBlind
	}
	if bps > g.maxBps || bps < -g.maxBps {
		return fmt.Errorf("index_lag: the venue's spot sample is %d bps from the perp's on-chain index (limit %d); new perp orders resume when the index catches up", bps, g.maxBps)
	}
	return nil
}

// presentation is what /v1/markets shows under the perp block.
func (g *indexLagGate) presentation(onChainIndex *big.Int) indexLagPresentation {
	bps, age, ok := g.lag(onChainIndex)
	p := indexLagPresentation{Enforced: g.enforce, MaxBps: g.maxBps}
	if ok {
		p.LagBps = &bps
	}
	g.mu.Lock()
	if g.latest != nil {
		p.SpotSampleAt = g.latest.at.Unix()
		p.SpotUsdcPerCngn = e18String(g.latest.usdcPerCngn)
	}
	g.mu.Unlock()
	if ok {
		p.SampleAgeSec = int64(age / time.Second)
	}
	return p
}

type indexLagPresentation struct {
	Enforced bool  `json:"enforced"`
	MaxBps   int64 `json:"max_bps"`
	// LagBps is spot's distance from the on-chain index; absent when the venue is blind.
	LagBps          *int64 `json:"lag_bps,omitempty"`
	SpotSampleAt    int64  `json:"spot_sample_at,omitempty"`
	SpotUsdcPerCngn string `json:"spot_usdc_per_cngn,omitempty"`
	SampleAgeSec    int64  `json:"sample_age_sec,omitempty"`
}

// handleIndexStatus is POST /v1/internal/index-status: the publisher's report, token-authenticated.
func (s *Server) handleIndexStatus(w http.ResponseWriter, r *http.Request) {
	if s.indexLag == nil {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "index status is not configured"})
		return
	}
	presented := strings.TrimSpace(r.Header.Get("X-Numo-Index-Token"))
	if presented == "" || subtle.ConstantTimeCompare([]byte(presented), []byte(s.indexLag.token)) != 1 {
		writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "bad index status token"})
		return
	}
	var report indexStatusReport
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&report); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}
	if report.AtMs <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "at_ms is required"})
		return
	}
	if err := s.indexLag.record(report); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// parseE18 reads a decimal string with up to 18 fractional digits as an 18dp integer.
func parseE18(value string) (*big.Int, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil, errors.New("empty")
	}
	rat, ok := new(big.Rat).SetString(value)
	if !ok {
		return nil, errors.New("not a decimal")
	}
	scaled := new(big.Rat).Mul(rat, new(big.Rat).SetInt(perpE18))
	if !scaled.IsInt() {
		return nil, errors.New("more than 18 fractional digits")
	}
	return new(big.Int).Set(scaled.Num()), nil
}
