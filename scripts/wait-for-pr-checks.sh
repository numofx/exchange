#!/usr/bin/env bash
# Wait until a PR's checks have finished, and succeed only if they passed.
#
#   ./scripts/wait-for-pr-checks.sh <pr> [timeout-seconds]   # then merge only on exit 0
#
# "No checks reported" is not "done". Right after a push, GitHub has not registered the workflows yet, and a loop that
# treats an empty list as finished merges with nothing having run -- which is how #155 merged before its terraform
# check existed (2026-10-09). So:
#
#   exit 0  at least one check is registered, none is pending, and every one passed (or was skipped) -- on two
#           polls in a row with the same set of checks, since workflows register one by one and a fast check can
#           pass before a slow one has appeared
#   exit 1  a check failed or was cancelled
#   exit 2  timed out -- still pending, or nothing ever registered
set -euo pipefail

PR="${1:?usage: wait-for-pr-checks.sh <pr> [timeout-seconds]}"
TIMEOUT="${2:-1800}"
POLL="${POLL:-15}"
deadline=$(( $(date +%s) + TIMEOUT ))
settled=""

while :; do
  checks="$(gh pr checks "$PR" --json name,bucket 2>/dev/null || true)"
  verdict="$(printf '%s' "${checks:-[]}" | python3 -c '
import json, sys
try:
    checks = json.load(sys.stdin)
except ValueError:
    checks = []
buckets = [c.get("bucket") for c in checks]
if not buckets:
    print("none")
elif any(b in ("fail", "cancel") for b in buckets):
    print("failed " + ", ".join(c["name"] for c in checks if c.get("bucket") in ("fail", "cancel")))
elif any(b == "pending" for b in buckets):
    print("pending")
else:
    print("passed " + ",".join(sorted(c["name"] for c in checks)))
')"
  case "$verdict" in
    passed*)
      if [ "$settled" = "$verdict" ]; then echo "PR #$PR: passed: ${verdict#passed }"; exit 0; fi
      settled="$verdict" ;;
    *) settled="" ;;
  esac
  case "$verdict" in failed*) echo "PR #$PR: failed: ${verdict#failed }" >&2; exit 1 ;; esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "PR #$PR: timed out after ${TIMEOUT}s (${verdict}: $( [ "$verdict" = none ] && echo 'no checks ever registered' || echo 'still pending'))" >&2
    exit 2
  fi
  sleep "$POLL"
done
