#!/usr/bin/env bash
# Checks the out-of-band secrets exist and are the right ones, before a cutover.
#
# Terraform cannot do this itself: it references the executor key by a constructed
# ARN precisely so it never reads the value, which means a missing or wrong key
# would otherwise surface only when ECS fails to start the task.
#
# Nothing here prints secret material — only the derived address, which is public.
set -euo pipefail

PROFILE="${PROFILE:-numo}"
REGION="${REGION:-us-east-1}"
MM_ADDRESS="${MM_ADDRESS:-0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B}"
MATCHING="${MATCHING:-0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191}"

fail=0
note() { printf '%-8s %s\n' "$1" "$2"; }

for name in /numo/exchange/executor_private_key /numo/exchange/rpc_url \
            /numo/exchange/mm_private_key /numo/exchange/mm_rpc_url; do
  if aws ssm get-parameter --profile "$PROFILE" --region "$REGION" --name "$name" >/dev/null 2>&1; then
    note "ok" "$name exists"
  else
    note "MISSING" "$name"; fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  rpc=$(aws ssm get-parameter --profile "$PROFILE" --region "$REGION" \
        --name /numo/exchange/rpc_url --with-decryption --query Parameter.Value --output text)
  addr=$(cast wallet address "$(aws ssm get-parameter --profile "$PROFILE" --region "$REGION" \
        --name /numo/exchange/executor_private_key --with-decryption --query Parameter.Value --output text)")

  note "info" "executor key derives to $addr"

  # The signer only matters if the chain agrees it may settle trades.
  if [ "$(cast call "$MATCHING" 'tradeExecutors(address)(bool)' "$addr" --rpc-url "$rpc")" = "true" ]; then
    note "ok" "$addr is an authorized tradeExecutor"
  else
    note "FAIL" "$addr is NOT an authorized tradeExecutor — settlement would revert"; fail=1
  fi

  # A key that cannot pay for gas fails the same way a missing key does, just later.
  bal=$(cast balance "$addr" --rpc-url "$rpc" --ether)
  if [ "$(echo "$bal < 0.005" | bc -l)" = "1" ]; then
    note "WARN" "gas balance is $bal ETH — top up before unpause"
  else
    note "ok" "gas balance $bal ETH"
  fi

  # The market maker signs as itself, not through the executor, so its key is checked
  # against the address the task definition advertises rather than against the chain.
  mm=$(cast wallet address "$(aws ssm get-parameter --profile "$PROFILE" --region "$REGION" \
       --name /numo/exchange/mm_private_key --with-decryption --query Parameter.Value --output text)")
  if [ "$(echo "$mm" | tr 'A-Z' 'a-z')" = "$(echo "$MM_ADDRESS" | tr 'A-Z' 'a-z')" ]; then
    note "ok" "market-maker key derives to $mm"
  else
    note "FAIL" "market-maker key derives to $mm, expected $MM_ADDRESS"; fail=1
  fi
fi

exit "$fail"
