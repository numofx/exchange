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
#                        for nonces (the 2026-10-03 mark outage was one process doing that with itself).
#                        A second keeper (a v2 series, numo-future-feeds-v2@.service) names its own in
#                        FORWARD_RELAYER_SSM_NAME, from its env file; unset, it is forward_relayer_key.
#   alert_webhook_url    optional
#
# A v3 series (FUTURE_VERSION=v3 in its env file) also posts Data Streams reports, with the subscription's
# credentials from /numo/data-streams (username, hmac_secret): that path, not /numo/feeds, because it is the
# subscription's own (infra/aws/secrets.tf). The ops box reads it through ops_box_ssm_paths.
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
export RELAYER_KEY="$(get "${FORWARD_RELAYER_SSM_NAME:-forward_relayer_key}")"
export ALERT_WEBHOOK_URL="$(get_optional alert_webhook_url)"
if [ "${FUTURE_VERSION:-}" = "v3" ]; then
  streams() {
    aws ssm get-parameter --name "/numo/data-streams/$1" --with-decryption \
      --query Parameter.Value --output text --region "$REGION"
  }
  export DATA_STREAMS_USERNAME="$(streams username)"
  export DATA_STREAMS_SECRET="$(streams hmac_secret)"
fi

exec "$@"
