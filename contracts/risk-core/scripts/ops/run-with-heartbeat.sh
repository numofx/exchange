#!/usr/bin/env bash
# Runs a monitor and reports the run to its healthchecks.io check, so a monitor that stops running
# pages exactly like one that finds something.
#
# Usage: run-with-heartbeat.sh <name> <command> [args...]
#   e.g. run-with-heartbeat.sh settlement-canary scripts/ops/run-with-ssm.sh /usr/bin/python3 ...
#
# The check URL is SSM /numo/pager/heartbeats/<name> (a https://hc-ping.com/<uuid> URL) -- under
# /numo/pager because the box's role may read only /numo/{feeds,mark-keeper,keeper,pager}/* (an
# explicit Deny in infra/aws/ops-box.tf), and these route to the same pager. After the command
# exits, this pings <url>/<exit code>: 0 marks the check up, anything else marks it down at once.
# A run that never happens sends nothing, and the check goes down when its grace period runs out
# -- the case no monitor can report about itself. healthchecks.io routes both to Pushover, the
# same integration the perp pager's dead-man's switch already uses.
#
# The command always runs. A missing URL or a failed ping is printed and turns the unit's exit
# non-zero, but never skips the check itself: a monitor without a heartbeat is worse, not better,
# than one with. check_heartbeats.py reports any check that has never been pinged.
set -uo pipefail

NAME="${1:?usage: run-with-heartbeat.sh <name> <command> [args...]}"
shift
REGION="${AWS_REGION:-us-east-1}"

URL="${HEARTBEAT_URL:-$(aws ssm get-parameter --name "/numo/pager/heartbeats/$NAME" --with-decryption \
  --query Parameter.Value --output text --region "$REGION" 2>/dev/null || true)}"

# /start lets healthchecks.io measure how long the run takes and flag one that hangs.
[ -n "$URL" ] && curl -fsS -m 10 --retry 3 -o /dev/null "$URL/start" || true

"$@"
CODE=$?

if [ -z "$URL" ]; then
  echo "heartbeat: no URL for '$NAME' (SSM /numo/pager/heartbeats/$NAME); this run reported to nobody" >&2
  exit $(( CODE != 0 ? CODE : 3 ))
fi
if ! curl -fsS -m 10 --retry 3 -o /dev/null "$URL/$CODE"; then
  echo "heartbeat: ping for '$NAME' failed; healthchecks.io will page when the grace period ends" >&2
  exit $(( CODE != 0 ? CODE : 4 ))
fi
exit "$CODE"
