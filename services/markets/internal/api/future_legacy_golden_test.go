package api

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// legacyListingGolden is the /v1/markets entry today's deployment serves for its one series
// (CNGN_FUTURE_ASSET_ADDRESS / CNGN_FUTURE_EXPIRY / CNGN_FUTURE_MANAGER_ADDRESS), captured before the
// series list existed (exchange #228). Regenerate only for a change meant to reach that listing:
// UPDATE_GOLDEN=1 go test ./internal/api -run TestTheLegacySingleSeriesConfigServesTodaysListing
var legacyListingGolden = filepath.Join("testdata", "legacy_future_listing.golden.json")

// The single-series envs alone, as every deployment sets them today, produce the same /v1/markets
// entry, byte for byte but for the clock (updated_at, and the stub's last trade time, set from now).
func TestTheLegacySingleSeriesConfigServesTodaysListing(t *testing.T) {
	rpc := newFutureRPC()
	srv := rpc.server(t)
	defer srv.Close()
	s := futureServer(t, srv.URL)

	rec := httptest.NewRecorder()
	s.handleMarkets(rec, httptest.NewRequest(http.MethodGet, "/v1/markets", nil))
	var entries []map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &entries); err != nil {
		t.Fatalf("markets: %v %s", err, rec.Body.String())
	}
	for _, entry := range entries {
		if future, ok := entry["future"].(map[string]any); ok {
			future["updated_at"] = "<clock>"
			future["last_trade_time"] = "<clock>"
		}
	}
	got, _ := json.MarshalIndent(entries, "", "  ")
	got = append(got, '\n')

	if os.Getenv("UPDATE_GOLDEN") != "" {
		if err := os.MkdirAll(filepath.Dir(legacyListingGolden), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(legacyListingGolden, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(legacyListingGolden)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != string(want) {
		t.Fatalf("the legacy config's /v1/markets changed:\n got %s\nwant %s", got, want)
	}
}
