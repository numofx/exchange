#!/usr/bin/env bash
# The OnchainBook maker's key and RPC from SSM, into its environment only: never written to disk.
#
# Usage: run-with-ssm-book-maker.sh /home/ec2-user/market-maker-book/book-maker
#
# SSM (SecureString): /numo/exchange/mm_private_key (the MM wallet 0x3448…B47B, owner of account #56),
# /numo/exchange/mm_rpc_url (the makers' RPC).
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"

get() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text --region "$REGION"
}

MM_OWNER_PRIVATE_KEY="$(get /numo/exchange/mm_private_key)"; export MM_OWNER_PRIVATE_KEY
MM_RPC_URL="$(get /numo/exchange/mm_rpc_url)"; export MM_RPC_URL

exec "$@"
