#!/usr/bin/env bash
# The keeper against the real perp stack on an anvil fork of Base:
#   BASE_RPC_URL=<archive-capable Base RPC> ./scripts/e2e.sh
# Forks Base (as chain 31337, so nothing reads or writes the 8453 artifacts), deploys the stack with
# risk-core's own deploy script, then runs src/keeper.anvil.test.ts against it.
set -euo pipefail
: "${BASE_RPC_URL:?set BASE_RPC_URL}"
PORT="${E2E_PORT:-8600}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
RISK_CORE="$HERE/../../contracts/risk-core"
# keccak256("numo.perp-keeper.e2e.feed-signer"), the key the test signs feeds with
FEED_SIGNER=0x413EC43faa999e8BAd0A1Bd71E3D09B056de2913
# anvil's first default key, only ever used on this local fork
DEPLOYER=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

anvil --fork-url "$BASE_RPC_URL" --chain-id 31337 --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do cast chain-id --rpc-url "http://127.0.0.1:$PORT" >/dev/null 2>&1 && break; sleep 1; done

(cd "$RISK_CORE" && FEED_SIGNER=$FEED_SIGNER PERP_GUARDIAN=0x0000000000000000000000000000000000006A2d forge script test/e2e/DeployPerpStackForE2E.s.sol --sig "runE2E()" \
  --rpc-url "http://127.0.0.1:$PORT" --private-key "$DEPLOYER" --broadcast --non-interactive >/dev/null)

cd "$HERE" && KEEPER_E2E_RPC_URL="http://127.0.0.1:$PORT" node --import tsx --test src/keeper.anvil.test.ts
