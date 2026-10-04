#!/usr/bin/env bash
# The unified account on the local venue (after up.sh --unified): spot runs on the perp stack, so one
# account under the perp SRM holds USDC cash and cNGN, trades spot and perp, and all of it is margin.
#   1. /v1/markets binds spot to the perp's cNGN escrow, the perp TradeModule, the perp cash and the perp SRM
#   2. a spot trade settles through the perp module: both legs move on the perp cash and escrow,
#      checked against the spot fill contract, with the executor's gas headroom
#   3. a spot sell that would overdraw cash (the engine's buyer underfunded) never fills: the venue
#      accepts the order, the matcher refuses the fill, cash stays where it was
#   4. cross-margin: an account's cNGN (its spot holding) is credited at the haircut in the SRM's own
#      headroom, and a perp order from it is accepted
#   5. the guardian's pause stops spot as well as perp (trading_paused), and lifts
#   6. a withdrawal of the perp cash from a spot account pays USDC
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
RPC=http://127.0.0.1:8600
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
step() { printf '\n== %s\n' "$*"; }
[ -f "$DIR/venue.json" ] || { echo "run up.sh --unified first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }
python3 -c "import json,sys; sys.exit(0 if json.load(open('$DIR/venue.json')).get('unified') else 1)" || { echo "the venue is not unified: run up.sh --unified" >&2; exit 1; }

INDEX=$(python3 -c "print(round(1e18 / $(cast call "$(python3 -c "import json;print(json.load(open('$DIR/venue.json'))['indexFeed'])")" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))")
echo "index $INDEX cNGN/USDC"

step "1. spot is bound to the perp stack, and the index-lag gate is enforced as on Base"
$VENUE spot-market-check
curl -sf http://127.0.0.1:8090/v1/markets | python3 -c "
import json, sys
perp = next(m for m in json.load(sys.stdin) if m['contract_type'] == 'perpetual')
lag = (perp.get('perp') or {}).get('index_lag') or {}
assert lag.get('enforced') is True, f'the index-lag gate is not enforced on the local venue: {lag}'
assert lag.get('lag_bps') is not None, f'the venue has no spot sample yet: {lag}'
print('ok: index-lag gate enforced, lag', lag['lag_bps'], 'bps, sample age', lag.get('sample_age_sec'), 's')"

step "2. a spot trade settles through the perp module"
$VENUE spot-account usdc-maker usdc 1000
$VENUE spot-account cngn-taker cngn 400000
$VENUE spot-cross $INDEX 100

step "3. an overdrawn spot sell never fills (the matcher refuses it as buyer_underfunded)"
$VENUE spot-account poor usdc 100
$VENUE spot-overdrawn poor cngn-taker $INDEX 500

step "4. cross-margin: the maker's cNGN is credited at the haircut, and it can trade the perp"
$VENUE spot-deposit usdc-maker cngn 100000
$VENUE margin-of usdc-maker
$VENUE order usdc-maker buy 500 accepted

step "5. the guardian's pause stops spot too, and lifts"
$VENUE pause
sleep 6   # the api polls the pause
$VENUE spot-order usdc-maker sell $INDEX 10 refused
$VENUE unpause
sleep 6
$VENUE spot-order usdc-maker sell $INDEX 10 accepted

step "6. a withdrawal of the perp cash from a spot account pays USDC"
$VENUE spot-withdraw usdc-maker 10

echo
echo "ok: the unified account holds on the local venue: spot through the perp module, one margin for both, the cash floor, the pause"
