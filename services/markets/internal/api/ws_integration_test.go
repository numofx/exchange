package api

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/numofx/matching-backend/internal/config"
	"github.com/numofx/matching-backend/internal/instruments"
	projectmigrations "github.com/numofx/matching-backend/migrations"
)

// TestWSBookEndToEnd drives the full handler: connect -> subscribe(book) -> snapshot ->
// insert an order -> live update. Set TEST_DATABASE_URL to run; skipped otherwise.
func TestWSBookEndToEnd(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set TEST_DATABASE_URL to run the WS integration test")
	}
	const asset = "0xdd9c2ddf97a2dc9b9d348dcd0ef776af5291a1f9"

	ctx, cancel := context.WithCancel(context.Background())
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		cancel()
		t.Fatalf("connect: %v", err)
	}
	defer pool.Close()
	defer cancel()
	wsApplyMigrations(ctx, t, pool)

	cfg := config.Config{
		EventsReconcileInterval: 500 * time.Millisecond,
		EventsSubBuffer:         64,
		WSAuthDomain:            "markets.numo.xyz",
		WSAuthMaxTTL:            5 * time.Minute,
		CNGNSpotAssetAddress:    asset, // enables the spot market in the registry
	}
	registry := instruments.DefaultRegistry(cfg)
	srv := NewServer(cfg, pool, registry)
	go func() { _ = srv.hub.Run(ctx) }()
	time.Sleep(150 * time.Millisecond) // let the hub establish LISTEN

	httpSrv := httptest.NewServer(http.HandlerFunc(srv.handleWS))
	defer httpSrv.Close()
	wsURL := "ws" + strings.TrimPrefix(httpSrv.URL, "http")

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "done")

	// subscribe to the (empty) book
	writeJSONFrame(ctx, t, conn, map[string]any{"op": "subscribe", "channel": "book", "market": instruments.CNGNSpotSymbol})

	snap := readFrame(ctx, t, conn)
	if snap.Type != "snapshot" || snap.Channel != "book" {
		t.Fatalf("expected book snapshot, got %+v", snap)
	}

	// place an order -> expect a live book update with seq > snapshot seq
	if _, err := pool.Exec(ctx, `insert into active_orders
		(order_id,owner_address,signer_address,subaccount_id,recipient_id,nonce,side,asset_address,sub_id,desired_amount,filled_amount,limit_price,limit_price_ticks,worst_fee,expiry,action_json,signature,status)
		values ('ws-ord-1','0xabc','0xsig',1,1,1,'buy',$1,0,'5','0','1380','1380','0',9999999999,'{}','0xsig','active')`, asset); err != nil {
		t.Fatalf("insert order: %v", err)
	}

	upd := readFrame(ctx, t, conn)
	if upd.Type != "update" || upd.Channel != "book" {
		t.Fatalf("expected book update, got %+v", upd)
	}
	if upd.Seq <= snap.Seq {
		t.Fatalf("update seq %d not after snapshot seq %d", upd.Seq, snap.Seq)
	}
	var payload struct {
		Side      string `json:"side"`
		SizeDelta string `json:"size_delta"`
	}
	if err := json.Unmarshal(upd.Data, &payload); err != nil {
		t.Fatalf("decode update payload: %v (%s)", err, upd.Data)
	}
	if payload.SizeDelta != "5" || payload.Side != "buy" {
		t.Fatalf("unexpected book delta: %+v", payload)
	}

	// ping/pong liveness
	writeJSONFrame(ctx, t, conn, map[string]any{"op": "ping"})
	if pong := readFrame(ctx, t, conn); pong.Type != "pong" {
		t.Fatalf("expected pong, got %+v", pong)
	}

	// unauthenticated orders subscribe must be rejected
	writeJSONFrame(ctx, t, conn, map[string]any{"op": "subscribe", "channel": "orders"})
	if e := readFrame(ctx, t, conn); e.Type != "error" || e.Code != "auth_required" {
		t.Fatalf("expected auth_required error, got %+v", e)
	}
}

type wsOutTest struct {
	Type    string          `json:"type"`
	Channel string          `json:"channel"`
	Market  string          `json:"market"`
	Seq     int64           `json:"seq"`
	Data    json.RawMessage `json:"data"`
	Code    string          `json:"code"`
	Message string          `json:"message"`
}

func writeJSONFrame(ctx context.Context, t *testing.T, conn *websocket.Conn, v any) {
	t.Helper()
	b, _ := json.Marshal(v)
	wctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if err := conn.Write(wctx, websocket.MessageText, b); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func readFrame(ctx context.Context, t *testing.T, conn *websocket.Conn) wsOutTest {
	t.Helper()
	rctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	_, data, err := conn.Read(rctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var f wsOutTest
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("unmarshal frame: %v (%s)", err, data)
	}
	return f
}

func wsApplyMigrations(ctx context.Context, t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	entries, err := fs.ReadDir(projectmigrations.Files, ".")
	if err != nil {
		t.Fatalf("read migrations: %v", err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".up.sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)
	for _, name := range files {
		b, err := fs.ReadFile(projectmigrations.Files, name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if _, err := pool.Exec(ctx, string(b)); err != nil {
			t.Fatalf("apply %s: %v", name, err)
		}
	}
}
