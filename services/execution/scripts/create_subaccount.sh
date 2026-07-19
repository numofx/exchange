#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"

CHAIN_ID="${CHAIN_ID:-8453}"
EXCHANGE_CORE_REPO_PATH="${EXCHANGE_CORE_REPO_PATH:-../exchange-core}"
MATCHING_ADDRESS="${MATCHING_ADDRESS:-0xe4c2a55401F73A540CA6e1C43067Aa7164f89088}"
MARKET="${MARKET:-BTC_SQUARED}"
MANAGER_ADDRESS="${MANAGER_ADDRESS:-}"

if [[ -z "$MANAGER_ADDRESS" ]]; then
  deployment_file="$EXCHANGE_CORE_REPO_PATH/deployments/$CHAIN_ID/$MARKET.json"
  if [[ ! -f "$deployment_file" ]]; then
    echo "Missing deployment file: $deployment_file" >&2
    exit 1
  fi
  MANAGER_ADDRESS="$(jq -r '.manager' "$deployment_file")"
fi

if [[ -z "$MANAGER_ADDRESS" || "$MANAGER_ADDRESS" == "null" ]]; then
  echo "Manager address is required. Set MANAGER_ADDRESS or choose a market deployment with a manager." >&2
  exit 1
fi

echo "rpc_url=$RPC_URL"
echo "matching=$MATCHING_ADDRESS"
echo "market=$MARKET"
echo "manager=$MANAGER_ADDRESS"
echo "sender=$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "action=createSubAccount"

cast send \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  "$MATCHING_ADDRESS" \
  "createSubAccount(address)" \
  "$MANAGER_ADDRESS"
