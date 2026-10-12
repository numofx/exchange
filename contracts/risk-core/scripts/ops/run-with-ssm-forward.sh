#!/usr/bin/env bash
# Secrets for the cNGN future's forward publisher (services/perp-feeds, dist/forward-main.js), from
# SSM via the instance role, then exec the command.
#
# Under /numo/feeds, which the ops box may already read, rather than a new path: a new path means
# editing ops_box_ssm_paths (infra/aws/ops-box.tf), which also feeds an import block and the
# deny-outside-paths policy.
#
#   rpc_url              the same RPC the perp publishers use
#   forward_relayer_key  a relayer of its OWN: sharing perp-feeds' relayer across two processes races
#                        for nonces (the 2026-10-03 mark outage was one process doing that with itself)
#   alert_webhook_url    optional
#
# The forward SIGNER is not here: it is a KMS key, FORWARD_SIGNER_KMS_KEY_ID in the env file, signed
# with through the instance role's kms:Sign grant. Its private key never reaches the box.
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
export RELAYER_KEY="$(get forward_relayer_key)"
export ALERT_WEBHOOK_URL="$(get_optional alert_webhook_url)"

exec "$@"
