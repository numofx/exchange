#!/usr/bin/env bash
# Run a deploy that replaces the matcher without paging matcher-dead for the gap it leaves.
#
# The matcher is one task replaced stop-before-start (ecs.tf; exchange #235 is the fix that lets two overlap),
# so every deploy leaves ~70s with no heartbeat, and the perp pager (check_perp_pager.py, every minute on the
# ops box) pages matcher-dead after 60s. While the deploy runs this sets /numo/pager/mute_matcher_dead_until,
# which the pager reads each run; it is deleted on ANY exit, so a deploy that fails pages at once.
#
#   ids=... ; ./with-matcher-mute.sh terraform apply main.plan
#
# The mute only stops a NEW matcher-dead page, never one already paging, and the pager ignores one set more
# than 900s ahead (MATCHER_MUTE_MAX_SEC), so a script killed mid-deploy cannot hide a dead matcher for long.
# After the command it waits for the old matcher task to be STOPPED (wait-for-rollout.sh: desired status is
# not stopped status) and for /v1/health to show a fresh heartbeat. Only then is the deploy over.
set -euo pipefail

PROFILE="${AWS_PROFILE:-numo}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="${CLUSTER:-numo-exchange}"
PARAM="${MUTE_PARAM:-/numo/pager/mute_matcher_dead_until}"
MUTE_SEC="${MUTE_SEC:-600}"
HEALTH_URL="${MATCHER_HEALTH_URL:-https://api.numofx.com/v1/health}"
FRESH_SEC="${FRESH_SEC:-30}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-300}"

[ "$#" -gt 0 ] || { echo "usage: $0 <deploy command...>   (e.g. terraform apply main.plan)" >&2; exit 2; }
[ "$MUTE_SEC" -le 900 ] || { echo "MUTE_SEC=$MUTE_SEC: the pager ignores a mute more than 900s ahead" >&2; exit 2; }

here="$(cd "$(dirname "$0")" && pwd)"
aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }
matcher_td() { aws_ ecs describe-services --cluster "$CLUSTER" --services matcher --query 'services[0].taskDefinition' --output text; }

before_td="$(matcher_td)"
old_tasks="$(AWS_PROFILE="$PROFILE" "$here/wait-for-rollout.sh" snapshot matcher | tr '\n' ' ')"

until_ts=$(( $(date +%s) + MUTE_SEC ))
aws_ ssm put-parameter --name "$PARAM" --type String --value "$until_ts" --overwrite >/dev/null
unmute() { aws_ ssm delete-parameter --name "$PARAM" >/dev/null 2>&1 || true; echo "matcher-dead unmuted"; }
trap unmute EXIT
echo "matcher-dead muted until $(date -u -r "$until_ts" +%H:%M:%SZ 2>/dev/null || date -u -d "@$until_ts" +%H:%M:%SZ) ($MUTE_SEC s)"

"$@"

if [ "$(matcher_td)" = "$before_td" ]; then
  echo "the matcher's task definition did not change: nothing replaced it, nothing to wait for"
  exit 0
fi

AWS_PROFILE="$PROFILE" "$here/wait-for-rollout.sh" wait matcher $old_tasks

deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
while :; do
  age="$(curl -fsS --max-time 10 "$HEALTH_URL" 2>/dev/null \
    | python3 -c 'import json,sys; print(float(json.load(sys.stdin)["matcher"]["age_seconds"]))' 2>/dev/null || echo none)"
  if [ "$age" != "none" ] && python3 -c "import sys; sys.exit(0 if float('$age') <= $FRESH_SEC else 1)"; then
    echo "matcher heartbeat ${age}s old: the new matcher is matching"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "NO FRESH MATCHER HEARTBEAT after ${HEALTH_TIMEOUT}s (last age: $age): unmuting, the pager will page" >&2
    exit 1
  fi
  sleep 5
done
