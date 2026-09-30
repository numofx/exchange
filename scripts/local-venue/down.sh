#!/usr/bin/env bash
# Stops everything up.sh started. State (Postgres data, logs, venue.json) stays in $LOCAL_VENUE_DIR.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="${LOCAL_VENUE_DIR:-$(cd "$HERE/../.." && pwd)/.local-venue}"
for PIDFILE in "$DIR"/pids/*; do
  [ -f "$PIDFILE" ] || continue
  kill "$(cat "$PIDFILE")" 2>/dev/null && echo "stopped $(basename "$PIDFILE")"
  rm -f "$PIDFILE"
done
# Safety net for anything whose pid was not recorded: these flags only ever run against a local fork.
pkill -f "dist/main.js --local-fixed-price" 2>/dev/null && echo "stopped stray local feed publishers"
[ -d "$DIR/pgdata" ] && pg_ctl -D "$DIR/pgdata" stop >/dev/null 2>&1 && echo "stopped postgres"
exit 0
