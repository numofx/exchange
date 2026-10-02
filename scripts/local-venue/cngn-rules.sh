#!/usr/bin/env bash
# The venue's rules for cNGN-margined accounts, on the local venue (after up.sh):
#   1. long USD on cNGN margin is accepted up to 1:1 with the cNGN posted, and refused above it
#   2. long naira on cNGN margin is refused
#   3. long naira on USDC margin is accepted, as before
#   4. a USDC withdrawal that would take a perp account's cash below zero is refused
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
# 2M cNGN posted: at the index that is the most long USD the account may hold.
CNGN=2000000
LOCKED=$((CNGN / INDEX))
echo "index $INDEX cNGN/USDC; treasury posts $CNGN cNGN = \$$LOCKED of hedge"

step "1. long USD on cNGN: accepted at 1:1, refused one dollar over"
$VENUE account-cngn treasury $CNGN
$VENUE order treasury buy $((LOCKED - 1)) accepted
$VENUE order treasury buy 2 refused          # the resting order plus this one would exceed the cNGN
step "2. long naira on cNGN: refused"
$VENUE order treasury sell 10 refused
step "3. long naira on USDC: accepted"
$VENUE account usdc-trader 2000
$VENUE order usdc-trader sell 100 accepted
step "4. a USDC withdrawal past the account's cash is refused; one within it pays"
# A fresh account with no orders: a fill's fee would move the cash the check reconciles.
$VENUE account usdc-holder 100
$VENUE withdraw-refused usdc-holder 101
$VENUE withdraw usdc-holder 1
echo
echo "ok: all four cNGN rules hold on the local venue"
