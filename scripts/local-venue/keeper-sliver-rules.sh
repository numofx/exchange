#!/usr/bin/env bash
# The keeper finishes what it starts, and the matcher is watched (after up.sh, plain venue):
#   1. a solvent liquidation leaves a sliver; the keeper's own finishing bid ends the auction (no
#      outside liquidator), and the owner's Close sized from the pre-liquidation position ends flat
#   2. the keeper's /health lists open auctions while one runs, and an auction open past
#      AUCTION_OPEN_WARN_MS raises auction-open-<id> (run up.sh with AUCTION_OPEN_WARN_MS=20000 to see it)
#   3. markets-service /v1/health carries the matcher's heartbeat; the pager reads it quietly while
#      the matcher runs, pages matcher-dead once the matcher is killed, and resolves when it is back
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
RPC=http://127.0.0.1:8600
API_PORT=8090
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
step() { printf '\n== %s\n' "$*"; }
json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$@"; }
position_of() { $VENUE position "$1" | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["position"])'; }
index_now() { python3 -c "print(round(1e18 / $(cast call "$(json "$DIR/venue.json" indexFeed)" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))"; }
[ -f "$DIR/venue.json" ] || { echo "run up.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }

move_index() {
  local LEVEL=$1
  kill "$(cat "$DIR/pids/perp-feeds")" 2>/dev/null || true; rm -f "$DIR/pids/perp-feeds"
  python3 - "$DIR/perp-index-state.json" "$LEVEL" <<'PYSEED'
import json, sys, time
now = int(time.time() * 1000)
samples = [{"price": float(sys.argv[2]), "at": now - (12 - i) * 60_000 + 30_000} for i in range(12)]
json.dump({"samples": samples, "lastPublished": None}, open(sys.argv[1], "w"))
PYSEED
  (cd "$ROOT/services/perp-feeds" && set -a && . "$DIR/perp-feeds.env" && set +a && \
    node dist/main.js --local-sources="$LEVEL" --accept-index-step --level="$LEVEL" --approved-by=local-keeper-sliver --reason="keeper sliver scenario") 2>&1 | grep -E "index-step|refused" || true
  (cd "$ROOT/services/perp-feeds" && set -a && . "$DIR/perp-feeds.env" && set +a && \
    exec node dist/main.js --local-fixed-price="$LEVEL") >"$DIR/logs/perp-feeds.log" 2>&1 &
  echo $! >"$DIR/pids/perp-feeds"
  sleep 8
  # The venue's index-lag gate compares its spot sample with the on-chain index; the local reporter
  # posts a fixed level, so it must follow the move or the gate refuses every perp order (-2197 bps).
  kill "$(cat "$DIR/pids/index-status-reporter")" 2>/dev/null || true
  cat >"$DIR/bin/index-status-reporter.sh" <<REPORTER
#!/usr/bin/env bash
USDC_PER_CNGN=\$(python3 -c "print(f'{1 / $LEVEL:.18f}')")
while :; do
  curl -s -o /dev/null -X POST -H "X-Numo-Index-Token: local-venue-index-status-token" -H "content-type: application/json" \\
    -d "{\\"at_ms\\": \$(( \$(date +%s) * 1000 )), \\"usdc_per_cngn\\": \\"\$USDC_PER_CNGN\\", \\"sample_ok\\": true}" \\
    http://127.0.0.1:$API_PORT/v1/internal/index-status
  sleep 30
done
REPORTER
  chmod +x "$DIR/bin/index-status-reporter.sh"
  ("$DIR/bin/index-status-reporter.sh" >/dev/null 2>&1 &
   echo $! >"$DIR/pids/index-status-reporter")
  sleep 3
  echo "index now $(index_now) cNGN/USDC"
}

# The pager against a local capture server, as step-drill.sh runs it.
PAGES="$DIR/pages.jsonl"; rm -f "$PAGES" "$DIR/pager-state.json"
python3 - "$PAGES" <<'PY' >"$DIR/logs/page-capture.log" 2>&1 &
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out, "a").write(body.decode() + "\n")
        self.send_response(202); self.end_headers()
    def do_GET(self):
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 9778), H).serve_forever()
PY
CAPTURE=$!
trap 'kill $CAPTURE 2>/dev/null || true' EXIT
PAGER() { (cd "$ROOT/contracts/risk-core" && RPC_URL=$RPC KEEPER_HEALTH_URL=http://127.0.0.1:9464/health MATCHER_HEALTH_URL=http://127.0.0.1:$API_PORT/v1/health \
  PAGER_PROVIDER=pagerduty PAGERDUTY_URL=http://127.0.0.1:9778/ PAGERDUTY_ROUTING_KEY=local PAGE_PREFIX="[LOCAL] " \
  PAGER_STATE_FILE="$DIR/pager-state.json" PERP_INDEX_STATUS_FILE="$DIR/perp-index-status.json" PAGER_HEARTBEAT_URL=http://127.0.0.1:9778/hb \
  ALERT_WEBHOOK_URL= python3 scripts/ops/check_perp_pager.py --stack "$DIR/venue.json"); }
paged() { [ -f "$PAGES" ] && grep -c "\"event_action\": \"$1\".*$2" "$PAGES" || echo 0; }

step "1. the keeper finishes its own sliver, then the owner's stale Close ends flat"
$VENUE account maker 200000
$VENUE account liq 400
$VENUE quote
$VENUE take liq buy 1000
PRE=$(position_of liq)
echo "liq position before: $PRE"
INDEX0=$(index_now)
move_index $(python3 -c "print(round($INDEX0 * 0.78))")
$VENUE wait-auction-over liq 600
grep -h "finishing bid\|auction-open" "$DIR/logs/perp-keeper.log" | tail -3 | cut -c1-200
grep -q "finishing bid" "$DIR/logs/perp-keeper.log" || { echo "FAIL: the keeper did not place a finishing bid" >&2; exit 1; }
$VENUE quote
$VENUE close-from liq "$PRE"

step "2. the keeper's /health while idle"
curl -s http://127.0.0.1:9464/health | python3 -c 'import sys,json; h=json.load(sys.stdin); print("keeper health: lastPassOk", h["lastPassOk"], "openAuctions", h.get("openAuctions"))'

step "3. the matcher's heartbeat on /v1/health, and the pager on a dead matcher"
curl -s http://127.0.0.1:8082/healthz | cut -c1-200; echo
curl -s http://127.0.0.1:$API_PORT/v1/health | python3 -c 'import sys,json; h=json.load(sys.stdin); m=h["matcher"]; print("api /v1/health:", h["status"], "heartbeat age", round(m["age_seconds"],1), "s; indexer", m["details"].get("indexer"))'
PAGER | grep -E "^matcher:|^ok:"
[ "$(paged trigger matcher)" = 0 ] || { echo "FAIL: the pager paged a live matcher" >&2; exit 1; }
echo "stopping the matcher"
kill "$(cat "$DIR/pids/markets-matcher")"; rm -f "$DIR/pids/markets-matcher"
sleep 70
curl -s -o /dev/null -w "matcher /healthz after kill: %{http_code} (connection refused reads as 000)\n" http://127.0.0.1:8082/healthz || true
curl -s http://127.0.0.1:$API_PORT/v1/health | python3 -c 'import sys,json; h=json.load(sys.stdin); print("api /v1/health:", h["status"], "heartbeat age", round(h["matcher"]["age_seconds"]), "s")'
PAGER | grep -E "^matcher:|^ok:"
[ "$(paged trigger matcher-dead)" = 1 ] || { echo "FAIL: no matcher-dead page" >&2; cat "$PAGES" >&2; exit 1; }
echo "ok: paged matcher-dead"
echo "restarting the matcher"
(set -a; . "$DIR/markets.env"; set +a; exec "$DIR/bin/markets-matcher") >>"$DIR/logs/markets-matcher.log" 2>&1 &
echo $! >"$DIR/pids/markets-matcher"
sleep 12
PAGER | grep -E "^matcher:|^ok:"
[ "$(paged resolve matcher-dead)" = 1 ] || { echo "FAIL: matcher-dead did not resolve" >&2; exit 1; }
echo "ok: matcher-dead resolved once the heartbeat was fresh again"

echo
echo "ok: the keeper finishes its slivers, and a dead matcher pages"
