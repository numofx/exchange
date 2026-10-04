#!/usr/bin/env bash
# Runs the spot market-maker migration (scripts/local-venue/migrate-spot-mm.ts) on the ops box with the
# MM's key read from SSM into the process environment, never onto disk. The box role is granted that
# one parameter by infra/aws/ops-box.tf (ops_box_mm_key_read), to be removed after the migration.
#
# Usage, from the exchange checkout on the box:
#   contracts/risk-core/scripts/ops/run-with-ssm-mm.sh status
#   contracts/risk-core/scripts/ops/run-with-ssm-mm.sh cancel --execute
#   contracts/risk-core/scripts/ops/run-with-ssm-mm.sh withdraw --execute
#   contracts/risk-core/scripts/ops/run-with-ssm-mm.sh deposit --execute
set -euo pipefail
REGION="${AWS_REGION:-us-east-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
get() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION"
}
export MM_OWNER_PRIVATE_KEY="$(get /numo/exchange/mm_private_key)"
export RPC_URL="${RPC_URL:-$(get /numo/feeds/rpc_url)}"
export MARKETS_URL="${MARKETS_URL:-https://api.numofx.com}"
# The box runs the bundle built off-box (ops/migrate-spot-mm-dist, scripts/local-venue/dist/migrate-spot-mm.mjs):
# it installs and compiles nothing. A checkout with the workspace installed runs the source instead.
BUNDLE="$ROOT/scripts/local-venue/dist/migrate-spot-mm.mjs"
if [ -f "$BUNDLE" ]; then
  exec node "$BUNDLE" "$@"
fi
exec pnpm --dir "$ROOT/scripts/local-venue" exec tsx "$ROOT/scripts/local-venue/migrate-spot-mm.ts" "$@"
