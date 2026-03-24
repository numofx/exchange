#!/usr/bin/env bash
set -euo pipefail

# Canonical pre-launch smoke gate for deliverable FX futures.
# Keep this path stable and do not change it unless a new bug appears.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKETS_SERVICE_ROOT="${MARKETS_SERVICE_ROOT:-$(cd "$ROOT/../markets-service" && pwd)}"

echo "[1/2] risk-core deliverable future smoke suite"
(
  cd "$ROOT"
  forge test --match-path test/risk-managers/unit-tests/StandardManager/TestStandardManager_DeliverableFuture.t.sol
)

echo "[2/2] markets-service listing smoke suite"
(
  cd "$MARKETS_SERVICE_ROOT"
  GOCACHE="${GOCACHE:-/tmp/markets-service-gocache}" go test ./internal/instruments ./internal/api
)

echo "smoke suite passed"
