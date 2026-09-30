#!/usr/bin/env bash
# The perp pager's secrets from SSM, and nothing else: it reads the chain and posts to a pager, so it
# gets no signing key (unlike run-with-ssm.sh, which exports the feed signer's). Optional values are
# left empty rather than failing, so a missing pager is reported by the pager itself, loudly.
#
# Usage: run-with-ssm-pager.sh /usr/bin/python3 scripts/ops/check_perp_pager.py
#
# SSM (SecureString): /numo/feeds/rpc_url, /numo/feeds/alert_webhook_url, and under /numo/pager:
#   provider                pushover | pagerduty
#   pushover_token          pushover_user        (provider=pushover)
#   pagerduty_routing_key                         (provider=pagerduty)
#   heartbeat_url           optional dead-man's switch (healthchecks.io or similar)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

get() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION"
}
get_optional() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION" 2>/dev/null || true
}

export RPC_URL="$(get /numo/feeds/rpc_url)"
export ALERT_WEBHOOK_URL="$(get_optional /numo/feeds/alert_webhook_url)"
export PAGER_PROVIDER="$(get_optional /numo/pager/provider)"
export PUSHOVER_TOKEN="$(get_optional /numo/pager/pushover_token)"
export PUSHOVER_USER="$(get_optional /numo/pager/pushover_user)"
export PAGERDUTY_ROUTING_KEY="$(get_optional /numo/pager/pagerduty_routing_key)"
export PAGER_HEARTBEAT_URL="$(get_optional /numo/pager/heartbeat_url)"

exec "$@"
