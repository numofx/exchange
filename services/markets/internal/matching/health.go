package matching

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"github.com/numofx/matching-backend/internal/orders"
)

const (
	// matcherStaleAfter is how long without a completed tick before the matcher calls itself
	// unhealthy: the poll interval is 250ms and one tick settles at most one fill per market (the
	// executor waits for a receipt, up to EXECUTOR_TIMEOUT), so a healthy matcher completes a cycle
	// well inside this. ECS restarts the task on a failing probe.
	matcherStaleAfter = 2 * time.Minute
	// heartbeatEvery is how often the matcher writes service_heartbeats; the pager reads it through
	// markets-service and pages when it is older than its own threshold (60s).
	heartbeatEvery   = 5 * time.Second
	heartbeatService = "matcher"
)

// indexerStatus is what the position indexer last did; see positionIndexer.
type indexerStatus struct {
	CursorBlock   uint64    `json:"cursor_block"`
	HeadBlock     uint64    `json:"head_block"`
	LagBlocks     uint64    `json:"lag_blocks"`
	LastAppliedAt time.Time `json:"last_applied_at"`
	LastError     string    `json:"last_error,omitempty"`
}

// matcherStatus is the matcher's own account of itself: served on its /healthz for ECS, written to
// service_heartbeats for the pager.
type matcherStatus struct {
	StartedAt      time.Time      `json:"started_at"`
	LastTickAt     time.Time      `json:"last_tick_at"`
	TickAgeSeconds float64        `json:"tick_age_seconds"`
	Healthy        bool           `json:"healthy"`
	Indexer        *indexerStatus `json:"indexer,omitempty"`
}

// matcherHealth collects the matcher's liveness from the tick loop and the indexer.
type matcherHealth struct {
	mu         sync.Mutex
	startedAt  time.Time
	lastTickAt time.Time
	indexer    *positionIndexer
	now        func() time.Time
}

func newMatcherHealth(indexer *positionIndexer) *matcherHealth {
	now := time.Now()
	return &matcherHealth{startedAt: now, lastTickAt: now, indexer: indexer, now: time.Now}
}

// ticked records one completed pass over every enabled market.
func (h *matcherHealth) ticked() {
	h.mu.Lock()
	h.lastTickAt = h.now()
	h.mu.Unlock()
}

func (h *matcherHealth) status() matcherStatus {
	h.mu.Lock()
	last, started := h.lastTickAt, h.startedAt
	h.mu.Unlock()
	age := h.now().Sub(last)
	status := matcherStatus{StartedAt: started, LastTickAt: last, TickAgeSeconds: age.Seconds(), Healthy: age < matcherStaleAfter}
	if h.indexer != nil {
		s := h.indexer.status()
		status.Indexer = &s
	}
	return status
}

// serve answers GET /healthz with the status, 200 while the tick loop is alive and 503 once it has
// stalled, until ctx ends. The distroless image has no shell, so the container probe is the matcher
// binary itself calling this (cmd/matcher -healthcheck).
func (h *matcherHealth) serve(ctx context.Context, addr string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		status := h.status()
		w.Header().Set("content-type", "application/json")
		if !status.Healthy {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(status)
	})
	server := &http.Server{Addr: addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	slog.Info("matcher_health_listening", "addr", addr)
	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		slog.Error("matcher_health_server_failed", "addr", addr, "error", err)
	}
}

// heartbeat writes the status to service_heartbeats, at most every heartbeatEvery.
type heartbeat struct {
	orders *orders.Repository
	health *matcherHealth
	last   time.Time
}

func (b *heartbeat) maybeBeat(ctx context.Context) {
	if time.Since(b.last) < heartbeatEvery {
		return
	}
	b.last = time.Now()
	writeCtx, cancel := detachedContext(ctx, 3*time.Second)
	defer cancel()
	if err := b.orders.RecordHeartbeat(writeCtx, heartbeatService, b.health.status()); err != nil {
		slog.Warn("matcher_heartbeat_failed", "error", err)
	}
}
