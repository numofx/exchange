#!/usr/bin/env bash
# Assert the book is drained, and optionally drain it.
#
# The cutover runbook says "cancel the resting book. Do not rely on expiry." That was an action
# with no way to confirm it worked, and one order state cannot be drained by the documented means
# at all:
#
#   - CancelByOwnerNonce filters `status = 'active'`, so an order in 'matching' is uncancellable.
#   - The book skips 'matching' rows and expireOrders skips them, so they are invisible.
#   - ReleaseStaleMatches returns them to 'active', but runs only at matcher startup.
#
# So an order stranded in 'matching' survives a drain, and comes back as an ACTIVE order signed
# against the OLD trade module after the cutover redeploy — into a book that has moved on. That is
# the one row that turns a clean cutover into a stuck pair.
#
#   ./assert_book_drained.sh           # assert only; exit 1 if anything is open
#   ./assert_book_drained.sh --drain   # cancel everything open, then assert
#
# --drain cancels 'matching' rows as well as 'active' ones. That is safe ONLY with the matcher
# stopped: 'matching' is written on the matcher's own crossing path, and cancelling a row it is
# mid-flight on would cancel an order that is about to settle. The script refuses unless
# MATCHER_STOPPED=yes is set, because "I stopped it" is exactly the step that gets skipped.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  source .env
fi
: "${DATABASE_URL:?DATABASE_URL is required}"

DRAIN=no
[[ "${1:-}" == "--drain" ]] && DRAIN=yes

open_counts() {
  psql "$DATABASE_URL" -At -F' ' -v ON_ERROR_STOP=1 -c \
    "select status, count(*) from active_orders where status in ('active','matching') group by status order by status"
}

total_open() {
  psql "$DATABASE_URL" -At -v ON_ERROR_STOP=1 -c \
    "select count(*) from active_orders where status in ('active','matching')"
}

echo "open orders by status:"
open_counts | sed 's/^/  /' || true
BEFORE="$(total_open)"
echo "  total open: $BEFORE"

if [[ "$DRAIN" == "yes" ]]; then
  if [[ "${MATCHER_STOPPED:-no}" != "yes" ]]; then
    echo >&2
    echo "REFUSING to drain: set MATCHER_STOPPED=yes once the matcher is actually at 0 replicas." >&2
    echo "  'matching' is written on the matcher's crossing path. Cancelling a row it is mid-flight" >&2
    echo "  on would cancel an order that is about to settle on chain." >&2
    exit 2
  fi
  echo "draining (matcher confirmed stopped)..."
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -c \
    "update active_orders
        set status = 'cancelled',
            cancelled_at = now(),
            cancel_reason = 'cutover drain',
            cancelled_by = 'assert_book_drained.sh'
      where status in ('active','matching')" | sed 's/^/  /'
fi

AFTER="$(total_open)"
echo
if [[ "$AFTER" == "0" ]]; then
  echo "BOOK DRAINED — 0 orders in 'active' or 'matching'."
  exit 0
fi

echo "BOOK NOT DRAINED — $AFTER order(s) still open." >&2
echo "  Do not run the cutover. Re-run with --drain (matcher stopped) or investigate:" >&2
psql "$DATABASE_URL" -At -F' | ' -v ON_ERROR_STOP=1 -c \
  "select order_id, status, owner_address, nonce from active_orders
    where status in ('active','matching') order by status, order_id limit 20" 2>/dev/null | sed 's/^/    /' >&2
exit 1
