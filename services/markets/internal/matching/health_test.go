package matching

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestMatcherHealthTurnsUnhealthyWhenTicksStop(t *testing.T) {
	clock := time.Date(2026, 10, 4, 20, 0, 0, 0, time.UTC)
	h := newMatcherHealth(nil)
	h.now = func() time.Time { return clock }
	h.ticked()
	if s := h.status(); !s.Healthy || s.TickAgeSeconds != 0 {
		t.Fatalf("fresh tick must be healthy: %+v", s)
	}
	clock = clock.Add(matcherStaleAfter - time.Second)
	if s := h.status(); !s.Healthy {
		t.Fatalf("under the stale threshold must still be healthy: %+v", s)
	}
	clock = clock.Add(2 * time.Second)
	if s := h.status(); s.Healthy {
		t.Fatalf("past the stale threshold must be unhealthy: %+v", s)
	}
}

func TestHealthzAnswers503OnceStalled(t *testing.T) {
	clock := time.Now()
	h := newMatcherHealth(nil)
	h.now = func() time.Time { return clock }
	h.ticked()
	handler := http.NewServeMux()
	handler.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		status := h.status()
		if !status.Healthy {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(status)
	})
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("alive matcher: %d", rec.Code)
	}
	clock = clock.Add(matcherStaleAfter + time.Second)
	rec = httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("stalled matcher must answer 503: %d", rec.Code)
	}
}

func TestIndexerStatusReportsLagAndLastError(t *testing.T) {
	p := &positionIndexer{}
	p.note(func(s *indexerStatus) { s.HeadBlock = 1000; s.CursorBlock = 940 })
	if s := p.status(); s.LagBlocks != 60 {
		t.Fatalf("lag %d, want 60", s.LagBlocks)
	}
	p.note(func(s *indexerStatus) { s.CursorBlock = 1000; s.LastError = "rpc down" })
	if s := p.status(); s.LagBlocks != 0 || s.LastError != "rpc down" {
		t.Fatalf("%+v", s)
	}
}
