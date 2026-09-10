#!/usr/bin/env bash
# Run exactly what CI runs, in the same order, so a green run here means a green run there.
#
# This exists because it did not. Local checking was an ad-hoc sequence of `forge test`,
# `npm test` and `go test` — every one of which passed while CI was red on `forge fmt --check`
# for three commits. "Green" meant two different things depending on who you asked.
#
# The rule for this file: it mirrors .github/workflows/*.yml and nothing else. If you add a
# step to CI, add it here. If you add one here, add it to CI. A check that runs in only one
# place recreates the problem this script was written to remove.
#
#   ./scripts/verify.sh              # everything
#   ./scripts/verify.sh risk-core    # one section: risk-core | execution | markets | node | abis
#
# BASE_RPC_URL is required. CI supplies it from secrets, and the fork suites fail in setUp
# without it — which is the same divergence in the other direction.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
ONLY="${1:-all}"
FAILED=()

if [ -z "${BASE_RPC_URL:-}" ]; then
  echo "BASE_RPC_URL is not set." >&2
  echo "  The fork suites fail in setUp without it, so a run without it is not the run CI does." >&2
  echo "  export BASE_RPC_URL=<base mainnet rpc>" >&2
  exit 2
fi

step() {                       # step <section> <dir> <description> <command...>
  local section="$1" dir="$2" desc="$3"; shift 3
  [ "$ONLY" = "all" ] || [ "$ONLY" = "$section" ] || return 0
  printf '\n\033[1m==> [%s] %s\033[0m\n' "$section" "$desc"
  if ( cd "$ROOT/$dir" && "$@" ); then
    printf '    \033[32mok\033[0m\n'
  else
    printf '    \033[31mFAILED\033[0m\n'
    FAILED+=("[$section] $desc")
  fi
}

# ---- contracts-risk-core.yml -----------------------------------------------------------
step risk-core contracts/risk-core "forge fmt --check" forge fmt --check
step risk-core contracts/risk-core "forge build scripts/*.s.sol" bash -c 'forge build scripts/*.s.sol'
step risk-core contracts/risk-core "resolve_cngn_action6 self-test" python3 scripts/ops/resolve_cngn_action6.py --self-test
step risk-core contracts/risk-core "propose_cngn_spot_batch self-test" python3 scripts/ops/propose_cngn_spot_batch.py --self-test
step risk-core contracts/risk-core "propose_market1_inert_batch self-test" python3 scripts/ops/propose_market1_inert_batch.py --self-test
step risk-core contracts/risk-core "check_settlement_canary self-test" python3 scripts/ops/check_settlement_canary.py --self-test
step risk-core contracts/risk-core "refresh_deployment_artifacts self-test" python3 scripts/ops/refresh_deployment_artifacts.py --self-test
step risk-core contracts/risk-core "forge test" forge test

# ---- contracts-execution.yml -----------------------------------------------------------
step execution contracts/execution "forge fmt --check" forge fmt --check
step execution contracts/execution "forge build scripts/*.s.sol" bash -c 'forge build scripts/*.s.sol'
step execution contracts/execution "forge test" forge test

# ---- services-markets.yml --------------------------------------------------------------
step markets services/markets "go build ./..." go build ./...
step markets services/markets "go vet ./..." go vet ./...
step markets services/markets "go test ./..." go test ./...

# ---- services-execution.yml ------------------------------------------------------------
step node . "pnpm install --frozen-lockfile" pnpm install --frozen-lockfile
step node . "build @numo/abis" pnpm --filter @numo/abis build
step node . "matching-executor check" pnpm --filter matching-executor run check
step node . "matching-executor build" pnpm --filter matching-executor run build
step node . "matching-executor test" pnpm --filter matching-executor test

# ---- abis-drift.yml --------------------------------------------------------------------
# Regenerates in place and fails if the committed files move. Restores them either way, so a
# local run never leaves the tree dirty the way the CI runner can afford to.
abis_drift() {
  ( cd "$ROOT/contracts/execution" && forge build ) >/dev/null || return 1
  node "$ROOT/packages/abis/scripts/generate.mjs" >/dev/null || return 1
  if [ -n "$(git -C "$ROOT" status --porcelain packages/abis/src/generated)" ]; then
    echo "packages/abis is stale — run 'pnpm abis:generate' and commit:" >&2
    git -C "$ROOT" --no-pager diff packages/abis/src/generated >&2
    git -C "$ROOT" checkout -- packages/abis/src/generated
    return 1
  fi
  return 0
}
step abis . "abis drift" abis_drift

# ----------------------------------------------------------------------------------------
printf '\n'
if [ ${#FAILED[@]} -eq 0 ]; then
  printf '\033[32mall checks passed\033[0m — this is what CI runs\n'
  exit 0
fi
printf '\033[31m%d check(s) failed:\033[0m\n' "${#FAILED[@]}"
printf '  %s\n' "${FAILED[@]}"
exit 1
