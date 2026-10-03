package api

import (
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/numofx/matching-backend/internal/config"
)

func gateForTest(enforce bool) *indexLagGate {
	g := newIndexLagGate(config.Config{IndexStatusToken: "t0k3n", IndexLagGate: enforce, IndexLagMaxBps: 100, IndexStatusMaxAge: 180 * time.Second})
	now := time.Unix(1_800_000_000, 0)
	g.now = func() time.Time { return now }
	return g
}

func TestIndexLagGateRefusesPastTheBoundAndWhenBlind(t *testing.T) {
	index := big.NewInt(720_000_000_000_000) // 0.00072 USDC per cNGN
	g := gateForTest(true)
	if err := g.allows(index); err == nil || !strings.Contains(err.Error(), "index_status_stale") {
		t.Fatalf("no sample yet must read as blind: %v", err)
	}
	at := g.now().Add(-30 * time.Second).UnixMilli()
	if err := g.record(indexStatusReport{AtMs: at, UsdcPerCngn: "0.000727", SampleOk: true}); err != nil { // +97 bps
		t.Fatal(err)
	}
	if err := g.allows(index); err != nil {
		t.Fatalf("97 bps is within the 100 bps bound: %v", err)
	}
	if err := g.record(indexStatusReport{AtMs: at + 1, UsdcPerCngn: "0.0007128", SampleOk: true}); err != nil { // -100 bps
		t.Fatal(err)
	}
	if err := g.allows(index); err != nil {
		t.Fatalf("exactly 100 bps below is within the bound: %v", err)
	}
	if err := g.record(indexStatusReport{AtMs: at + 2, UsdcPerCngn: "0.00072800", SampleOk: true}); err != nil { // +111 bps
		t.Fatal(err)
	}
	err := g.allows(index)
	if err == nil || !strings.Contains(err.Error(), "index_lag: the venue's spot sample is 111 bps") {
		t.Fatalf("111 bps must be refused with the figure: %v", err)
	}
	// A failed sample keeps the publisher alive but does not move the latest good one.
	if err := g.record(indexStatusReport{AtMs: at + 3, SampleOk: false}); err != nil {
		t.Fatal(err)
	}
	if bps, _, ok := g.lag(index); !ok || bps != 111 {
		t.Fatalf("lag after a failed sample = %d ok=%v, want 111 ok", bps, ok)
	}
	// Older than the max age: blind again.
	g.now = func() time.Time { return time.Unix(1_800_000_000, 0).Add(200 * time.Second) }
	if err := g.allows(index); err == nil || !strings.Contains(err.Error(), "index_status_stale") {
		t.Fatalf("a stale sample must read as blind: %v", err)
	}
	// Not enforcing: everything passes, but the lag is still reported.
	off := gateForTest(false)
	_ = off.record(indexStatusReport{AtMs: off.now().UnixMilli(), UsdcPerCngn: "0.0008", SampleOk: true})
	if err := off.allows(index); err != nil {
		t.Fatalf("gate off must allow: %v", err)
	}
	if p := off.presentation(index); p.Enforced || p.LagBps == nil || *p.LagBps != 1111 {
		t.Fatalf("presentation = %+v", p)
	}
}

func TestIndexStatusEndpointIsTokenGated(t *testing.T) {
	s := &Server{indexLag: gateForTest(true)}
	post := func(token, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/internal/index-status", strings.NewReader(body))
		if token != "" {
			req.Header.Set("X-Numo-Index-Token", token)
		}
		rec := httptest.NewRecorder()
		s.handleIndexStatus(rec, req)
		return rec
	}
	if rec := post("", `{"at_ms":1,"usdc_per_cngn":"0.00072","sample_ok":true}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", rec.Code)
	}
	if rec := post("wrong", `{"at_ms":1,"usdc_per_cngn":"0.00072","sample_ok":true}`); rec.Code != http.StatusUnauthorized {
		t.Fatalf("wrong token: %d", rec.Code)
	}
	if rec := post("t0k3n", `{"at_ms":1,"usdc_per_cngn":"nope","sample_ok":true}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("bad decimal: %d", rec.Code)
	}
	if rec := post("t0k3n", `{"at_ms":1800000000000,"usdc_per_cngn":"0.00072","sample_ok":true}`); rec.Code != http.StatusNoContent {
		t.Fatalf("good report: %d %s", rec.Code, rec.Body.String())
	}
	unconfigured := &Server{}
	if rec := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/v1/internal/index-status", strings.NewReader(`{}`))
		rec := httptest.NewRecorder()
		unconfigured.handleIndexStatus(rec, req)
		return rec
	}(); rec.Code != http.StatusNotFound {
		t.Fatalf("unconfigured: %d", rec.Code)
	}
}
