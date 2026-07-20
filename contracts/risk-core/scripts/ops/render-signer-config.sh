#!/usr/bin/env bash
# Assemble the MPCVault client-signer config.yml from the on-host ed25519 private key and the
# vault uuid in SSM. Writes to a tmpfs path so the combined secret file isn't persisted.
# Run as ExecStartPre of numo-mark-signer.service. Schema per MPCVault client-signer docs:
#   https://docs.mpcvault.com/guides/18-how-to-enable-api/client-signer
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
KEY="${SIGNER_KEY:-$HOME/.mpcvault/client-signer-key}"          # generated on the host
OUT="${SIGNER_CONFIG:-/run/mpcvault/config.yml}"
# our callback (mark_callback.py) listens on the host; the container reaches it via host-gateway
CALLBACK_URL="${CALLBACK_URL:-http://host.docker.internal:8799/api/mpcvault/callback}"

[ -f "$KEY" ] || { echo "signer key $KEY not found" >&2; exit 1; }
VAULT_UUID="$(aws ssm get-parameter --name /numo/mark-keeper/mpcvault_vault --with-decryption \
  --query Parameter.Value --output text --region "$REGION")"

mkdir -p "$(dirname "$OUT")"
umask 077
{
  echo "http-health:"
  echo "  listening-addr: 0.0.0.0:8080"
  echo "vault-uuid: \"$VAULT_UUID\""
  echo "ssh:"
  echo "  private-key: |"
  sed 's/^/    /' "$KEY"
  echo "  password: \"\""
  echo "callback-url: \"$CALLBACK_URL\""
} > "$OUT"
echo "wrote $OUT (vault $VAULT_UUID, callback $CALLBACK_URL)"
