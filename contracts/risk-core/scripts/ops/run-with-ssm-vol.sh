#!/usr/bin/env bash
# Secrets for the cNGN options' vol publisher (services/perp-feeds, dist/vol-main.js), from SSM via the instance role,
# then exec the command. Under /numo/feeds, which the ops box already reads (see run-with-ssm-forward.sh for why not a
# new path).
#
#   rpc_url              the same RPC the other publishers use
#   VOL_RELAYER_SSM_NAME a relayer of its OWN, named in the env file (default vol_relayer_key): sharing another
#                        publisher's relayer across processes races it for nonces. Watch it in check_signer_balance.py.
#   alert_webhook_url    optional
#
# The vol SIGNER is not here: it is a KMS key, VOL_SIGNER_KMS_KEY_ID in the env file. Its private key never reaches the
# box, and it must not be the index's or the forward's key (deploy-cngn-options-v2.s.sol refuses that).
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
export RELAYER_KEY="$(get "${VOL_RELAYER_SSM_NAME:-vol_relayer_key}")"
export ALERT_WEBHOOK_URL="$(get_optional alert_webhook_url)"

exec "$@"
