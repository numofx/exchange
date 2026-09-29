#!/usr/bin/env bash
# The index-step reopening procedure, drilled on the local venue with the full OI cap open:
#
#   ./scripts/local-venue/up.sh && ./scripts/local-venue/step-drill.sh [step-bps]   (default 4000 = 40%)
#
#  1. fill the rest of the cap: one NGN long at ~3x against a well-funded NGN short
#  2. stop the publisher; 12 minutes of source samples at the new level go in its state file (what
#     the sources would have reported after a real devaluation)
#  3. the step with the keeper DOWN is refused, and nothing is published
#  4. the step with the keeper live is published once, and the audit log names who approved it
#  5. restart the publisher at the new level; the keeper must liquidate the NGN long
#  6. report what the SecurityModule paid, and whether any loss socialized
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
STEP_BPS="${1:-4000}"
RPC=http://127.0.0.1:8600
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$@"; }
step() { printf '\n== %s\n' "$*"; }

[ -f "$DIR/venue.json" ] || { echo "run up.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }

INDEX_NOW=$(python3 -c "print(round(1e18 / $(cast call "$(json "$DIR/venue.json" indexFeed)" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))")
# A step of STEP_BPS in USD per NGN: NGN devalues, so NGN per USD rises by 1 / (1 - step).
NEW_LEVEL=$(python3 -c "print(round($INDEX_NOW / (1 - $STEP_BPS / 10000)))")
echo "index $INDEX_NOW -> $NEW_LEVEL NGN/USD (a ${STEP_BPS}bps fall in USD per NGN)"

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
$VENUE wait-closed ngn-long 600
$VENUE report
grep -E "bid|auction" "$DIR/logs/perp-keeper.log" | tail -12
