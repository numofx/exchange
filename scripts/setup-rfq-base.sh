#!/usr/bin/env bash
set -euo pipefail

# Configure an RFQ-first launch profile on Base for a deployed matching stack.
#
# Required env vars:
#   BASE_RPC_URL=https://mainnet.base.org
#   PRIVATE_KEY=0x...
#   KEEPER=0xYourKeeperExecutorAddress
#
# Optional env vars:
#   CHAIN_ID=8453
#   MATCHING_DEPLOYMENT_FILE=deployments/<chainId>/matching.json
#   CORE_DEPLOYMENT_FILE=../../exchange-core/deployments/<chainId>/core.json
#   DISABLE_DEFAULT_EXECUTOR=true|false   (default: true)
#   DISABLE_ATOMIC_EXECUTOR=true|false    (default: true)
#   FEE_RECIPIENT_ACCOUNT_ID=<uint>       (default: auto from SecurityModule.accountId())

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required env var: $name" >&2
    exit 1
  fi
}

send_tx() {
  local to="$1"
  local sig="$2"
  shift 2
  cast send "$to" "$sig" "$@" --private-key "$PRIVATE_KEY" --rpc-url "$BASE_RPC_URL" >/dev/null
}

set_allowed_module() {
  local module="$1"
  local desired="$2" # true|false
  local current
  current="$(cast call "$MATCHING" "allowedModules(address)(bool)" "$module" --rpc-url "$BASE_RPC_URL")"
  if [[ "$current" == "$desired" ]]; then
    echo "skip module $module already $desired"
    return
  fi
  echo "set module $module -> $desired"
  send_tx "$MATCHING" "setAllowedModule(address,bool)" "$module" "$desired"
}

set_trade_executor() {
  local executor="$1"
  local desired="$2" # true|false
  local current
  current="$(cast call "$MATCHING" "tradeExecutors(address)(bool)" "$executor" --rpc-url "$BASE_RPC_URL")"
  if [[ "$current" == "$desired" ]]; then
    echo "skip executor $executor already $desired"
    return
  fi
  echo "set executor $executor -> $desired"
  send_tx "$MATCHING" "setTradeExecutor(address,bool)" "$executor" "$desired"
}

set_fee_recipient() {
  local desired="$1"
  local current
  current="$(cast call "$RFQ" "feeRecipient()(uint256)" --rpc-url "$BASE_RPC_URL")"
  if [[ "$current" == "$desired" ]]; then
    echo "skip rfq feeRecipient already $desired"
    return
  fi
  echo "set rfq feeRecipient -> $desired"
  send_tx "$RFQ" "setFeeRecipient(uint256)" "$desired"
}

require_cmd cast
require_cmd jq

require_env BASE_RPC_URL
require_env PRIVATE_KEY
require_env KEEPER

CHAIN_ID="${CHAIN_ID:-8453}"
DISABLE_DEFAULT_EXECUTOR="${DISABLE_DEFAULT_EXECUTOR:-true}"
DISABLE_ATOMIC_EXECUTOR="${DISABLE_ATOMIC_EXECUTOR:-true}"

MATCHING_DEPLOYMENT_FILE="${MATCHING_DEPLOYMENT_FILE:-deployments/${CHAIN_ID}/matching.json}"
CORE_DEPLOYMENT_FILE="${CORE_DEPLOYMENT_FILE:-../../exchange-core/deployments/${CHAIN_ID}/core.json}"

if [[ ! -f "$MATCHING_DEPLOYMENT_FILE" ]]; then
  echo "Missing matching deployment file: $MATCHING_DEPLOYMENT_FILE" >&2
  exit 1
fi

if [[ ! -f "$CORE_DEPLOYMENT_FILE" ]]; then
  echo "Missing core deployment file: $CORE_DEPLOYMENT_FILE" >&2
  exit 1
fi

MATCHING="$(jq -r '.matching' "$MATCHING_DEPLOYMENT_FILE")"
RFQ="$(jq -r '.rfq' "$MATCHING_DEPLOYMENT_FILE")"
DEPOSIT="$(jq -r '.deposit' "$MATCHING_DEPLOYMENT_FILE")"
WITHDRAWAL="$(jq -r '.withdrawal' "$MATCHING_DEPLOYMENT_FILE")"
LIQUIDATE="$(jq -r '.liquidate' "$MATCHING_DEPLOYMENT_FILE")"
TRADE="$(jq -r '.trade' "$MATCHING_DEPLOYMENT_FILE")"
TRANSFER="$(jq -r '.transfer' "$MATCHING_DEPLOYMENT_FILE")"
ATOMIC="$(jq -r '.atomicSigningExecutor' "$MATCHING_DEPLOYMENT_FILE")"
SECURITY_MODULE="$(jq -r '.securityModule' "$CORE_DEPLOYMENT_FILE")"

if [[ "${FEE_RECIPIENT_ACCOUNT_ID:-}" == "" ]]; then
  FEE_RECIPIENT_ACCOUNT_ID="$(cast call "$SECURITY_MODULE" "accountId()(uint256)" --rpc-url "$BASE_RPC_URL")"
fi

DEFAULT_EXECUTOR="0xf00A105BC009eA3a250024cbe1DCd0509c71C52b"

echo "Applying RFQ-first policy on chain $CHAIN_ID"
echo "Matching: $MATCHING"
echo "RFQ: $RFQ"
echo "Keeper: $KEEPER"
echo "Fee recipient accountId: $FEE_RECIPIENT_ACCOUNT_ID"

# Keep only RFQ + onboarding and risk-safety modules enabled.
set_allowed_module "$RFQ" true
set_allowed_module "$DEPOSIT" true
set_allowed_module "$WITHDRAWAL" true
set_allowed_module "$LIQUIDATE" true
set_allowed_module "$TRADE" false
set_allowed_module "$TRANSFER" false

# Restrict executors to your configured keeper set.
set_trade_executor "$KEEPER" true
if [[ "$DISABLE_DEFAULT_EXECUTOR" == "true" ]]; then
  set_trade_executor "$DEFAULT_EXECUTOR" false
fi
if [[ "$DISABLE_ATOMIC_EXECUTOR" == "true" ]]; then
  set_trade_executor "$ATOMIC" false
fi

set_fee_recipient "$FEE_RECIPIENT_ACCOUNT_ID"

echo
echo "Verification:"
echo "allowed rfq       $(cast call "$MATCHING" "allowedModules(address)(bool)" "$RFQ" --rpc-url "$BASE_RPC_URL")"
echo "allowed deposit   $(cast call "$MATCHING" "allowedModules(address)(bool)" "$DEPOSIT" --rpc-url "$BASE_RPC_URL")"
echo "allowed withdrawal$(cast call "$MATCHING" "allowedModules(address)(bool)" "$WITHDRAWAL" --rpc-url "$BASE_RPC_URL")"
echo "allowed liquidate $(cast call "$MATCHING" "allowedModules(address)(bool)" "$LIQUIDATE" --rpc-url "$BASE_RPC_URL")"
echo "allowed trade     $(cast call "$MATCHING" "allowedModules(address)(bool)" "$TRADE" --rpc-url "$BASE_RPC_URL")"
echo "allowed transfer  $(cast call "$MATCHING" "allowedModules(address)(bool)" "$TRANSFER" --rpc-url "$BASE_RPC_URL")"
echo "executor keeper   $(cast call "$MATCHING" "tradeExecutors(address)(bool)" "$KEEPER" --rpc-url "$BASE_RPC_URL")"
echo "executor default  $(cast call "$MATCHING" "tradeExecutors(address)(bool)" "$DEFAULT_EXECUTOR" --rpc-url "$BASE_RPC_URL")"
echo "executor atomic   $(cast call "$MATCHING" "tradeExecutors(address)(bool)" "$ATOMIC" --rpc-url "$BASE_RPC_URL")"
echo "rfq feeRecipient  $(cast call "$RFQ" "feeRecipient()(uint256)" --rpc-url "$BASE_RPC_URL")"

echo
echo "RFQ setup complete."
