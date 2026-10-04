#!/usr/bin/env bash
# cNGN as margin on the local venue (after up.sh). The venue applies no direction rule and no 1:1
# bound to an account holding cNGN: cNGN and USDC both count as margin under the SRM's own check,
# cNGN at its factor, any direction, normal maximum leverage. What the venue still enforces:
#   1. long USD on cNGN margin is accepted past 1:1 with the cNGN posted (the SRM's margin is the limit)
#   2. long naira on cNGN margin is accepted (the app warns that it doubles the naira exposure)
#   3. long naira on USDC margin is accepted, as before
#   4. a USDC withdrawal that would take a perp account's cash below zero is refused
# Margin itself is the matcher's fill-time check against the SRM (an order past it rests and does
# not fill), the same on cNGN as on USDC; it is not a submit-time refusal and is not tested here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
RPC=http://127.0.0.1:8600
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
step() { printf '\n== %s\n' "$*"; }
[ -f "$DIR/venue.json" ] || { echo "run up.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }

INDEX=$(python3 -c "print(round(1e18 / $(cast call "$(python3 -c "import json;print(json.load(open('$DIR/venue.json'))['indexFeed'])")" 'getSpot()(uint256,uint256)' --rpc-url $RPC | head -1 | cut -d' ' -f1)))")
# 2M cNGN posted, worth VALUE at the index; the SRM credits half of it as margin, so at 3x the
# account carries up to 1.5x VALUE of notional in either direction, past 1:1 and nothing like a bound.
CNGN=2000000
VALUE=$((CNGN / INDEX))
echo "index $INDEX cNGN/USDC; treasury posts $CNGN cNGN = \$$VALUE at the index (\$$((VALUE / 2)) of margin)"

step "1. long USD on cNGN: accepted past 1:1 with the cNGN posted"
$VENUE account-cngn treasury $CNGN
$VENUE order treasury buy $((VALUE + VALUE / 4)) accepted
step "2. long naira on cNGN: accepted (doubles the naira exposure; the app warns, the venue allows)"
$VENUE account-cngn naira-doubler $CNGN
$VENUE order naira-doubler sell $((VALUE / 4)) accepted
step "3. long naira on USDC: accepted"
$VENUE account usdc-trader 2000
$VENUE order usdc-trader sell 100 accepted
step "4. a USDC withdrawal past the account's cash is refused; one within it pays"
# A fresh account with no orders: a fill's fee would move the cash the check reconciles.
$VENUE account usdc-holder 100
$VENUE withdraw-refused usdc-holder 101
$VENUE withdraw usdc-holder 1
echo
echo "ok: cNGN margins like USDC on the local venue; the venue refuses nothing but the cash floor"
