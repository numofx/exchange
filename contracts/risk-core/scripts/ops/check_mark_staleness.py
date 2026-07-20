#!/usr/bin/env python3
"""Mark staleness monitor for the deliverable FX future.

Alerts when the on-chain mark stops tracking spot — either the last setMarkPrice is too
old, or the mark has drifted too far from the live spot feed. This is the safety backstop
for the mark process, whether marks are set unattended (the keeper) or by hand: if marks
stop, the losing side of any open position stops being margined.

Thresholds (warn early):
  mark age          > 2700s (45m)  — keeper heartbeat is 30m; warn just past it
  |mark-spot|/spot  > 150 bps       — mark drifted from spot

Env (or ~/.numo-mark-keeper.env / ~/.numo-feeds.env):
  RPC_URL            Base RPC
  ALERT_WEBHOOK_URL  Slack/Discord-compatible webhook (optional; logs only if unset)

Run every minute via systemd timer (numo-mark-alert.timer) or cron.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from mark_keeper import artifact, get_series, get_spot, load_env_file  # noqa: E402

MARK_AGE_WARN_SEC = 45 * 60
MARK_DRIFT_WARN_BPS = 150


def alert(webhook: str | None, msg: str) -> None:
  print(msg, file=sys.stderr)
  if not webhook:
    return
  body = json.dumps({"text": msg, "content": msg}).encode()
  req = urllib.request.Request(webhook, data=body, headers={"Content-Type": "application/json"})
  try:
    urllib.request.urlopen(req, timeout=15).read()
  except Exception as exc:
    print(f"webhook delivery failed: {exc}", file=sys.stderr)


def main() -> int:
  load_env_file(Path.home() / ".numo-mark-keeper.env")
  load_env_file(Path.home() / ".numo-feeds.env")  # webhook may already live here
  rpc = os.environ.get("RPC_URL", "https://mainnet.base.org")
  webhook = os.environ.get("ALERT_WEBHOOK_URL")

  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  future, feed, sub_id = fut["future"], fut["spotFeed"], str(fut["subId"])

  problems = []
  try:
    series = get_series(rpc, future, sub_id)
    if series["settlementPriceSet"]:
      print("series settled; mark alert n/a")
      return 0
    mark = series["markPrice"]
    age = int(time.time()) - series["lastMarkTime"]
    if age > MARK_AGE_WARN_SEC:
      problems.append(f"MARK STALE: last setMarkPrice {age}s ago (warn {MARK_AGE_WARN_SEC}s), mark {mark / 1e18:.2f}")
    try:
      spot = get_spot(rpc, feed)
      drift = abs(mark - spot) * 10_000 // spot if spot else 10_000
      if drift > MARK_DRIFT_WARN_BPS:
        problems.append(f"MARK DRIFT: mark {mark / 1e18:.2f} vs spot {spot / 1e18:.2f} = {drift}bps (warn {MARK_DRIFT_WARN_BPS}bps)")
      else:
        print(f"ok: mark age {age}s, drift {drift}bps, mark {mark / 1e18:.2f} spot {spot / 1e18:.2f}")
    except Exception as exc:
      problems.append(f"SPOT READ FAILED (can't check mark drift): {exc}")
  except Exception as exc:
    problems.append(f"MARK CHECK FAILED: {exc}")

  if problems:
    alert(webhook, "NUMO MARK ALERT\n" + "\n".join(problems))
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
