#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${RPC_URL:?RPC_URL is required}"
: "${PRIVATE_KEY:?PRIVATE_KEY is required}"
: "${ACCOUNT_ID:?ACCOUNT_ID is required}"
: "${AMOUNT_CNGN:?AMOUNT_CNGN is required}"

# Base mainnet: cNGN token + risk-core WrappedERC20Asset that wraps it (both 6 decimals)
CNGN_ADDRESS="${CNGN_ADDRESS:-0x46C85152bFe9f96829aA94755D9f915F9B10EF5F}"
WRAPPED_CNGN_ADDRESS="${WRAPPED_CNGN_ADDRESS:-0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493}"

RAW_AMOUNT="$(python3 - <<'PY'
from decimal import Decimal, ROUND_DOWN
import os
amount = Decimal(os.environ["AMOUNT_CNGN"])
raw = int((amount * Decimal(10**6)).to_integral_value(rounding=ROUND_DOWN))
print(raw)
PY
)"

echo "rpc_url=$RPC_URL"
echo "sender=$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "cngn=$CNGN_ADDRESS"
echo "wrapped_cngn=$WRAPPED_CNGN_ADDRESS"
echo "account_id=$ACCOUNT_ID"
echo "amount_cngn=$AMOUNT_CNGN"
echo "raw_amount=$RAW_AMOUNT"
echo "action=approve"

cast send \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  "$CNGN_ADDRESS" \
  "approve(address,uint256)" \
  "$WRAPPED_CNGN_ADDRESS" \
  "$RAW_AMOUNT"

echo "action=deposit"

cast send \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  "$WRAPPED_CNGN_ADDRESS" \
  "deposit(uint256,uint256)" \
  "$ACCOUNT_ID" \
  "$RAW_AMOUNT"
