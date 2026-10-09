#!/usr/bin/env bash
# Secrets for monitors that only READ the chain and report: the RPC, the alert webhook and the
# healthchecks.io API key, and nothing else. No signing key -- unlike run-with-ssm.sh, which
# exports the feed signer's and the relayer's. Same reasoning as run-with-ssm-pager.sh.
#
# Usage: run-with-ssm-readonly.sh <command> [args...]
#   e.g. run-with-ssm-readonly.sh /usr/bin/pnpm --dir services/rebalance rebalance check --alert
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

get() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION"
}
get_optional() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION" 2>/dev/null || true
}

export RPC_URL="$(get /numo/feeds/rpc_url)"
export BASE_RPC_URL="$RPC_URL"   # what services/rebalance calls it
export ALERT_WEBHOOK_URL="$(get_optional /numo/feeds/alert_webhook_url)"
export HEALTHCHECKS_API_KEY="$(get_optional /numo/pager/healthchecks_api_key)"

exec "$@"
