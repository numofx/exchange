#!/usr/bin/env bash
# Fetch feed secrets from SSM Parameter Store (via the EC2 instance IAM role)
# into the process environment, then exec the given command. Keeps the
# feed-signer/relayer keys off the instance disk entirely.
#
# Usage: run-with-ssm.sh <command> [args...]
#   e.g. run-with-ssm.sh /usr/bin/python3 scripts/publish_fx_feeds.py
#
# Requires: awscli on the host and an instance role granting
#   ssm:GetParameter on /numo/feeds/* plus kms:Decrypt via ssm.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PREFIX="${NUMO_SSM_PREFIX:-/numo/feeds}"

get() {
  aws ssm get-parameter --name "$PREFIX/$1" --with-decryption \
    --query Parameter.Value --output text --region "$REGION"
}
get_optional() {
  aws ssm get-parameter --name "$PREFIX/$1" --with-decryption \
    --query Parameter.Value --output text --region "$REGION" 2>/dev/null || true
}

export RPC_URL="$(get rpc_url)"
export FEED_SIGNER_KEY="$(get feed_signer_key)"
export RELAYER_KEY="$(get relayer_key)"
export ALERT_WEBHOOK_URL="$(get_optional alert_webhook_url)"

exec "$@"
