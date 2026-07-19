#!/usr/bin/env bash
set -euo pipefail

# Full-lifecycle drill for the SEP-16-2026 deliverable FX future on a local Anvil node.
# Covers: deployment, funding, exact 5x (20% IM) validation, ramp leverage blockage,
# and warp-forward atomic delivery at expiry.
#
# Usage: bash scripts/drill-5x-lifecycle.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PORT=8547
RPC="http://127.0.0.1:$PORT"
PK=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d45d95e0b46
DEPLOYER=$(cast wallet address --private-key "$PK" 2>/dev/null | tail -1)

LAST_TRADE=1789567200          # Sep 16 2026 15:00:00 WAT
EXPIRY=1789567201              # Sep 16 2026 15:00:01 WAT
SUBID=$EXPIRY
RAMP_START=$((LAST_TRADE - 3 * 86400))

IM_CASH=2000000000             # 2,000 USDC (6 dec) = exact 20% IM on one 10,000-notional contract
UNDER_CASH=1999000000          # 1,999 USDC: below IM
ONE_CONTRACT=1000000000000000000
BASE_DELIVERY_USDC=10000000000 # 10,000 USDC (6 dec) short must deliver
QUOTE_DELIVERY=15000000000000000000000000  # 15,000,000 cNGN as 18-dec subaccount balance
QUOTE_DELIVERY_TOK=15000000000000          # same amount in cNGN token units (6 dec)
PX=1500000000000000000000      # 1500e18

DEPLOY_DIR="deployments/31337"
BACKUP_DIR=""

cleanup() {
  [ -n "${ANVIL_PID:-}" ] && kill "$ANVIL_PID" 2>/dev/null || true
  rm -rf "$DEPLOY_DIR" broadcast/deploy-erc20s.s.sol/31337 broadcast/deploy-deliverable-fx-minimal.s.sol/31337 \
    cache/deploy-erc20s.s.sol/31337 cache/deploy-deliverable-fx-minimal.s.sol/31337 2>/dev/null || true
  [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] && mv "$BACKUP_DIR" "$DEPLOY_DIR"
}
trap cleanup EXIT

if [ -d "$DEPLOY_DIR" ]; then
  BACKUP_DIR="$(mktemp -d)/31337"
  mkdir -p "$(dirname "$BACKUP_DIR")"
  mv "$DEPLOY_DIR" "$BACKUP_DIR"
fi
mkdir -p "$DEPLOY_DIR"

step() { echo; echo "== $*"; }
val() { awk '{print $1}'; }  # strip cast's "[1.5e25]" annotations

assert_eq() { # actual expected label
  if [ "$1" != "$2" ]; then echo "  ✗ FAIL: $3 (got $1, want $2)"; exit 1; fi
  echo "  ✓ $3 = $1"
}

assert_neg() { # actual label
  case "$1" in -*) echo "  ✓ $2 = $1 (< 0)";; *) echo "  ✗ FAIL: $2 should be negative, got $1"; exit 1;; esac
}

expect_revert() { # label, then command...
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "  ✗ FAIL: expected revert: $label"; exit 1; fi
  echo "  ✓ reverted as expected: $label"
}

send() { cast send --rpc-url "$RPC" --private-key "$PK" "$@" >/dev/null; }
call() { cast call --rpc-url "$RPC" "$@"; }
jget() { python3 -c "import json;print(json.load(open('$1'))['$2'])"; }

step "start anvil on :$PORT"
anvil --port "$PORT" --silent &
ANVIL_PID=$!
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
cast chain-id --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$DEPLOYER" 0x21E19E0C9BAB2400000 --rpc-url "$RPC" >/dev/null
echo "  deployer $DEPLOYER funded"

step "deploy mock ERC20s (writes $DEPLOY_DIR/shared.json)"
PRIVATE_KEY=$PK forge script scripts/deploy-erc20s.s.sol --rpc-url "$RPC" --broadcast >/dev/null
USDC=$(jget "$DEPLOY_DIR/shared.json" usdc)
send "$USDC" "configureMinter(address,bool)" "$DEPLOYER" true

step "deploy mock cNGN spot feed @ 1500"
FEED=$(forge create test/shared/mocks/MockFeeds.sol:MockFeeds --rpc-url "$RPC" --private-key "$PK" --broadcast 2>/dev/null | awk '/Deployed to:/{print $3}')
send "$FEED" "setSpot(uint256,uint256)" "$PX" 1000000000000000000

step "deploy full deliverable FX stack (minimal script)"
PRIVATE_KEY=$PK CNGN_SPOT_FEED_ADDRESS=$FEED \
  forge script scripts/deploy-deliverable-fx-minimal.s.sol --tc DeployDeliverableFXMinimal \
  --rpc-url "$RPC" --broadcast >/dev/null

SUB=$(jget "$DEPLOY_DIR/core.json" subAccounts)
CASH=$(jget "$DEPLOY_DIR/core.json" cash)
FUT_JSON="$DEPLOY_DIR/CNGN_SEP16_2026_FUTURE.json"
MANAGER=$(jget "$FUT_JSON" manager)
FUTURE=$(jget "$FUT_JSON" future)
WUSDC=$(jget "$FUT_JSON" baseAsset)
WCNGN=$(jget "$FUT_JSON" quoteAsset)
CNGN=$(jget "$DEPLOY_DIR/WRAPPED_CNGN.json" wrappedAsset)
send "$CNGN" "configureMinter(address,bool)" "$DEPLOYER" true

step "verify deployed config"
MP=$(call "$MANAGER" "marginParams()(uint256,uint256)")
assert_eq "$(echo "$MP" | sed -n 1p | val)" 200000000000000000 "normalIM (20% = 5x)"
assert_eq "$(echo "$MP" | sed -n 2p | val)" 150000000000000000 "normalMM (15%)"
assert_eq "$(jget "$FUT_JSON" subId)" "$SUBID" "series subId (== expiry)"
assert_eq "$(jget "$FUT_JSON" lastTradeTime)" "$LAST_TRADE" "lastTradeTime"

step "create subaccounts (alice=short, bob=long; carol/dave=under-margin pair)"
newacc() {
  local id
  id=$(call "$SUB" "createAccount(address,address)(uint256)" "$DEPLOYER" "$MANAGER" | val)
  send "$SUB" "createAccount(address,address)" "$DEPLOYER" "$MANAGER"
  echo "$id"
}
ALICE=$(newacc); BOB=$(newacc); CAROL=$(newacc); DAVE=$(newacc)
MGR_ACC=$(call "$MANAGER" "accId()(uint256)" | val)
echo "  ✓ accounts: alice=$ALICE bob=$BOB carol=$CAROL dave=$DAVE managerAcc=$MGR_ACC"

step "fund margin: 2,000 USDC cash each side (exact 5x on 10,000 notional)"
send "$USDC" "mint(address,uint256)" "$DEPLOYER" 100000000000000
send "$USDC" "approve(address,uint256)" "$CASH" 100000000000000
send "$CASH" "deposit(uint256,uint256)" "$ALICE" "$IM_CASH"
send "$CASH" "deposit(uint256,uint256)" "$BOB" "$IM_CASH"
send "$CASH" "deposit(uint256,uint256)" "$CAROL" "$UNDER_CASH"
send "$CASH" "deposit(uint256,uint256)" "$DAVE" "$IM_CASH"

ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
transfer_future() { # from to amount
  cast send --rpc-url "$RPC" --private-key "$PK" "$SUB" \
    "submitTransfer((uint256,uint256,address,uint256,int256,bytes32),bytes)" \
    "($1,$2,$FUTURE,$SUBID,$3,$ZERO32)" "0x"
}

step "open 1 contract at exactly 5x (alice short -> bob long)"
transfer_future "$ALICE" "$BOB" "$ONE_CONTRACT" >/dev/null
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$ALICE" "$FUTURE" "$SUBID" | val)" "-$ONE_CONTRACT" "alice future position"
assert_eq "$(call "$MANAGER" "getMargin(uint256,bool)(int256)" "$ALICE" true | val)" 0 "alice IM headroom (exactly 5x)"
assert_eq "$(call "$MANAGER" "getMargin(uint256,bool)(int256)" "$BOB" true | val)" 0 "bob IM headroom (exactly 5x)"
assert_eq "$(call "$MANAGER" "getMargin(uint256,bool)(int256)" "$ALICE" false | val)" 500000000000000000000 "alice MM headroom (500)"

step "reject > 5x: carol funded 1,999 USDC cannot open"
expect_revert "open 1 contract with 1,999 USDC margin" transfer_future "$CAROL" "$DAVE" "$ONE_CONTRACT"

step "warp into margin ramp (lastTrade - 3d + 60s) and verify blockage"
cast rpc evm_setNextBlockTimestamp $((RAMP_START + 60)) --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
assert_neg "$(call "$MANAGER" "getMargin(uint256,bool)(int256)" "$ALICE" true | val)" "alice IM during ramp (requirement > 20%)"
expect_revert "exposure increase during ramp (DFXM_LeverageIncreaseBlocked)" transfer_future "$ALICE" "$BOB" 1000000000000000

step "fund deliverables before close (short: 10,000 USDC base; long: 15,000,000 cNGN quote; manager: quote float)"
send "$USDC" "approve(address,uint256)" "$WUSDC" "$BASE_DELIVERY_USDC"
send "$WUSDC" "deposit(uint256,uint256)" "$ALICE" "$BASE_DELIVERY_USDC"
send "$CNGN" "mint(address,uint256)" "$DEPLOYER" 45000000000000
send "$CNGN" "approve(address,uint256)" "$WCNGN" 45000000000000
send "$WCNGN" "deposit(uint256,uint256)" "$BOB" "$QUOTE_DELIVERY_TOK"
send "$WCNGN" "deposit(uint256,uint256)" "$MGR_ACC" "$QUOTE_DELIVERY_TOK"

step "post settlement price (1500) and warp to atomic delivery time (expiry = lastTrade + 1s)"
send "$FUTURE" "setSettlementPrice(uint96,uint256)" "$SUBID" "$PX"
cast rpc evm_setNextBlockTimestamp "$EXPIRY" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
assert_eq "$(call "$MANAGER" "canSettleDeliverableFuture(address,uint256,uint96)(bool)" "$FUTURE" "$ALICE" "$SUBID")" true "alice settleable at expiry"

step "settle: short delivers base, long delivers quote (atomic via manager float)"
send "$MANAGER" "settleDeliverableFuture(address,uint256,uint96)" "$FUTURE" "$ALICE" "$SUBID"
send "$MANAGER" "settleDeliverableFuture(address,uint256,uint96)" "$FUTURE" "$BOB" "$SUBID"

step "verify delivery outcome"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$ALICE" "$FUTURE" "$SUBID" | val)" 0 "alice future closed"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$BOB" "$FUTURE" "$SUBID" | val)" 0 "bob future closed"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$ALICE" "$WCNGN" 0 | val)" "$QUOTE_DELIVERY" "alice received 15,000,000 cNGN"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$ALICE" "$WUSDC" 0 | val)" 0 "alice delivered all base USDC"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$BOB" "$WUSDC" 0 | val)" 10000000000000000000000 "bob received 10,000 USDC"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$BOB" "$WCNGN" 0 | val)" 0 "bob delivered all quote cNGN"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$MGR_ACC" "$WCNGN" 0 | val)" "$QUOTE_DELIVERY" "manager quote float restored"
assert_eq "$(call "$SUB" "getBalance(uint256,address,uint256)(int256)" "$MGR_ACC" "$WUSDC" 0 | val)" 0 "manager holds no base"
assert_eq "$(call "$MANAGER" "accountSettled(uint256,uint96)(bool)" "$ALICE" "$SUBID")" true "alice marked settled"
assert_eq "$(call "$MANAGER" "accountSettled(uint256,uint96)(bool)" "$BOB" "$SUBID")" true "bob marked settled"

echo
echo "DRILL PASSED: deploy -> fund -> exact 5x -> ramp blockage -> atomic delivery all verified"
