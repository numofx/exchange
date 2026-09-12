#!/usr/bin/env bash
# Wait for an ECS rollout to be genuinely finished, and measure only after it is.
#
# DESIRED STATUS IS NOT STOPPED STATUS. `list-tasks --desired-status RUNNING` drops a task the
# moment ECS decides to stop it, while the container keeps running -- and, for the market maker,
# keeps placing orders. A wait built on that returns early, and everything measured afterwards
# mixes two versions.
#
# It cost four wrong conclusions in one day, the last one a live book left holding six quotes from
# a draining predecessor that carried the previous configuration.
#
# Usage:
#   ids=$(./wait-for-rollout.sh snapshot market-maker-spot)   # BEFORE the apply
#   terraform apply ...
#   ./wait-for-rollout.sh wait market-maker-spot $ids         # blocks until those tasks are gone
set -euo pipefail

CLUSTER="${CLUSTER:-numo-exchange}"
REGION="${REGION:-us-east-1}"
PROFILE="${AWS_PROFILE:-numo}"
POLL="${POLL:-8}"
TIMEOUT="${TIMEOUT:-900}"

aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

snapshot() {
  aws_ ecs list-tasks --cluster "$CLUSTER" --service-name "$1" --desired-status RUNNING \
    --query 'taskArns[]' --output text | tr '\t' '\n' | sed 's#.*/##'
}

wait_for() {
  local service="$1"; shift
  local deadline=$(( $(date +%s) + TIMEOUT ))

  # 1. Every pre-existing task must reach lastStatus=STOPPED. Not "no longer desired-RUNNING":
  #    describe-tasks reports what the container is actually doing, which is the only thing that
  #    decides whether it can still write to the venue.
  for task in "$@"; do
    [ -z "$task" ] && continue
    while :; do
      local status
      status=$(aws_ ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" \
                 --query 'tasks[0].lastStatus' --output text 2>/dev/null || echo "MISSING")
      case "$status" in
        STOPPED|MISSING|None) echo "  $task: $status"; break ;;
      esac
      [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMED OUT waiting for $task (last seen $status)" >&2; exit 1; }
      sleep "$POLL"
    done
  done

  # 2. And the service itself must be down to a single completed deployment, so the replacement is
  #    the only thing serving.
  while :; do
    local n state
    n=$(aws_ ecs describe-services --cluster "$CLUSTER" --services "$service" \
          --query 'length(services[0].deployments)' --output text)
    state=$(aws_ ecs describe-services --cluster "$CLUSTER" --services "$service" \
          --query 'services[0].deployments[0].rolloutState' --output text)
    if [ "$n" = "1" ] && [ "$state" = "COMPLETED" ]; then
      echo "  $service: 1 deployment, COMPLETED"
      return 0
    fi
    [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMED OUT: $service has $n deployments, state $state" >&2; exit 1; }
    sleep "$POLL"
  done
}

case "${1:-}" in
  snapshot) shift; snapshot "$@" ;;
  wait)     shift; wait_for "$@" ;;
  *) echo "usage: $0 snapshot <service> | $0 wait <service> <task-id>..." >&2; exit 2 ;;
esac
