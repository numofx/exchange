#!/usr/bin/env bash
# Load mark-keeper secrets from SSM Parameter Store (via the EC2 instance IAM role) into
# the process environment, then exec the given command. Keeps the MPCVault token off disk.
#
# Usage: run-with-ssm-mark.sh <command> [args...]
#   e.g. run-with-ssm-mark.sh /usr/bin/python3 scripts/mark_keeper.py
#
# SSM params (prefix /numo/mark-keeper, SecureString):
#   mpcvault_token   MPCVault API token (x-mtoken)
#   mpcvault_vault   vault uuid
#   vault_address    the vault EOA that owns the future (tx `from`)
#   callback_secret  (optional) shared secret the callback expects
#   rpc_url          (optional) falls back to /numo/feeds/rpc_url
#   alert_webhook_url(optional) falls back to /numo/feeds/alert_webhook_url
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PREFIX="${NUMO_SSM_PREFIX:-/numo/mark-keeper}"
FEEDS="/numo/feeds"

get() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION"
}
get_opt() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION" 2>/dev/null || true
}

export MPCVAULT_TOKEN="$(get "$PREFIX/mpcvault_token")"
export MPCVAULT_VAULT="$(get "$PREFIX/mpcvault_vault")"
export VAULT_ADDRESS="$(get "$PREFIX/vault_address")"
export CALLBACK_SECRET="$(get_opt "$PREFIX/callback_secret")"

export RPC_URL="$(get_opt "$PREFIX/rpc_url")"
[ -n "${RPC_URL:-}" ] || export RPC_URL="$(get "$FEEDS/rpc_url")"
export ALERT_WEBHOOK_URL="$(get_opt "$PREFIX/alert_webhook_url")"
[ -n "${ALERT_WEBHOOK_URL:-}" ] || export ALERT_WEBHOOK_URL="$(get_opt "$FEEDS/alert_webhook_url")"

exec "$@"
