#!/usr/bin/env bash
# The cNGN options maker against the venue as deployed, on a Base fork:
#
#   BASE_RPC_URL=<Base RPC> ./scripts/local-venue/options-fork.sh
#
#  1. anvil forks Base at head as chain 31337: MarginEngine v2, the OptionAsset, the vol and forward feeds and the
#     options' cap are mainnet's, already open. The vault (impersonated) adds a local executor to Matching.
#  2. markets api + matcher and execution-service run with PRODUCTION's environment, read from the live ECS task
#     definitions (AWS profile numo); only the chain id, RPC, database, ports and the executor's key are local.
#  3. a maker account (2,000 USDC) and a taker account (500 USDC) are opened under MarginEngine v2.
#  4. mm-bot runs in options mode (MM_OPTION_SERIES) from the market-maker checkout, and must quote both sides of
#     every listed strike within 90s.
#  5. the taker buys 10 units (10,000 cNGN) of the ATM put at the maker's ask: positions, premium, the 15 bps fee
#     and the writer's IM surplus are checked against the engine (options-fork.ts take).
#  6. the fork is moved past the feeds' heartbeats: the vol, spot and forward reads revert, and the maker must take
#     every quote on every strike down.
#
# Run it within ~15 minutes of the feeds' last publish (spot heartbeat 1200s, vol 1800s): the fork has no publisher.
# Logs and pids go to .options-fork/ (OPTIONS_FORK_DIR); ./scripts/local-venue/options-fork.sh --down stops it.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${OPTIONS_FORK_DIR:-$ROOT/.options-fork}"
MM_REPO="${MARKET_MAKER_DIR:-$ROOT/../market-maker}"
PROFILE="${AWS_PROFILE:-numo}"
SERIES="${OPTIONS_FORK_SERIES:-cNGN-30NOV26}"
STRIKE="${OPTIONS_FORK_TAKE:-cNGN-30NOV26-0.00072-P}"
ANVIL_PORT=8610 PG_PORT=5545 API_PORT=8095 EXEC_PORT=8096 MM_METRICS_PORT=8097 MATCHER_HEALTH_PORT=8099
RPC="http://127.0.0.1:$ANVIL_PORT"
DB="postgres://postgres@127.0.0.1:$PG_PORT/matching_backend?sslmode=disable"
VAULT=0x1dcA42ab54Bd3862853A821F84B29BF65245F435
MATCHING=0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191
key() { cast keccak "numo.local-venue.$1"; }
EXECUTOR_KEY=$(key executor)

down() {
  for f in "$DIR"/pids/*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; done
  [ -d "$DIR/pgdata" ] && pg_ctl -D "$DIR/pgdata" stop -m fast >/dev/null 2>&1 || true
}
if [ "${1:-}" = "--down" ]; then down; exit 0; fi
: "${BASE_RPC_URL:?set BASE_RPC_URL (a Base RPC to fork)}"
[ -d "$MM_REPO/cmd/mm-bot" ] || { echo "no market-maker checkout at $MM_REPO (MARKET_MAKER_DIR)" >&2; exit 1; }
mkdir -p "$DIR/logs" "$DIR/pids" "$DIR/bin"
down
rm -f "$DIR/accounts.json" "$DIR"/mm-state.json*

step() { printf '\n== %s\n' "$*"; }
start() { local name=$1; shift; nohup "$@" >"$DIR/logs/$name.log" 2>&1 & echo $! >"$DIR/pids/$name"; }
wait_for() {
  local what=$1; shift
  for _ in $(seq 1 90); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "timed out waiting for $what (logs in $DIR/logs)" >&2; exit 1
}
OPT="pnpm --dir $HERE exec tsx $HERE/options-fork.ts $DIR"
export LOCAL_VENUE_RPC=$RPC LOCAL_VENUE_MARKETS="http://127.0.0.1:$API_PORT"

# A service's production environment from its live task definition, as KEY='value' lines a shell can source. Secrets
# are not in `environment` (they are `secrets`), so nothing sensitive is read; `drop` removes names that must be local.
prod_env() { # prod_env <ecs service> <drop regex>
  local td
  td=$(aws ecs describe-services --profile "$PROFILE" --region us-east-1 --cluster numo-exchange --services "$1" \
    --query 'services[0].taskDefinition' --output text)
  aws ecs describe-task-definition --profile "$PROFILE" --region us-east-1 --task-definition "$td" \
    --query 'taskDefinition.containerDefinitions[0].environment' --output json |
    python3 -c '
import json, re, sys
drop = re.compile(sys.argv[1])
for e in sorted(json.load(sys.stdin), key=lambda e: e["name"]):
    if not drop.search(e["name"]):
        print("%s=%s" % (e["name"], "'"'"'" + e["value"].replace("'"'"'", "'"'"'\\'"'"''"'"'") + "'"'"'"))
' "$2"
  echo "# from $td"
}

step "anvil: Base fork at head as chain 31337 on :$ANVIL_PORT"
start anvil anvil --fork-url "$BASE_RPC_URL" --chain-id 31337 --port $ANVIL_PORT --silent
wait_for anvil cast chain-id --rpc-url $RPC
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not a local fork" >&2; exit 1; }
EXECUTOR=$(cast wallet address --private-key "$EXECUTOR_KEY")
cast rpc anvil_impersonateAccount $VAULT --rpc-url $RPC >/dev/null
cast rpc anvil_setBalance $VAULT 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null
cast send $MATCHING "setTradeExecutor(address,bool)" "$EXECUTOR" true --from $VAULT --unlocked --rpc-url $RPC >/dev/null
cast rpc anvil_setBalance "$EXECUTOR" 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null

step "production environment (ECS task definitions, profile $PROFILE)"
LOCAL_ONLY='^(CHAIN_ID|CHAIN_RPC_URL|RPC_URL|DATABASE_URL|API_ADDR|PORT|HOST|SERVICE_MODE|EXECUTOR_.*URL|.*KMS.*|.*CANARY.*|DEPOSITS_ENABLED|WAIT_FOR_RECEIPT|MATCHER_HEALTH_ADDR|WS_ALLOWED_ORIGINS)$'
{ prod_env markets-service "$LOCAL_ONLY"; prod_env matcher "$LOCAL_ONLY|^(MATCHING_ADDRESS|OPTION_SERIES|FUTURE_SERIES)$"; cat <<ENV
CHAIN_ID=31337
CHAIN_RPC_URL=$RPC
DATABASE_URL=$DB
API_ADDR=:$API_PORT
APP_ENV=dev
DEPOSITS_ENABLED=false
EXECUTOR_URL=http://127.0.0.1:$EXEC_PORT/execute
EXECUTOR_WITHDRAW_URL=http://127.0.0.1:$EXEC_PORT/withdraw
EXECUTOR_DEPOSIT_URL=http://127.0.0.1:$EXEC_PORT/deposit
MATCHER_POLL_INTERVAL=500ms
MATCHER_HEALTH_ADDR=:$MATCHER_HEALTH_PORT
WS_ALLOWED_ORIGINS=http://localhost:3000
ENV
} >"$DIR/markets.env"
{ prod_env execution-service "$LOCAL_ONLY"; cat <<ENV
CHAIN_ID=31337
RPC_URL=$RPC
PRIVATE_KEY=$EXECUTOR_KEY
PORT=$EXEC_PORT
HOST=127.0.0.1
DEPOSITS_ENABLED=false
WAIT_FOR_RECEIPT=true
ENV
} >"$DIR/execution.env"
grep -q '^OPTION_SERIES=' "$DIR/markets.env" || { echo "production markets lists no OPTION_SERIES" >&2; exit 1; }
grep -E '^# from' "$DIR/markets.env" "$DIR/execution.env"

step "postgres on :$PG_PORT, migrations, builds"
[ -d "$DIR/pgdata" ] || initdb -D "$DIR/pgdata" -U postgres --auth=trust >/dev/null
pg_ctl -D "$DIR/pgdata" -o "-p $PG_PORT -c unix_socket_directories=''" -l "$DIR/logs/postgres.log" start >/dev/null
wait_for postgres psql -h 127.0.0.1 -p $PG_PORT -U postgres -c 'select 1'
dropdb -h 127.0.0.1 -p $PG_PORT -U postgres --if-exists matching_backend
createdb -h 127.0.0.1 -p $PG_PORT -U postgres matching_backend
(cd "$ROOT/services/markets" && DATABASE_URL=$DB go run ./cmd/migrate >"$DIR/logs/migrate.log" 2>&1)
(cd "$ROOT/services/markets" && go build -o "$DIR/bin/markets-api" ./cmd/api && go build -o "$DIR/bin/markets-matcher" ./cmd/matcher)
(cd "$ROOT/services/execution" && pnpm run build >/dev/null)
(cd "$MM_REPO" && go build -o "$DIR/bin/mm-bot" ./cmd/mm-bot)
echo "market-maker $(git -C "$MM_REPO" rev-parse --abbrev-ref HEAD)@$(git -C "$MM_REPO" rev-parse --short HEAD)"

step "services: execution :$EXEC_PORT, markets api :$API_PORT, matcher"
(cd "$ROOT/services/execution" && set -a && . "$DIR/execution.env" && set +a && start execution node dist/index.js)
(set -a; . "$DIR/markets.env"; set +a; start markets-api "$DIR/bin/markets-api"; start markets-matcher "$DIR/bin/markets-matcher")
wait_for execution curl -sf http://127.0.0.1:$EXEC_PORT/healthz
wait_for "markets api" curl -sf http://127.0.0.1:$API_PORT/markets
curl -sf http://127.0.0.1:$API_PORT/markets | python3 -c '
import json, sys
opts = [m for m in json.load(sys.stdin) if m.get("contract_type") == "option"]
assert opts, "no option markets listed"
assert all(m["option"]["trading_open"] for m in opts), "an option strike is not trading_open on the fork"
print("%d option strikes listed, all open, unit %s" % (len(opts), opts[0]["ui_size_unit"]))'

step "accounts under MarginEngine v2"
$OPT open-account mm 2000
$OPT open-account taker 500
MM_ID=$(python3 -c "import json;print(json.load(open('$DIR/accounts.json'))['mm'])")
MM_KEY=$(key mm)
MM_ADDR=$(cast wallet address --private-key "$MM_KEY")

step "mm-bot options mode ($SERIES), account $MM_ID"
cat >"$DIR/mm.env" <<ENV
MM_OPTION_SERIES=$SERIES
MM_MARKET_SYMBOL=$STRIKE
MM_API_BASE_URL=http://127.0.0.1:$API_PORT
MM_RPC_URL=$RPC
MM_DATABASE_URL=$DB
MM_CHAIN_ID=31337
MM_MATCHING_ADDRESS=$MATCHING
MM_TRADE_MODULE_ADDRESS=0xDea968188598BA0E3F58A56C0fdfF338C74F699f
MM_SUBACCOUNTS_ADDRESS=0x7019244E25FA416e6Ca2ed2F3cA25277aef72843
MM_SIGNER_BACKEND=local
MM_OWNER_PRIVATE_KEY=$MM_KEY
MM_OWNER_ADDRESS=$MM_ADDR
MM_SIGNER_ADDRESS=$MM_ADDR
MM_SUBACCOUNT_ID=$MM_ID
MM_RECIPIENT_ID=$MM_ID
MM_STATE_FILE=$DIR/mm-state.json
MM_METRICS_ADDR=127.0.0.1:$MM_METRICS_PORT
MM_ORDER_EXPIRY_SECONDS=300
MM_MAX_LONG_INVENTORY=300000
MM_MAX_SHORT_INVENTORY=-300000
MM_OPERATOR_MODE=normal
MM_DRY_RUN=false
ENV
(set -a; . "$DIR/mm.env"; set +a; start mm-bot "$DIR/bin/mm-bot")
two_sided() { # every listed strike has a bid and an ask resting
  curl -sf http://127.0.0.1:$API_PORT/markets | python3 -c '
import json, sys, urllib.request
syms = [m["market"] for m in json.load(sys.stdin) if m.get("contract_type") == "option"]
for s in syms:
    b = json.load(urllib.request.urlopen("http://127.0.0.1:'$API_PORT'/book?symbol=" + s))
    if not b.get("bids") and not b.get("asks"):
        sys.exit(1)
'
}
wait_for "the maker to quote every strike" two_sided
for S in $(curl -sf http://127.0.0.1:$API_PORT/markets | python3 -c 'import json,sys;[print(m["market"]) for m in json.load(sys.stdin) if m.get("contract_type")=="option"]'); do
  printf '%-26s %s\n' "$S" "$($OPT best "$S")"
done

step "taker buys 10 units (10,000 cNGN) of $STRIKE at the maker's ask"
$OPT take taker "$STRIKE" buy 10

step "break it: past the vol feed's 1800s heartbeat, the maker must pull every quote"
cast rpc evm_increaseTime 1900 --rpc-url $RPC >/dev/null
cast rpc evm_mine --rpc-url $RPC >/dev/null
# Spot (1200s) goes stale with it, and the forward with spot: the bot cannot read any strike, halts each one
# ("option state unreadable") and cancels its quotes.
pulled() { ! two_sided_any; }
two_sided_any() { # any strike still has a quote resting
  curl -sf http://127.0.0.1:$API_PORT/markets | python3 -c '
import json, sys, urllib.request
syms = [m["market"] for m in json.load(sys.stdin) if m.get("contract_type") == "option"]
sys.exit(0 if any(json.load(urllib.request.urlopen("http://127.0.0.1:'$API_PORT'/book?symbol=" + s)).get(k) for s in syms for k in ("bids", "asks")) else 1)
'
}
wait_for "the maker to pull every strike after the feeds went stale" pulled
grep -E 'msg=halted' "$DIR/logs/mm-bot.log" | sed -E 's/.*market=([^ ]+).*reason="([^"]+)".*/\1 \2/' | sort -u
echo "OK: quoted, filled as the engine margins it, and pulled on a stale surface"
