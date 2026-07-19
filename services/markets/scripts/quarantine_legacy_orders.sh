#!/usr/bin/env bash
set -euo pipefail

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${DATABASE_URL:?DATABASE_URL is required}"

TARGET_ASSET="${TARGET_ASSET:-${CNGN_JUN30_2026_FUTURE_ASSET_ADDRESS:-}}"
TARGET_SUB_ID="${TARGET_SUB_ID:-${CNGN_JUN30_2026_FUTURE_SUB_ID:-}}"
EXPECTED_OWNER="${EXPECTED_OWNER:-${EXPECTED_ORDER_OWNER:-}}"

if [[ -z "$TARGET_ASSET" || -z "$TARGET_SUB_ID" ]]; then
  echo "TARGET_ASSET and TARGET_SUB_ID are required (or set CNGN_JUN30_2026_FUTURE_* in .env)." >&2
  exit 1
fi

if [[ -z "$EXPECTED_OWNER" ]]; then
  echo "EXPECTED_OWNER (or EXPECTED_ORDER_OWNER) is required for quarantine filtering." >&2
  exit 1
fi

echo "target_asset=$TARGET_ASSET"
echo "target_sub_id=$TARGET_SUB_ID"
echo "expected_owner=$EXPECTED_OWNER"

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -v target_asset="$TARGET_ASSET" \
  -v target_sub_id="$TARGET_SUB_ID" \
  -v expected_owner="$EXPECTED_OWNER" <<'SQL'
with quarantined as (
  update active_orders
  set status = 'cancelled'
  where status in ('active', 'matching')
    and lower(asset_address) = lower(:'target_asset')
    and sub_id = :'target_sub_id'
    and lower(owner_address) <> lower(:'expected_owner')
  returning order_id, owner_address, status, created_at
)
select * from quarantined order by created_at;
SQL

