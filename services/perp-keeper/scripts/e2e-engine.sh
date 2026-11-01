#!/usr/bin/env bash
# The keeper against the live MarginEngine and MarginEngine v2 on an anvil fork of Base at head
# (engine-keeper.anvil.test.ts, engine-keeper-v2.anvil.test.ts): no deploy step, both engines are already there. Then
# the expired-option sweep on v2 (engine-keeper-v2-options.anvil.test.ts), which deploys cNGN options from risk-core's
# artifacts, warps a month and reverts its snapshot: last, so it never moves the clock under the others.
# One file at a time: they share the fork. Needs BASE_RPC_URL.
set -euo pipefail
: "${BASE_RPC_URL:?set BASE_RPC_URL}"
PORT="${E2E_ENGINE_PORT:-8605}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
(cd "$HERE/../../contracts/risk-core" && forge build src/assets/OptionAsset.sol src/feeds/LyraVolFeed.sol src/feeds/FutureFixingSettlementFeed.sol >/dev/null)
anvil --fork-url "$BASE_RPC_URL" --chain-id 31337 --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done
cd "$HERE" && ENGINE_KEEPER_E2E_RPC_URL="http://127.0.0.1:$PORT" OPTIONS_KEEPER_E2E_RPC_URL="http://127.0.0.1:$PORT" \
  node --import tsx --test --test-concurrency=1 src/engine-keeper.anvil.test.ts src/engine-keeper-v2.anvil.test.ts \
  src/engine-keeper-v2-options.anvil.test.ts
