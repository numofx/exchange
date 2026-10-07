#!/usr/bin/env bash
# The whole perp venue on your machine, launched the way mainnet will be:
#
#   BASE_RPC_URL=<archive-capable Base RPC> ./scripts/local-venue/up.sh
#
#  1. anvil forks Base as chain 31337 (nothing reads or writes the 8453 artifacts)
#  2. the real deploy scripts put up the perp stack (cap 0) and its TradeModule (not allowlisted)
#  3. the deploy batches run as the vault would run them (impersonated): acceptOwnership only
#  4. Postgres, migrations, markets api + matcher, execution-service
#  5. perp-feeds --local-fixed-price, the keeper (live, /health on), the SecurityModule seed, a quote
#  6. propose_perp_enable_batch.py --local checks every launch gate and writes the enable actions;
#     they are applied as the vault (impersonated) -- the step that opens the market
#  7. a taker crosses the quote and the position is read back from /v1/positions, then withdraws
#     100 USDC of margin by a signed WithdrawalModule action on the perp cash
#
# Everything runs in the background with logs and pids under $LOCAL_VENUE_DIR (default
# .local-venue/ at the repo root). ./scripts/local-venue/down.sh stops it all.
#
#   up.sh --spot-only   the spot regression instead: no perp deployed, and every perp variable
#                       unset on markets-service and execution-service, exactly as they run before the
#                       perp's Terraform vars are set. A spot fill (checked against the fill contract)
#                       and a spot withdrawal must go through.
#   up.sh --unified     spot on the perp stack: the spot market's asset is the perp's cNGN escrow, its
#                       module the perp TradeModule and its quote the perp cash, so one account under
#                       the perp SRM trades spot and perp and all of it is margin. What the unified
#                       cutover configures on mainnet (unified-rules.sh then checks it).
set -euo pipefail
SPOT_ONLY=0
UNIFIED=0
[ "${1:-}" = "--spot-only" ] && SPOT_ONLY=1
[ "${1:-}" = "--unified" ] && UNIFIED=1
: "${BASE_RPC_URL:?set BASE_RPC_URL (an archive-capable Base RPC to fork)}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DIR="${LOCAL_VENUE_DIR:-$ROOT/.local-venue}"
mkdir -p "$DIR/logs" "$DIR/pids" "$DIR/bin"

ANVIL_PORT=8600 PG_PORT=5544 API_PORT=8090 EXEC_PORT=8091 KEEPER_HEALTH_PORT=9464
RPC="http://127.0.0.1:$ANVIL_PORT"
INDEX_NGN_PER_USD="${INDEX_NGN_PER_USD:-1374}"
DB="postgres://postgres@127.0.0.1:$PG_PORT/matching_backend?sslmode=disable"
INDEX_STATUS_TOKEN=local-venue-index-status-token

VAULT=0x1dcA42ab54Bd3862853A821F84B29BF65245F435
MATCHING=0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191
DATA_SUBMITTER=0xe0C06DD245f1e8C8bC516c66C66e64648987F912
SUB_ACCOUNTS=0x7019244E25FA416e6Ca2ed2F3cA25277aef72843
# anvil's first default key: only ever used on this fork, as the deployer and the feed relayer
DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
key() { cast keccak "numo.local-venue.$1"; }
FEED_SIGNER_KEY=$(key feed-signer)
EXECUTOR_KEY=$(key executor)
KEEPER_KEY=$(key keeper)
GUARDIAN=$(cast wallet address --private-key "$(key guardian)")

step() { printf '\n== %s\n' "$*"; }
start() { # start <name> <cmd...>: background, logged, pid recorded
  local name=$1; shift
  nohup "$@" >"$DIR/logs/$name.log" 2>&1 &
  echo $! >"$DIR/pids/$name"
}
wait_for() { # wait_for <what> <cmd...>
  local what=$1; shift
  for _ in $(seq 1 60); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  echo "timed out waiting for $what (logs in $DIR/logs)" >&2; exit 1
}
as_vault() { cast send "$@" --from $VAULT --unlocked --rpc-url $RPC >/dev/null; }
json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$@"; }

"$HERE/down.sh" >/dev/null 2>&1 || true
# A fresh fork every run: nothing from the last one (account labels, index samples, step audit) applies.
rm -f "$DIR/accounts.json" "$DIR/venue.json" "$DIR/perp-index-state.json" "$DIR/perp-index-steps.jsonl" "$DIR/enable-actions.json" "$DIR/pager-capture.log"

step "anvil: Base fork as chain 31337 on :$ANVIL_PORT"
start anvil anvil --fork-url "$BASE_RPC_URL" --chain-id 31337 --port $ANVIL_PORT --silent
wait_for anvil cast chain-id --rpc-url $RPC
[ "$(cast chain-id --rpc-url $RPC)" = 31337 ] || { echo "not a local fork" >&2; exit 1; }

EXECUTOR=$(cast wallet address --private-key "$EXECUTOR_KEY")
cast rpc anvil_impersonateAccount $VAULT --rpc-url $RPC >/dev/null
cast rpc anvil_setBalance $VAULT 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null
# The local executor stands in for the venue's KMS key.
as_vault $MATCHING "setTradeExecutor(address,bool)" "$EXECUTOR" true
cast rpc anvil_setBalance "$EXECUTOR" 0xDE0B6B3A7640000 --rpc-url $RPC >/dev/null

if [ "$SPOT_ONLY" = 0 ]; then
step "deploy: perp stack (cap 0) and TradeModule (not allowlisted)"
(cd "$ROOT/contracts/risk-core" && FEED_SIGNER=$(cast wallet address --private-key "$FEED_SIGNER_KEY") PERP_GUARDIAN=$GUARDIAN \
  forge script test/e2e/DeployPerpStackForE2E.s.sol --sig "runE2E()" --rpc-url $RPC \
  --private-key $DEPLOYER --broadcast --non-interactive >"$DIR/logs/deploy-stack.log" 2>&1)
(cd "$ROOT/contracts/execution" && forge script test/e2e/DeployPerpModuleForE2E.s.sol --sig "runE2E()" \
  --rpc-url $RPC --private-key $DEPLOYER --broadcast --non-interactive >"$DIR/logs/deploy-module.log" 2>&1)
STACK="$ROOT/contracts/risk-core/cache/e2e-perp-stack.json"
MODULE_JSON="$ROOT/contracts/execution/cache/e2e-perp-module.json"
MODULE=$(json "$MODULE_JSON" tradePerp)

step "vault: the deploy batches (acceptOwnership everywhere, then the SRM guardian; nothing opens the market)"
# The stack batch exactly as the deploy script writes it for the vault, guardian included.
python3 -c "import json,sys;[print(a['to'], a['data']) for a in json.load(open(sys.argv[1]))]" \
  "$ROOT/contracts/risk-core/cache/e2e-perp-stack-vault-actions.json" |
  while read -r TO DATA; do cast send "$TO" "$DATA" --from $VAULT --unlocked --rpc-url $RPC >/dev/null; done
as_vault "$MODULE" "acceptOwnership()"
echo "cap=$(cast call "$(json "$STACK" perp)" 'totalPositionCap(address)(uint256)' "$(json "$STACK" srm)" --rpc-url $RPC)" \
  "module allowed=$(cast call $MATCHING 'allowedModules(address)(bool)' "$MODULE" --rpc-url $RPC)" \
  "guardian=$(cast call "$(json "$STACK" srm)" 'guardian()(address)' --rpc-url $RPC)"

step "deploy: the perp's cNGN collateral escrow and rate model, then both vault batches (haircut 50%, cap 8M cNGN, 10% floor)"
(cd "$ROOT/contracts/risk-core" && forge script test/e2e/DeployCngnPerpCollateralForE2E.s.sol --sig "runE2E()" \
  --rpc-url $RPC --private-key $DEPLOYER --broadcast --non-interactive >"$DIR/logs/deploy-collateral.log" 2>&1)
COLLATERAL="$ROOT/contracts/risk-core/cache/e2e-perp-collateral.json"
python3 -c "import json,sys;[print(a['to'], a['data']) for a in json.load(open(sys.argv[1]))]" \
  "$ROOT/contracts/risk-core/cache/e2e-perp-collateral-vault-actions.json" |
  while read -r TO DATA; do cast send "$TO" "$DATA" --from $VAULT --unlocked --rpc-url $RPC >/dev/null; done
# The enabling action is its own batch on mainnet (signed after the services are live); here the
# services come up against an open escrow, so it is applied straight after.
python3 -c "import json,sys;[print(a['to'], a['data']) for a in json.load(open(sys.argv[1]))]" \
  "$ROOT/contracts/risk-core/cache/e2e-perp-collateral-enable-vault-actions.json" |
  while read -r TO DATA; do cast send "$TO" "$DATA" --from $VAULT --unlocked --rpc-url $RPC >/dev/null; done
CNGN_ESCROW=$(json "$COLLATERAL" escrow)
echo "cngn escrow=$CNGN_ESCROW open=$(cast call "$CNGN_ESCROW" 'whitelistedManager(address)(bool)' "$(json "$STACK" srm)" --rpc-url $RPC)" \
  "factor=$(cast call "$(json "$STACK" srm)" 'baseMarginParams(uint256)(uint256,uint256)' 1 --rpc-url $RPC | head -1)" \
  "cap=$(cast call "$CNGN_ESCROW" 'totalPositionCap(address)(uint256)' "$(json "$STACK" srm)" --rpc-url $RPC)" \
  "rateModel=$(cast call "$(json "$STACK" cash)" 'rateModel()(address)' --rpc-url $RPC)"

python3 - "$STACK" "$MODULE" "$DIR/venue.json" "$CNGN_ESCROW" "$UNIFIED" <<'PY'
import json, sys
stack = json.load(open(sys.argv[1]))
stack["tradePerp"] = sys.argv[2]
stack["cngnEscrow"] = sys.argv[4]
stack["unified"] = sys.argv[5] == "1"
json.dump(stack, open(sys.argv[3], "w"), indent=2)
PY
V="$DIR/venue.json"
PERP=$(json "$V" perp) CASH=$(json "$V" cash) SRM=$(json "$V" srm)
PERP_MARKETS_ENV="CNGN_PERP_ASSET_ADDRESS=$PERP
CNGN_PERP_TRADE_MODULE_ADDRESS=$MODULE
CNGN_PERP_CASH_ADDRESS=$CASH
CNGN_PERP_SRM_ADDRESS=$SRM
CNGN_PERP_COLLATERAL_ADDRESS=$CNGN_ESCROW"
PERP_EXEC_ENV="PERP_TRADE_MODULE_ADDRESS=$MODULE"
if [ "$UNIFIED" = 1 ]; then
  step "unified: spot on the perp stack (asset = cNGN escrow, module = perp TradeModule, quote = perp cash, manager = perp SRM)"
  SPOT_ASSET=$CNGN_ESCROW SPOT_MODULE=$MODULE SPOT_QUOTE=$CASH SPOT_MANAGER_ENV="SPOT_MARGIN_MANAGER_ADDRESS=$SRM"
fi
else
  step "spot only: no perp deployed, every perp variable left unset"
  PERP_MARKETS_ENV="" PERP_EXEC_ENV="" CASH="" CNGN_ESCROW=""
fi

# The spot market's stack: Base's own (the fork inherits it), or the perp's under --unified. The
# legacy spot assets stay withdrawable either way, as they must on mainnet after the cutover.
SPOT_ASSET=${SPOT_ASSET:-0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493}
SPOT_MODULE=${SPOT_MODULE:-0x12423B366F6F07130961900bE00d05Ea63Acd071}
SPOT_QUOTE=${SPOT_QUOTE:-0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84}
SPOT_MANAGER_ENV=${SPOT_MANAGER_ENV:-}
WITHDRAWAL_ASSETS="0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84,0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493${CASH:+,$CASH}${CNGN_ESCROW:+,$CNGN_ESCROW}"

step "postgres on :$PG_PORT, migrations"
command -v pg_ctl >/dev/null || { echo "needs Postgres binaries (brew install postgresql)" >&2; exit 1; }
[ -d "$DIR/pgdata" ] || initdb -D "$DIR/pgdata" -U postgres --auth=trust >/dev/null
# TCP only: the socket path under a deep $DIR can exceed the 103-byte limit.
pg_ctl -D "$DIR/pgdata" -o "-p $PG_PORT -c unix_socket_directories=''" -l "$DIR/logs/postgres.log" start >/dev/null
wait_for postgres psql -h 127.0.0.1 -p $PG_PORT -U postgres -c 'select 1'
dropdb -h 127.0.0.1 -p $PG_PORT -U postgres --if-exists matching_backend
createdb -h 127.0.0.1 -p $PG_PORT -U postgres matching_backend
(cd "$ROOT/services/markets" && DATABASE_URL=$DB go run ./cmd/migrate >"$DIR/logs/migrate.log" 2>&1)

step "build: markets, execution, perp-feeds, perp-keeper"
(cd "$ROOT/services/markets" && go build -o "$DIR/bin/markets-api" ./cmd/api && go build -o "$DIR/bin/markets-matcher" ./cmd/matcher)
for S in execution perp-feeds perp-keeper; do (cd "$ROOT/services/$S" && pnpm run build >/dev/null); done

cat >"$DIR/markets.env" <<ENV
APP_ENV=dev
API_ADDR=:$API_PORT
DATABASE_URL=$DB
CHAIN_RPC_URL=$RPC
CHAIN_ID=31337
MATCHING_ADDRESS=$MATCHING
TRADE_MODULE_ADDRESS=$SPOT_MODULE
QUOTE_ASSET_ADDRESS=$SPOT_QUOTE
CNGN_SPOT_ASSET_ADDRESS=$SPOT_ASSET
$SPOT_MANAGER_ENV
$PERP_MARKETS_ENV
# The index-lag gate as production runs it (enforced, 100 bps, 300s), fed by the local publisher's
# spot reports: a pre-check that wrongly runs on spot refuses spot orders here as it would on Base.
INDEX_STATUS_TOKEN=$INDEX_STATUS_TOKEN
INDEX_LAG_GATE=true
INDEX_LAG_MAX_BPS=100
INDEX_STATUS_MAX_AGE=300s
ENFORCE_MATCHING_CUSTODY=true
WITHDRAWAL_MODULE_ADDRESS=0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB
WITHDRAWAL_ASSET_ADDRESSES=$WITHDRAWAL_ASSETS
EXECUTOR_WITHDRAW_URL=http://127.0.0.1:$EXEC_PORT/withdraw
EXECUTOR_URL=http://127.0.0.1:$EXEC_PORT/execute
EXECUTOR_TIMEOUT=90s
MATCHER_POLL_INTERVAL=500ms
WS_ALLOWED_ORIGINS=http://localhost:3000,http://localhost:3111
ENV

step "services: execution :$EXEC_PORT, markets api :$API_PORT, matcher"
(cd "$ROOT/services/execution" && RPC_URL=$RPC CHAIN_ID=31337 PRIVATE_KEY=$EXECUTOR_KEY MATCHING_ADDRESS=$MATCHING \
  TRADE_MODULE_ADDRESS=$SPOT_MODULE \
  WITHDRAWAL_MODULE_ADDRESS=0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB \
  WITHDRAWAL_ASSET_ADDRESSES=$WITHDRAWAL_ASSETS \
  PORT=$EXEC_PORT HOST=127.0.0.1 DRY_RUN=false WAIT_FOR_RECEIPT=true start execution env $PERP_EXEC_ENV node dist/index.js)
(set -a; . "$DIR/markets.env"; set +a; start markets-api "$DIR/bin/markets-api"; start markets-matcher "$DIR/bin/markets-matcher")
wait_for execution curl -sf http://127.0.0.1:$EXEC_PORT/healthz
wait_for "markets api" curl -sf http://127.0.0.1:$API_PORT/v1/markets

# What perp-feeds does on Base after every sample: report spot to the venue's index-lag gate. The
# local publisher runs at a fixed price and takes no samples, so this loop reports that price every
# 30s in the publisher's format; without it the enforced gate is blind and refuses perp orders.
if [ "$SPOT_ONLY" = 0 ]; then
  cat >"$DIR/bin/index-status-reporter.sh" <<REPORTER
#!/usr/bin/env bash
USDC_PER_CNGN=\$(python3 -c "print(f'{1 / $INDEX_NGN_PER_USD:.18f}')")
while :; do
  curl -s -o /dev/null -X POST -H "X-Numo-Index-Token: $INDEX_STATUS_TOKEN" -H "content-type: application/json" \\
    -d "{\\"at_ms\\": \$(( \$(date +%s) * 1000 )), \\"usdc_per_cngn\\": \\"\$USDC_PER_CNGN\\", \\"sample_ok\\": true}" \\
    http://127.0.0.1:$API_PORT/v1/internal/index-status
  sleep 30
done
REPORTER
  chmod +x "$DIR/bin/index-status-reporter.sh"
  start index-status-reporter "$DIR/bin/index-status-reporter.sh"
  # The venue answers 204 to a report it recorded; the sample shows on /v1/markets only once the perp
  # block exists (after the index feed is published, below), which unified-rules.sh asserts.
  wait_for "index-status report accepted" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST -H 'X-Numo-Index-Token: $INDEX_STATUS_TOKEN' -H 'content-type: application/json' -d '{\"at_ms\": '\$(( \$(date +%s) * 1000 ))', \"usdc_per_cngn\": \"0.000727802037845705\", \"sample_ok\": true}' http://127.0.0.1:$API_PORT/v1/internal/index-status)\" = 204 ]"
fi

VENUE="pnpm --dir $HERE exec tsx $HERE/venue.ts $DIR"
if [ "$SPOT_ONLY" = 1 ]; then
  step "spot regression: /v1/markets, a fill, a withdrawal"
  curl -sf http://127.0.0.1:$API_PORT/v1/markets | python3 -c "
import json, sys
markets = [m['market'] for m in json.load(sys.stdin)]
assert markets == ['USDCcNGN-SPOT'], f'expected spot only, got {markets}'
print('ok: /v1/markets serves spot only:', markets)"
  $VENUE spot-account usdc-maker usdc 1000
  $VENUE spot-account cngn-taker cngn 200000
  # The UI contract is the engine's: a price in USDC per cNGN and a size in cNGN ($100 worth).
  SPOT_PRICE=$(python3 -c "from decimal import Decimal; print(format((Decimal(1) / Decimal($INDEX_NGN_PER_USD)).quantize(Decimal('1e-18')), 'f'))")
  $VENUE spot-cross $SPOT_PRICE $((100 * INDEX_NGN_PER_USD))
  $VENUE spot-withdraw usdc-maker 10
  printf '\nSpot regression passed. Logs: %s/logs    Stop: %s/down.sh\n' "$DIR" "$HERE"
  exit 0
fi

step "perp-feeds --local-fixed-price=$INDEX_NGN_PER_USD"
cat >"$DIR/perp-feeds.env" <<ENV
RPC_URL=$RPC
CHAIN_ID=31337
FEED_SIGNER_KEY=$FEED_SIGNER_KEY
RELAYER_KEY=$DEPLOYER
DATA_SUBMITTER=$DATA_SUBMITTER
PERP_ASSET=$PERP
INDEX_FEED=$(json "$V" indexFeed)
MARK_FEED=$(json "$V" markFeed)
IMPACT_ASK_FEED=$(json "$V" impactAskFeed)
IMPACT_BID_FEED=$(json "$V" impactBidFeed)
MARKETS_SERVICE_URL=http://127.0.0.1:$API_PORT
INDEX_STATE_FILE=$DIR/perp-index-state.json
INDEX_STEP_AUDIT_FILE=$DIR/perp-index-steps.jsonl
INDEX_STATUS_FILE=$DIR/perp-index-status.json
KEEPER_HEALTH_URL=http://127.0.0.1:$KEEPER_HEALTH_PORT/health
INDEX_STATUS_PUSH_URL=http://127.0.0.1:$API_PORT/v1/internal/index-status
INDEX_STATUS_TOKEN=$INDEX_STATUS_TOKEN
ENV
(cd "$ROOT/services/perp-feeds" && set -a && . "$DIR/perp-feeds.env" && set +a && \
  start perp-feeds node dist/main.js --local-fixed-price="$INDEX_NGN_PER_USD")
wait_for "index feed" cast call "$(json "$V" indexFeed)" "getSpot()(uint256,uint256)" --rpc-url $RPC

step "keeper: funded account under the perp SRM, live, /health on :$KEEPER_HEALTH_PORT"
# Created by the keeper's own EOA (label "keeper" is KEEPER_KEY) straight on SubAccounts, not through
# SubAccountCreator: that parks the account in Matching, and the keeper could not fund bids from it.
$VENUE keeper-account 20000
(cd "$ROOT/services/perp-keeper" && RPC_URL=$RPC CHAIN_ID=31337 KEEPER_KEY=$KEEPER_KEY \
  KEEPER_ACCOUNT="$(json "$DIR/accounts.json" keeper)" DRY_RUN=false SUB_ACCOUNTS=$SUB_ACCOUNTS SRM=$SRM \
  AUCTION="$(json "$V" auction)" CASH=$CASH PERP=$PERP SECURITY_MODULE_ACCOUNT="$(json "$V" securityModuleAccount)" \
  START_BLOCK="$(json "$V" blockNumber)" POLL_INTERVAL_MS=5000 HEALTH_PORT=$KEEPER_HEALTH_PORT MAX_BID_USD=2500 AUCTION_OPEN_WARN_MS="${AUCTION_OPEN_WARN_MS:-600000}" \
  CNGN_ESCROW="$(json "$V" cngnEscrow)" MAX_CNGN_INVENTORY=25000000 \
  start perp-keeper node dist/main.js)
wait_for "keeper health" sh -c "curl -sf http://127.0.0.1:$KEEPER_HEALTH_PORT/health | grep -q '\"lastPassOk\":true'"

step "security module seed, maker quote"
$VENUE fund-sm 10000
$VENUE account maker 20000
$VENUE account taker 5000
$VENUE quote

step "pager: one run against a local capture server (the enable gate requires a live pager)"
# PagerDuty's shape and a heartbeat endpoint, both captured locally: nothing leaves the machine.
cat >"$DIR/capture.py" <<'PY'
import http.server, sys
out = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def _log(self, body):
        open(out, "a").write(f"{self.command} {self.path} {body}\n")
        self.send_response(200); self.end_headers()
    def do_POST(self): self._log(self.rfile.read(int(self.headers["Content-Length"])).decode())
    def do_GET(self): self._log("")
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[2])), H).serve_forever()
PY
start pager-capture python3 "$DIR/capture.py" "$DIR/pager-capture.log" 9780
wait_for "pager capture" curl -sf http://127.0.0.1:9780/ready
PAGER_ENV="RPC_URL=$RPC KEEPER_HEALTH_URL=http://127.0.0.1:$KEEPER_HEALTH_PORT/health MATCHER_HEALTH_URL=http://127.0.0.1:$API_PORT/v1/health PAGER_PROVIDER=pagerduty
PAGERDUTY_URL=http://127.0.0.1:9780/page PAGERDUTY_ROUTING_KEY=local PAGER_HEARTBEAT_URL=http://127.0.0.1:9780/hb
PAGE_PREFIX=[LOCAL] PAGER_STATE_FILE=$DIR/pager-state.json PERP_INDEX_STATUS_FILE=$DIR/perp-index-status.json ALERT_WEBHOOK_URL="
rm -f "$DIR/pager-state.json"
(cd "$ROOT/contracts/risk-core" && env $PAGER_ENV python3 scripts/ops/check_perp_pager.py --stack "$V")
grep -q "GET /hb " "$DIR/pager-capture.log" || { echo "the pager did not ping its dead-man's switch" >&2; exit 1; }

step "enable: every launch gate, then the enable actions as the vault"
ACTIONS="$DIR/enable-actions.json"
(cd "$ROOT/contracts/risk-core" && RPC_URL=$RPC KEEPER_HEALTH_URL=http://127.0.0.1:$KEEPER_HEALTH_PORT/health MATCHER_HEALTH_URL=http://127.0.0.1:$API_PORT/v1/health \
  PAGER_STATE_FILE="$DIR/pager-state.json" \
  MARKETS_URL=http://127.0.0.1:$API_PORT python3 scripts/ops/propose_perp_enable_batch.py --local \
  --stack "$V" --module "$MODULE_JSON" --write "$ACTIONS")
python3 -c "import json,sys;[print(a['to'], a['data']) for a in json.load(open(sys.argv[1]))]" "$ACTIONS" |
  while read -r TO DATA; do cast send "$TO" "$DATA" --from $VAULT --unlocked --rpc-url $RPC >/dev/null; done
echo "cap=$(cast call "$PERP" 'totalPositionCap(address)(uint256)' "$SRM" --rpc-url $RPC)" \
  "module allowed=$(cast call $MATCHING 'allowedModules(address)(bool)' "$MODULE" --rpc-url $RPC)"
wait_for "trading_enabled" sh -c "curl -sf http://127.0.0.1:$API_PORT/v1/markets | grep -q '\"trading_enabled\":true'"

step "smoke: taker crosses the maker's offer"
$VENUE cross

step "smoke: taker withdraws 100 USDC of margin (WithdrawalModule on the perp cash, as the app does)"
$VENUE withdraw taker 100

cat <<DONE

Local venue up$([ "$UNIFIED" = 1 ] && echo " (UNIFIED: spot on the perp stack; run unified-rules.sh)"). Point trading-app at it:
  MARKETS_SERVICE_URL=http://127.0.0.1:$API_PORT
  NEXT_PUBLIC_MARKETS_WS_URL=ws://127.0.0.1:$API_PORT/v1/ws
  NEXT_PUBLIC_BASE_RPC_URL=$RPC
(orders the app signs name chain 8453 in their domain; the local venue verifies against 31337)

Logs: $DIR/logs    Stop: $HERE/down.sh
DONE
