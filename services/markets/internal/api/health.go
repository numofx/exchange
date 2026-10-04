package api

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"
)

// matcherHeartbeatStaleAfter: a heartbeat older than this is reported as "stale"; the matcher writes
// one every 5 seconds while its tick loop runs.
const matcherHeartbeatStaleAfter = 60 * time.Second

type healthResponse struct {
	// Status is "ok" when the matcher's heartbeat is fresh, "stale" when it is old, "unknown" when
	// it has never been written (or the database could not be read).
	Status  string         `json:"status"`
	Now     time.Time      `json:"now"`
	Matcher *matcherReport `json:"matcher,omitempty"`
	Error   string         `json:"error,omitempty"`
}

type matcherReport struct {
	LastSeenAt time.Time       `json:"last_seen_at"`
	AgeSeconds float64         `json:"age_seconds"`
	Details    json.RawMessage `json:"details"`
}

// handleHealthReport serves GET /v1/health: the matcher's last heartbeat (service_heartbeats) and
// its age on the database's clock, for the pager outside the cluster. /healthz stays this process's
// own liveness. Always 200: the pager reads the body; a 5xx here would only hide the matcher's
// state behind the API's.
func (s *Server) handleHealthReport(w http.ResponseWriter, r *http.Request) {
	response := healthResponse{Status: "unknown", Now: time.Now().UTC()}
	if s.orders == nil {
		writeJSON(w, http.StatusOK, response)
		return
	}
	beat, dbNow, ok, err := s.orders.ReadHeartbeat(r.Context(), "matcher")
	if err != nil {
		slog.Warn("health_heartbeat_unreadable", "error", err)
		response.Error = "heartbeat unreadable"
		writeJSON(w, http.StatusOK, response)
		return
	}
	if !ok {
		writeJSON(w, http.StatusOK, response)
		return
	}
	age := dbNow.Sub(beat.LastSeenAt)
	response.Now = dbNow.UTC()
	response.Matcher = &matcherReport{LastSeenAt: beat.LastSeenAt.UTC(), AgeSeconds: age.Seconds(), Details: beat.Details}
	response.Status = "ok"
	if age > matcherHeartbeatStaleAfter {
		response.Status = "stale"
	}
	writeJSON(w, http.StatusOK, response)
}
