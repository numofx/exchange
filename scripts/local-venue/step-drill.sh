#!/usr/bin/env bash
# The index-step reopening procedure, drilled on the local venue with the full OI cap open:
#
#   ./scripts/local-venue/up.sh && ./scripts/local-venue/step-drill.sh [step-bps] [usdc|cngn]
#   (default 4000 = 40%. `cngn` adds the cNGN scenario the venue allows: a treasury posting cNGN
#   and long USD 1:1 against it, which must ride the step out above margin with its cNGN intact
#   while the USDC-margined NGN long is liquidated as usual)
#
#  1. fill the rest of the cap: one NGN long at ~3x against a well-funded NGN short
#  2. stop the publisher; 12 minutes of source samples at the new level go in its state file (what
#     the sources would have reported after a real devaluation)
#  3. the step with the keeper DOWN is refused, and nothing is published
#  4. the step with the keeper live is published once, and the audit log names who approved it
#  5. restart the publisher at the new level; the keeper must liquidate the NGN long
#  6. report what the SecurityModule paid, and whether any loss socialized
#  7. the pager (check_perp_pager.py) against a local capture server: quiet at the start, pages an
#     unreachable keeper, the insolvent account and the SecurityModule payout, and resolves
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
STEP_BPS="${1:-4000}"
COLLATERAL="${2:-usdc}"
RPC=http://127.0.0.1:8600
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$@"; }
step() { printf '\n== %s\n' "$*"; }

[ -f "$DIR/venue.json" ] || { echo "run up.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }

INDEX_NOW=$(python3 -c "print(round(1e18 / $(cast call "$(json "$DIR/venue.json" indexFeed)" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))")
# A step of STEP_BPS in USDC per cNGN: NGN devalues, so cNGN per USDC rises by 1 / (1 - step).
NEW_LEVEL=$(python3 -c "print(round($INDEX_NOW / (1 - $STEP_BPS / 10000)))")
echo "index $INDEX_NOW -> $NEW_LEVEL cNGN/USDC (a ${STEP_BPS}bps fall in USDC per cNGN)"

# The pager, pointed at a local capture server in PagerDuty's shape: nothing leaves the machine.
PAGES="$DIR/pages.jsonl"; rm -f "$PAGES" "$DIR/pager-state.json"
python3 - "$PAGES" <<'PY' >"$DIR/logs/page-capture.log" 2>&1 &
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        open(out, "a").write(body.decode() + "\n")
        self.send_response(202); self.end_headers()
    def do_GET(self):  # the pager's dead-man's switch pings
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 9778), H).serve_forever()
PY
CAPTURE=$!
trap 'kill $CAPTURE 2>/dev/null || true' EXIT
PAGER() { (cd "$ROOT/contracts/risk-core" && RPC_URL=$RPC KEEPER_HEALTH_URL="${1:-http://127.0.0.1:9464/health}" MATCHER_HEALTH_URL=http://127.0.0.1:8090/v1/health \
  PAGER_PROVIDER=pagerduty PAGERDUTY_URL=http://127.0.0.1:9778/ PAGERDUTY_ROUTING_KEY=local PAGE_PREFIX="[REHEARSAL] " \
  PAGER_STATE_FILE="$DIR/pager-state.json" PERP_INDEX_STATUS_FILE="$DIR/perp-index-status.json" PAGER_HEARTBEAT_URL=http://127.0.0.1:9778/hb \
  ALERT_WEBHOOK_URL= python3 scripts/ops/check_perp_pager.py --stack "$DIR/venue.json"); }
paged() { [ -f "$PAGES" ] && grep -c "\"event_action\": \"$1\".*$2" "$PAGES" || echo 0; }

step "pager: quiet on a healthy market"
PAGER >/dev/null
[ "$(paged trigger .)" = 0 ] || { echo "FAIL: the pager paged on a healthy market" >&2; cat "$PAGES" >&2; exit 1; }
echo "ok: no pages"
step "pager: keeper unreachable pages"
PAGER http://127.0.0.1:9/health >/dev/null
[ "$(paged trigger keeper-unhealthy)" = 1 ] || { echo "FAIL: no keeper-unhealthy page" >&2; exit 1; }
PAGER >/dev/null
[ "$(paged resolve keeper-unhealthy)" = 1 ] || { echo "FAIL: keeper-unhealthy did not resolve" >&2; exit 1; }
echo "ok: paged, then resolved when the keeper answered again"

if [ "$COLLATERAL" = cngn ]; then
  # Before the cap is filled: the treasury's long USD takes 2M cNGN of the OI cap, the NGN long the rest.
  step "cNGN: a treasury posts 2M cNGN and hedges 1:1 (long USD)"
  $VENUE hedge treasury 2000000
fi
step "fill the cap"
$VENUE fill-cap
$VENUE report

step "stop the publisher; seed the sources' window at $NEW_LEVEL"
kill "$(cat "$DIR/pids/perp-feeds")" && rm -f "$DIR/pids/perp-feeds"
python3 - "$DIR/perp-index-state.json" "$NEW_LEVEL" <<'PY'
import json, sys, time
now = int(time.time() * 1000)
samples = [{"price": float(sys.argv[2]), "at": now - (12 - i) * 60_000 + 30_000} for i in range(12)]
json.dump({"samples": samples, "lastPublished": None}, open(sys.argv[1], "w"))
PY

FEEDS() { (cd "$ROOT/services/perp-feeds" && set -a && . "$DIR/perp-feeds.env" && set +a && "$@"); }
STEP_ARGS=(--local-sources="$NEW_LEVEL" --accept-index-step --level="$NEW_LEVEL" --approved-by=local-step-drill --reason="${STEP_BPS}bps devaluation drill")

step "step with the keeper unreachable: must be refused"
if FEEDS env KEEPER_HEALTH_URL=http://127.0.0.1:9 node dist/main.js "${STEP_ARGS[@]}" >"$DIR/logs/step-refused.log" 2>&1; then
  echo "FAIL: the step went through without a live keeper" >&2; exit 1
fi
grep -o "index step refused: [^\"]*" "$DIR/logs/step-refused.log" | head -1
[ "$(python3 -c "print(round(1e18 / $(cast call "$(json "$DIR/venue.json" indexFeed)" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))")" = "$INDEX_NOW" ] \
  && echo "index unchanged at $INDEX_NOW"

step "step with the keeper live"
FEEDS node dist/main.js "${STEP_ARGS[@]}" 2>&1 | grep -E "index-step|refused"
tail -2 "$DIR/perp-index-steps.jsonl" | python3 -c "import json,sys;[print(r['status'], 'by', r['approvedBy'], r['stepBps'], 'bps', r.get('tx','')) for r in map(json.loads, sys.stdin)]"

step "publisher back on at $NEW_LEVEL; keeper liquidates"
# exec, so the recorded pid is node's own and down.sh can stop it (not a subshell that outlives it).
(cd "$ROOT/services/perp-feeds" && set -a && . "$DIR/perp-feeds.env" && set +a && \
  exec node dist/main.js --local-fixed-price="$NEW_LEVEL") >"$DIR/logs/perp-feeds.log" 2>&1 &
echo $! >"$DIR/pids/perp-feeds"
# The pager runs alongside: it must page the insolvent account while it is open.
for _ in $(seq 1 60); do
  PAGER >/dev/null
  [ "$(paged trigger insolvent-account)" -ge 1 ] && break
  [ "$(pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR report 2>/dev/null | grep -c "'ngn-long' .* 0 " | tail -1)" -ge 1 ] && break
  sleep 3
done
$VENUE wait-liquidated ngn-long 600
# The keeper's next pass (every 5s here) is what clears the account from /health; give it a minute.
for _ in $(seq 1 20); do
  PAGER >/dev/null
  [ "$(paged resolve insolvent-account)" -ge 1 ] && break
  sleep 3
done
step "pager: what reached the capture server"
python3 -c "
import json, sys
for line in open(sys.argv[1]):
    e = json.loads(line)
    print(e['event_action'], e['dedup_key'], (e.get('payload') or {}).get('summary', ''))" "$PAGES"
[ "$(paged trigger insolvent-account)" -ge 1 ] || { echo "FAIL: the insolvent account was not paged" >&2; exit 1; }
[ "$(paged trigger sm-payout)" -ge 1 ] || { echo "FAIL: the SecurityModule payout was not paged" >&2; exit 1; }
[ "$(paged resolve insolvent-account)" -ge 1 ] || { echo "FAIL: the insolvent account did not resolve" >&2; exit 1; }
echo "ok: insolvent account and SecurityModule payout paged, insolvency resolved"
grep -q '\[REHEARSAL\]' "$PAGES" || { echo "FAIL: pages were not prefixed" >&2; exit 1; }
echo "ok: every page prefixed"
$VENUE report
grep -E "bid|auction" "$DIR/logs/perp-keeper.log" | tail -12
if [ "$COLLATERAL" = cngn ]; then
  step "cNGN: the hedged treasury rode the ${STEP_BPS}bps step out, above margin, cNGN intact, never liquidated"
  $VENUE hedge-check treasury
  grep -q "#$(json "$DIR/accounts.json" treasury): \(start\|bid\)" "$DIR/logs/perp-keeper.log" && { echo "FAIL: the keeper touched the hedged treasury" >&2; exit 1; }
  echo "ok: the keeper never started an auction on the treasury"
fi
