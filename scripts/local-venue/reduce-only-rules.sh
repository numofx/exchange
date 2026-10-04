#!/usr/bin/env bash
# Reduce-only on the local venue (after up.sh, any mode): the venue clamps a reduce-only order to the
# account's position as its own ledger has it after every fill, and cancels what cannot reduce.
#   1. a reduce-only order from a flat account is refused at submission (422)
#   2. a reduce-only order on the position's own side is refused at submission (422)
#   3. one Close sized from a fresh read ends flat
#   4. two rapid Closes from one stale read end flat: the second is cancelled, never fills
#   5. Close from two tabs (two concurrent submissions) ends flat
#   6. Close after a fill the UI has not shown: clamped to what is left, remainder cancelled, flat
# Every scenario asserts the chain position is exactly zero -- never flipped.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
RPC=http://127.0.0.1:8600
VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
step() { printf '\n== %s\n' "$*"; }
[ -f "$DIR/venue.json" ] || { echo "run up.sh first" >&2; exit 1; }
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not the local fork" >&2; exit 1; }

open() { # open <label> <usd>: a long USD position of <usd> taken from the maker's offer, confirmed on chain
  $VENUE take "$1" buy "$2"
}

step "0. accounts and the maker's resting quote"
$VENUE account maker 200000
$VENUE account closer 20000
$VENUE quote
$VENUE quote

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
$VENUE close-after-unseen-fill closer 300

echo
echo "ok: reduce-only holds on the local venue: refused when flat or on the wrong side, clamped to the ledger, never a flip"
