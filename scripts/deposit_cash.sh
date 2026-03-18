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
: "${AMOUNT_USDC:?AMOUNT_USDC is required}"

USDC_ADDRESS="${USDC_ADDRESS:-0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913}"
CASH_ADDRESS="${CASH_ADDRESS:-0xd267719409e0b3b9c6653C01c9411748915ab43b}"

RAW_AMOUNT="$(python3 - <<'PY'
from decimal import Decimal, ROUND_DOWN
import os
amount = Decimal(os.environ["AMOUNT_USDC"])
raw = int((amount * Decimal(10**6)).to_integral_value(rounding=ROUND_DOWN))
print(raw)
PY
)"

echo "rpc_url=$RPC_URL"
echo "sender=$(cast wallet address --private-key "$PRIVATE_KEY")"
echo "usdc=$USDC_ADDRESS"
echo "cash=$CASH_ADDRESS"
echo "account_id=$ACCOUNT_ID"
echo "amount_usdc=$AMOUNT_USDC"
echo "raw_amount=$RAW_AMOUNT"
echo "action=approve"

cast send \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  "$USDC_ADDRESS" \
  "approve(address,uint256)" \
  "$CASH_ADDRESS" \
  "$RAW_AMOUNT"

echo "action=deposit"

cast send \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  "$CASH_ADDRESS" \
  "deposit(uint256,uint256)" \
  "$ACCOUNT_ID" \
  "$RAW_AMOUNT"
