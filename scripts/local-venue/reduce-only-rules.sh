#!/usr/bin/env bash
# Reduce-only on the local venue (after up.sh, any mode): the venue clamps a reduce-only order to the
# account's position as its own ledger has it after every fill, and cancels what cannot reduce.
#   1. a reduce-only order from a flat account is refused at submission (422)
#   2. a reduce-only order on the position's own side is refused at submission (422)
#   3. one Close sized from a fresh read ends flat
#   4. two rapid Closes from one stale read end flat: the second is cancelled, never fills
#   5. Close from two tabs (two concurrent submissions) ends flat
#   6. Close after a fill the UI has not shown: clamped to what is left, remainder cancelled, flat
#   7. the keeper partially liquidates a position (a solvent auction), then a Close sized from the
#      pre-liquidation position must end flat: the clamp reads the chain, and the indexer has
#      already followed the liquidation into the ledger
#   8. the keeper liquidates a position in full, then a Close sized from the old position is refused
# Every scenario asserts the chain position is exactly zero -- never flipped. 7 and 8 move the index
# with the perp-feeds index-step procedure, as step-drill.sh does, so they need the plain venue
# (up.sh without --unified: the unified venue's index-lag gate would hold the perp orders).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
RPC=http://127.0.0.1:8600
API_PORT=8090
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
step() { printf '\n== %s\n' "$*"; }
[ -f "$DIR/venue.json" ] || { echo "run up.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }

# Orders are sized in cNGN; a long USD position is a short of the perp. INDEX converts the dollar
# sizes below at the index as it stands now (7 and 8 move it, and re-read it).
INDEX=$(python3 -c "print(round(1e18 / $(cast call "$(python3 -c "import json;print(json.load(open('$DIR/venue.json'))['indexFeed'])")" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))")
open() { # open <label> <usd>: a long USD position of <usd> (a sell of the perp) taken from the maker's bid, confirmed on chain
  $VENUE take "$1" sell $(($2 * INDEX))
}

step "0. accounts and the maker's resting quote"
$VENUE account maker 200000
$VENUE account closer 20000
$VENUE quote
$VENUE quote

if [ "${SKIP_BASIC:-0}" != 1 ]; then
step "1. reduce-only from a flat account is refused at submission"
$VENUE close-refused-flat closer

step "2. reduce-only on the position's own side is refused"
open closer 1000
$VENUE close-wrong-side closer

step "3. one Close from a fresh read ends flat"
$VENUE close closer

step "4. two rapid Closes from one stale read end flat"
$VENUE quote
open closer 1000
$VENUE close-twice closer

step "5. Close from two tabs ends flat"
$VENUE quote
open closer 1000
$VENUE close-concurrent closer

step "6. Close after a fill the UI has not shown ends flat"
$VENUE quote
open closer 1000
$VENUE close-after-unseen-fill closer $((300 * INDEX))

fi

json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$@"; }
position_of() { $VENUE position "$1" | tail -1 | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["position"])'; }
index_now() { python3 -c "print(round(1e18 / $(cast call "$(json "$DIR/venue.json" indexFeed)" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))"; }
# move_index <cNGN per USDC>: the publisher stops, the sources' window is seeded at the level, the
# one-shot index step is accepted (the keeper is live), and the publisher comes back at the level.
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
    node dist/main.js --local-sources="$LEVEL" --accept-index-step --level="$LEVEL" --approved-by=local-reduce-only --reason="reduce-only liquidation scenario") 2>&1 | grep -E "index-step|refused" || true
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

if [ "${SKIP_LIQUIDATION:-0}" != 1 ]; then
INDEX0=$(index_now)
step "7. a partial liquidation, then a Close sized from the pre-liquidation position ends flat"
# $400 of cash behind a $1,000 long USD (2.5x): a 22% stronger naira puts it under the 20%
# maintenance margin while still solvent, so the auction sells only what restores margin.
$VENUE account liq 400
$VENUE quote
$VENUE take liq sell $((1000 * INDEX0))
PRE=$(position_of liq)
echo "liq position before: $PRE"
move_index $(python3 -c "print(round($INDEX0 * 0.78))")
$VENUE wait-reduced liq "$PRE" 900
# The chain refuses every trade for an account whose auction is still open (BM_AccountUnderLiquidation);
# a solvent auction bid down to a sliver stays open for its 12h15m window, so a competing liquidator
# takes the sliver and the auction terminates, as it would on Base.
$VENUE mop-auction liq
$VENUE quote
$VENUE close-from liq "$PRE"
grep -h "perp_position_adjusted_on_chain\|reduce_only_ledger_resynced\|reduce_only_clamped" "$DIR/logs/markets-matcher.log" | tail -4 | cut -c1-220

step "8. a full liquidation, then a Close sized from the old position is refused"
INDEX1=$(index_now)
$VENUE account liq2 400
$VENUE quote
$VENUE take liq2 sell $((1000 * INDEX1))
PRE2=$(position_of liq2)
echo "liq2 position before: $PRE2"
# Insolvent past a 40% loss on $400 of cash; the index-step procedure caps one step at 5000bps of
# USDC per cNGN, so the naira strengthens in two accepted steps (30% then 25%, 47.5% in all).
move_index $(python3 -c "print(round($INDEX1 * 0.70))")
move_index $(python3 -c "print(round($INDEX1 * 0.70 * 0.75))")
$VENUE wait-liquidated liq2 900
$VENUE close-from liq2 "$PRE2" refused
grep -h "perp_position_adjusted_on_chain" "$DIR/logs/markets-matcher.log" | tail -2 | cut -c1-220
fi

echo
echo "ok: reduce-only holds on the local venue: refused when flat or on the wrong side, clamped to the ledger and the chain, never a flip"
