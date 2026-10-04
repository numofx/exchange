package orders

import (
	"context"
	"encoding/json"
	"testing"
	"time"
)

func TestHeartbeatRoundTripsAndAgesOnTheDatabaseClock(t *testing.T) {
	pool := openTestPool(t)
	repo := NewRepository(pool)
	ctx := context.Background()
	service := "it-matcher-" + time.Now().Format("150405.000")
	t.Cleanup(func() { _, _ = pool.Exec(ctx, "delete from service_heartbeats where service = $1", service) })

	if _, _, ok, err := repo.ReadHeartbeat(ctx, service); err != nil || ok {
		t.Fatalf("unknown service must read as absent: ok=%v err=%v", ok, err)
	}
	if err := repo.RecordHeartbeat(ctx, service, map[string]any{"indexer": map[string]any{"cursor_block": 42}}); err != nil {
		t.Fatal(err)
	}
	beat, dbNow, ok, err := repo.ReadHeartbeat(ctx, service)
	if err != nil || !ok {
		t.Fatalf("read: ok=%v err=%v", ok, err)
	}
	if age := dbNow.Sub(beat.LastSeenAt); age < 0 || age > 5*time.Second {
		t.Fatalf("a fresh heartbeat must be fresh on the database clock: %s", age)
	}
	var details struct {
		Indexer struct {
			CursorBlock int `json:"cursor_block"`
		} `json:"indexer"`
	}
	if err := json.Unmarshal(beat.Details, &details); err != nil || details.Indexer.CursorBlock != 42 {
		t.Fatalf("details %s: %v", beat.Details, err)
	}
	// A second write replaces, never duplicates.
	if err := repo.RecordHeartbeat(ctx, service, map[string]any{"indexer": map[string]any{"cursor_block": 43}}); err != nil {
		t.Fatal(err)
	}
	var rows int
	if err := pool.QueryRow(ctx, "select count(*) from service_heartbeats where service = $1", service).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("rows %d err %v", rows, err)
	}
}
