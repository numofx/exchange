#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${RPC_URL:?RPC_URL is required}"

SUBACCOUNTS_ADDRESS="${SUBACCOUNTS_ADDRESS:-0x5EeE710b54Fb06ab88B4Ac5EE8735778F42c16eE}"
MATCHING_ADDRESS="${MATCHING_ADDRESS:-0xe4c2a55401F73A540CA6e1C43067Aa7164f89088}"
TARGET_OWNER="${TARGET_OWNER:-}"

LAST_ACCOUNT_ID="$(cast call --rpc-url "$RPC_URL" "$SUBACCOUNTS_ADDRESS" "lastAccountId()(uint256)")"
echo "subaccounts=$SUBACCOUNTS_ADDRESS"
echo "matching=$MATCHING_ADDRESS"
echo "last_account_id=$LAST_ACCOUNT_ID"

for ((id = 1; id <= LAST_ACCOUNT_ID; id++)); do
  nft_owner="$(cast call --rpc-url "$RPC_URL" "$SUBACCOUNTS_ADDRESS" "ownerOf(uint256)(address)" "$id" 2>/dev/null || echo "ERR")"
  deposited_owner="$(cast call --rpc-url "$RPC_URL" "$MATCHING_ADDRESS" "subAccountToOwner(uint256)(address)" "$id" 2>/dev/null || echo "ERR")"

  if [[ -n "$TARGET_OWNER" ]]; then
    lower_target="$(printf '%s' "$TARGET_OWNER" | tr '[:upper:]' '[:lower:]')"
    lower_nft_owner="$(printf '%s' "$nft_owner" | tr '[:upper:]' '[:lower:]')"
    lower_deposited_owner="$(printf '%s' "$deposited_owner" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower_nft_owner" != "$lower_target" && "$lower_deposited_owner" != "$lower_target" ]]; then
      continue
    fi
  fi

  echo "id=$id nft_owner=$nft_owner deposited_owner=$deposited_owner"
done
