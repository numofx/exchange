#!/usr/bin/env bash
# End-to-end check of sponsored deposits and withdrawals against the live API, from a trader's wallet.
# Each subcommand signs with the trader's own key via `cast wallet sign` and prints the API's answer; nothing
# here holds or prints a key. Run the steps in order, checking each before the next:
#
#   reject            a 9.99 USDC deposit, which must be refused (400) before anything is sent
#   open              permit + deposit 10 USDC into a new perp account (two sponsored transactions)
#   withdraw <sub>    withdraw 10 USDC of perp cash back to the wallet (one sponsored transaction)
#   approve           USDC.approve(DepositModule, 10 USDC), paid by the wallet itself
#   topup <sub>       deposit 10 USDC into the existing account, on the approval (one sponsored transaction)
#   status <hash>     GET /v1/deposits/<action_hash>
#
# Signing: SIGN_ARGS is passed to cast, e.g. SIGN_ARGS="--account jason" (a keystore from
# `cast wallet import jason --interactive`) or SIGN_ARGS="--ledger". OWNER is the wallet's address.
set -euo pipefail

: "${OWNER:?set OWNER to the wallet address}"
: "${SIGN_ARGS:?set SIGN_ARGS, e.g. --account jason}"
API="${API:-https://api.numofx.com}"
RPC="${RPC:-https://mainnet.base.org}"
CHAIN_ID=8453
MATCHING=0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191
DEPOSIT_MODULE=0x6540f8d9Eb599b045C05E45cb6a5B1730a806658
WITHDRAWAL_MODULE=0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
PERP_CASH=0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272
PERP_MANAGER=0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4
AMOUNT=10000000 # 10 USDC, the venue's minimum

# shellcheck disable=SC2086
sign() { cast wallet sign $SIGN_ARGS --data "$1"; }

# A fresh random uint64 nonce; action nonces are per owner and module and only need to be unused.
fresh_nonce() { echo $((RANDOM * 32768 * 32768 + RANDOM * 32768 + RANDOM)); }

action_json() { # subaccount nonce module data expiry
  jq -nc --arg s "$1" --arg n "$2" --arg m "$3" --arg d "$4" --arg e "$5" --arg o "$OWNER" '
    {subaccount_id:$s, nonce:$n, module:$m, data:$d, expiry:$e, owner:$o, signer:$o}'
}

sign_action() { # action_json -> signature
  local typed
  typed=$(jq -c --arg c "$MATCHING" --argjson id "$CHAIN_ID" '{
    types: {
      EIP712Domain: [{name:"name",type:"string"},{name:"version",type:"string"},
                     {name:"chainId",type:"uint256"},{name:"verifyingContract",type:"address"}],
      Action: [{name:"subaccountId",type:"uint256"},{name:"nonce",type:"uint256"},{name:"module",type:"address"},
               {name:"data",type:"bytes"},{name:"expiry",type:"uint256"},{name:"owner",type:"address"},
               {name:"signer",type:"address"}]},
    primaryType: "Action",
    domain: {name:"Matching", version:"1.0", chainId:$id, verifyingContract:$c},
    message: {subaccountId:.subaccount_id, nonce:.nonce, module:.module, data:.data,
              expiry:.expiry, owner:.owner, signer:.signer}}' <<<"$1")
  sign "$typed"
}

sign_permit() { # value deadline -> signature
  local nonce typed
  nonce=$(cast call "$USDC" 'nonces(address)(uint256)' "$OWNER" --rpc-url "$RPC" | awk '{print $1}')
  typed=$(jq -nc --arg o "$OWNER" --arg s "$DEPOSIT_MODULE" --arg v "$1" --arg n "$nonce" --arg d "$2" \
    --arg u "$USDC" --argjson id "$CHAIN_ID" '{
    types: {
      EIP712Domain: [{name:"name",type:"string"},{name:"version",type:"string"},
                     {name:"chainId",type:"uint256"},{name:"verifyingContract",type:"address"}],
      Permit: [{name:"owner",type:"address"},{name:"spender",type:"address"},{name:"value",type:"uint256"},
               {name:"nonce",type:"uint256"},{name:"deadline",type:"uint256"}]},
    primaryType: "Permit",
    domain: {name:"USD Coin", version:"2", chainId:$id, verifyingContract:$u},
    message: {owner:$o, spender:$s, value:$v, nonce:$n, deadline:$d}}')
  sign "$typed"
}

post() { # path body
  echo "POST $1" >&2
  curl -sS -w '\nHTTP %{http_code}\n' -X POST -H 'content-type: application/json' --data "$2" "$API$1"
}

deposit() { # subaccount amount with_permit
  local expiry data action sig body
  expiry=$(($(date +%s) + 600))
  data=$(cast abi-encode 'f(uint256,address,address)' "$2" "$PERP_CASH" "$PERP_MANAGER")
  action=$(action_json "$1" "$(fresh_nonce)" "$DEPOSIT_MODULE" "$data" "$expiry")
  echo "action hash (on chain): $(cast call "$MATCHING" \
    'getActionHash((uint256,uint256,address,bytes,uint256,address,address))(bytes32)' \
    "($1,$(jq -r .nonce <<<"$action"),$DEPOSIT_MODULE,$data,$expiry,$OWNER,$OWNER)" --rpc-url "$RPC")" >&2
  sig=$(sign_action "$action")
  body=$(jq -nc --argjson a "$action" --arg s "$sig" '{action:$a, signature:$s}')
  if [[ "$3" == permit ]]; then
    body=$(jq -c --arg v "$2" --arg d "$expiry" --arg s "$(sign_permit "$2" "$expiry")" \
      '. + {permit:{value:$v, deadline:$d, signature:$s}}' <<<"$body")
  fi
  post /v1/deposits "$body"
}

withdraw() { # subaccount amount
  local expiry data action sig
  expiry=$(($(date +%s) + 600))
  data=$(cast abi-encode 'f(address,uint256)' "$PERP_CASH" "$2")
  action=$(action_json "$1" "$(fresh_nonce)" "$WITHDRAWAL_MODULE" "$data" "$expiry")
  sig=$(sign_action "$action")
  post /v1/withdrawals "$(jq -nc --argjson a "$action" --arg s "$sig" '{action:$a, signature:$s}')"
}

case "${1:-}" in
  reject) deposit 0 9990000 permit ;;
  open) deposit 0 "$AMOUNT" permit ;;
  withdraw) withdraw "${2:?subaccount id}" "$AMOUNT" ;;
  approve) cast send "$USDC" 'approve(address,uint256)' "$DEPOSIT_MODULE" "$AMOUNT" $SIGN_ARGS --rpc-url "$RPC" ;;
  topup) deposit "${2:?subaccount id}" "$AMOUNT" none ;;
  status) curl -sS -w '\nHTTP %{http_code}\n' "$API/v1/deposits/${2:?action hash}" ;;
  *) sed -n '2,16p' "$0"; exit 2 ;;
esac
