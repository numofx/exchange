#!/usr/bin/env bash
# The keeper's go-live rehearsal (runbook checklist, step 17): the PRODUCTION keeper build, with its
# PRODUCTION config and key, liquidates on a fork of Base taken after the stack is deployed and the
# keeper is funded -- the path a day of dry-run on a closed market never exercises.
#
#   KEEPER_KEY=<from SSM> BASE_RPC_URL=<archive RPC> ./scripts/local-venue/rehearse-mainnet.sh \
#     --keeper-env /etc/numo/perp-keeper.env
#
# Options: --fork-url <url> (default $BASE_RPC_URL), --stack <CNGN_PERP_STACK.json>,
#          --module <CNGN_PERP_TRADE_MODULE.json> (both default to the 8453 artifacts),
#          --keeper-dir <perp-keeper checkout with dist/> (default this repo's),
#          --cngn: the cNGN scenario against the REAL escrow (CNGN_PERP_COLLATERAL.json beside the
#          stack artifact; batch 5 applied on the fork as the vault): a treasury hedged 1:1 must ride
#          the fall out above margin, and a directly-created long-naira-on-cNGN account must be
#          liquidated by the production keeper, which then holds its cNGN. Needs CNGN_ESCROW in the
#          keeper env.
# Alerts are prefixed "[REHEARSAL] " and go ONLY to $REHEARSAL_ALERT_WEBHOOK_URL (a test channel);
# unset, they print here and reach no one.
#
# What keeps this off Base:
#  - anvil serves the fork as chain 31337, and the script refuses to go on unless the RPC says so;
#  - the keeper runs with CHAIN_ID=31337 and refuses to start if its RPC disagrees, so every
#    transaction it signs with the production key is EIP-155-bound to 31337 -- checked afterwards,
#    transaction by transaction;
#  - the keeper signs no typed data; the fork-only feed signer does, and the script first checks
#    the deployed feeds and Matching rebuild their EIP-712 domain for 31337 rather than keep Base's;
#  - the vault's actions are anvil impersonation: nothing is signed by the vault at all.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
FORK_URL="${BASE_RPC_URL:-}"
STACK="$ROOT/contracts/risk-core/deployments/8453/CNGN_PERP_STACK.json"
MODULE="$ROOT/contracts/execution/deployments/8453/CNGN_PERP_TRADE_MODULE.json"
KEEPER_DIR="$ROOT/services/perp-keeper"
KEEPER_ENV=""
UNIFIED=0
CNGN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cngn) CNGN=1; shift ;;
    --unified) UNIFIED=1; shift ;;
    --fork-url) FORK_URL=$2; shift 2 ;;
    --stack) STACK=$2; shift 2 ;;
    --module) MODULE=$2; shift 2 ;;
    --keeper-dir) KEEPER_DIR=$2; shift 2 ;;
    --keeper-env) KEEPER_ENV=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
: "${FORK_URL:?set BASE_RPC_URL or --fork-url}"
: "${KEEPER_KEY:?export KEEPER_KEY (the production keeper key, from SSM /numo/keeper/keeper_key)}"
[ -f "$KEEPER_ENV" ] || { echo "--keeper-env <the keeper's production env file> is required" >&2; exit 1; }
for f in "$STACK" "$MODULE" "$KEEPER_DIR/dist/main.js"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done

DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}/rehearsal"
mkdir -p "$DIR"
rm -f "$DIR/rehearsal-accounts.json" "$DIR/rehearsal-index" "$DIR/keeper.log"
PORT=8700
RPC="http://127.0.0.1:$PORT"
step() { printf '\n== %s\n' "$*"; }

step "fork of $FORK_URL as chain 31337 on :$PORT"
lsof -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1 && { echo "port $PORT is busy" >&2; exit 1; }
anvil --fork-url "$FORK_URL" --chain-id 31337 --port $PORT --silent >"$DIR/anvil.log" 2>&1 &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break; sleep 1; done
CHAIN=$(cast chain-id --rpc-url $RPC)
[ "$CHAIN" = 31337 ] || { echo "refusing: the rehearsal RPC reports chain $CHAIN, not 31337" >&2; exit 1; }
echo "ok: fork reports chain 31337"

T="pnpm --dir $HERE exec tsx $HERE/rehearse.ts $RPC $STACK $MODULE $DIR"
$T check-fork
START=$(cast block-number --rpc-url $RPC)

step "fork only: open the market, add a fork signer, positions, a 40% fall"
$T open-market
$T prices 0 2>/dev/null || $T prices 1374   # the live index if fresh, else a fixed level
$T positions
if [ $CNGN = 1 ]; then
  step "cNGN: batch 5 on the fork as the vault, then a hedged treasury and a long-naira-on-cNGN account"
  grep -q "^CNGN_ESCROW=" "$KEEPER_ENV" || { echo "--cngn needs CNGN_ESCROW in $KEEPER_ENV" >&2; exit 1; }
  $T cngn-open
  $T cngn-positions
fi
if [ $UNIFIED = 1 ]; then
  step "unified: an account holding cash AND cNGN with a long-naira perp, insolvent after the fall"
  grep -q "^CNGN_ESCROW=" "$KEEPER_ENV" || { echo "--unified needs CNGN_ESCROW in $KEEPER_ENV" >&2; exit 1; }
  $T cngn-open
  $T unified-positions
fi
$T crash 4000
if [ $UNIFIED = 1 ]; then
  AT_CRASH=$($T status)
  SM_BEFORE=$(echo "$AT_CRASH" | python3 -c 'import json,sys;print(json.load(sys.stdin)["securityModuleCash"])')
  MIXED_MM=$(echo "$AT_CRASH" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mixedMaintenanceMargin"])')
  ALICE_MM=$(echo "$AT_CRASH" | python3 -c 'import json,sys;print(json.load(sys.stdin)["aliceMaintenanceMargin"])')
  echo "unified at the crash: mixed maintenance margin $MIXED_MM (18dp, negative = insolvent), SecurityModule cash $SM_BEFORE"
  [ "${MIXED_MM#-}" != "$MIXED_MM" ] || { echo "REHEARSAL FAILED: the mixed account is not under maintenance margin after the fall" >&2; exit 1; }
fi

step "the production keeper, CHAIN_ID=31337, until both accounts are liquidated"
KEEPER_ADDR=$(cast wallet address --private-key "$KEEPER_KEY")
(set -a; . "$KEEPER_ENV"; set +a
 OWNER=$(cast call 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843 "ownerOf(uint256)(address)" "$KEEPER_ACCOUNT" --rpc-url $RPC)
 [ "$(echo "$OWNER" | tr A-F a-f)" = "$(echo "$KEEPER_ADDR" | tr A-F a-f)" ] ||
   { echo "KEEPER_ACCOUNT #$KEEPER_ACCOUNT is owned by $OWNER, not the keeper $KEEPER_ADDR: fund it first (checklist step 15)" >&2; exit 1; })
# Done when alice (insolvent) is closed and carol (solvent) was cut back above maintenance margin with
# her auction ended. A solvent liquidation is partial by design: it sells only enough to restore
# margin, and an auction that has sold what it can only ends when its solvent phase does (15 min
# fast + 12 h slow), so once carol is back above margin the fork jumps past that phase.
DONE='"alice":"0","carol":"[1-9][0-9]*","carolInAuction":false,"carolAboveMaintenance":true'
# dave ends in a SOLVENT auction (equity just above zero after the fall), which sells what restores
# margin and leaves a rounding sliver, so "liquidated" is under 100k cNGN left and the auction over.
[ $CNGN = 1 ] && DONE="$DONE"',.*"treasuryAboveMaintenance":true,"dave":"[0-9]{1,23}","daveInAuction":false'
# The mixed account is insolvent: the whole position goes in one bid and its auction ends.
[ $UNIFIED = 1 ] && DONE="$DONE"',.*"mixed":"0",.*"mixedInAuction":false'
LONG_WARP=0
for pass in $(seq 1 30); do
  (cd "$KEEPER_DIR" && set -a && . "$KEEPER_ENV" && set +a && unset HEALTH_PORT &&
   RPC_URL=$RPC CHAIN_ID=31337 DRY_RUN=false ALERT_PREFIX="[REHEARSAL] " \
   ALERT_WEBHOOK_URL="${REHEARSAL_ALERT_WEBHOOK_URL:-}" KEEPER_KEY="$KEEPER_KEY" \
   node dist/main.js --once) >>"$DIR/keeper.log" 2>&1 || { echo "keeper pass $pass failed:" >&2; tail -5 "$DIR/keeper.log" >&2; exit 1; }
  STATUS=$($T status)
  echo "pass $pass: $STATUS"
  echo "$STATUS" | grep -qE "$DONE" && break
  if [ $LONG_WARP = 0 ] && echo "$STATUS" | grep -q '"alice":"0".*"carolInAuction":true,"carolAboveMaintenance":true'; then
    $T warp $((12 * 3600 + 15 * 60 + 120)) >/dev/null; LONG_WARP=1
  else
    $T warp 300 >/dev/null
  fi
  $T prices 0 >/dev/null   # re-sign the crashed level with a fresh timestamp
done
echo "$STATUS" | grep -qE "$DONE" || { echo "REHEARSAL FAILED: not liquidated as expected after 30 passes (keeper log: $DIR/keeper.log)" >&2; exit 1; }
echo "$STATUS" | grep -q '"carol":"10000000000000000000000000"' && { echo "REHEARSAL FAILED: carol was never liquidated" >&2; exit 1; }

step "checks"
echo "ok: the production keeper closed the insolvent account, cut the solvent one back above margin, and ended its auction"
if [ $CNGN = 1 ]; then
  echo "$STATUS" | grep -q '"treasuryCngn":"2000000000000000000000000"' || { echo "REHEARSAL FAILED: the hedged treasury lost cNGN" >&2; exit 1; }
  grep -q "keeper-cngn-inventory" "$DIR/keeper.log" || { echo "REHEARSAL FAILED: the keeper did not report the cNGN it was paid in" >&2; exit 1; }
  echo "ok: cNGN: the hedged treasury rode the fall out above margin with its 2M cNGN; the keeper liquidated the long-naira-on-cNGN account and reports holding its cNGN"
fi
if [ $UNIFIED = 1 ]; then
  SM_AFTER=$(echo "$STATUS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["securityModuleCash"])')
  MIXED_CNGN=$(echo "$STATUS" | python3 -c 'import json,sys;print(json.load(sys.stdin)["mixedCngn"])')
  python3 - "$SM_BEFORE" "$SM_AFTER" "$MIXED_MM" "$ALICE_MM" "$MIXED_CNGN" <<'PY2'
import sys
before, after, mixed_mm, alice_mm, cngn = (int(x) for x in sys.argv[1:])
paid = before - after
# The SecurityModule pays every insolvent auction here: alice's from the base scenario and the
# mixed account's. Each auction's price walks to the maintenance-margin deficit by its end, so the
# total is at most the two deficits (the keeper bids earlier, so usually less), and above zero.
bound = max(0, -mixed_mm) + max(0, -alice_mm)
assert paid > 0, f"the SecurityModule paid nothing ({paid}) for two insolvent accounts"
assert paid <= bound * 105 // 100, f"the SecurityModule paid {paid/1e18:,.2f}, over the terminal bound {bound/1e18:,.2f} (mixed {-mixed_mm/1e18:,.2f} + alice {-alice_mm/1e18:,.2f})"
assert cngn == 0, f"the mixed account still holds {cngn/1e18:,.0f} cNGN: the bid did not take its spot holding"
print(f"ok: unified: the SecurityModule paid ${paid/1e18:,.2f} for alice and the mixed account against a terminal bound of ${bound/1e18:,.2f} (mixed {-mixed_mm/1e18:,.2f}, alice {-alice_mm/1e18:,.2f}); the keeper took the mixed portfolio whole, its 500k cNGN included")
PY2
  grep -q "keeper-cngn-inventory" "$DIR/keeper.log" || { echo "REHEARSAL FAILED: the keeper did not report the cNGN it inherited" >&2; exit 1; }
fi
$T verify-keeper-txs "$KEEPER_ADDR" "$START"
grep -E "^\[keeper\] #|\[alert\]" "$DIR/keeper.log" | tail -12
printf '\nREHEARSAL PASSED. Keeper log: %s/keeper.log\n' "$DIR"
