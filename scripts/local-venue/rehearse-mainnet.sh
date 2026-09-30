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
#          --keeper-dir <perp-keeper checkout with dist/> (default this repo's).
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
while [ $# -gt 0 ]; do
  case "$1" in
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
$T crash 4000

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
$T verify-keeper-txs "$KEEPER_ADDR" "$START"
grep -E "^\[keeper\] #|\[alert\]" "$DIR/keeper.log" | tail -12
printf '\nREHEARSAL PASSED. Keeper log: %s/keeper.log\n' "$DIR"
