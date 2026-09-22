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
from mark_keeper import artifact, get_series, get_spot, load_env_file, run  # noqa: E402

MARK_AGE_WARN_SEC = 45 * 60
MARK_DRIFT_WARN_BPS = 150


def total_position(rpc: str, future: str, manager: str) -> int:
  """Open interest on the future, as the manager accounts for it."""
  out = run(["cast", "call", future, "totalPosition(address)(uint256)", manager, "--rpc-url", rpc])
  return int(out.split()[0].replace(",", ""))


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

  # Retired 2026-09-22 while open interest is zero, in the same shape as the settled-series exit
  # below: this alert exists because "if marks stop, the losing side of any open position stops
  # being margined". With no position there is no losing side and nothing to margin, so the mark
  # being stale harms no one and paging about it is noise.
  #
  # Deliberately a CONDITION, not a deletion or a disabled timer. The premise is checked on every
  # run, so the day anyone opens a position here the alert resumes by itself. A retirement that
  # needs a human to remember to undo it is how a venue ends up with an unmonitored market.
  #
  # Context: the cNGN spot feed 0x41512C6a has been stale since 2026-09-11 (its updater ran out of
  # gas) and is not being refunded. Spot trading is unaffected -- it reads the static feeds it was
  # moved to at the SRM cutover on 2026-09-10 -- and market 1 was likewise moved off its live feed
  # on 2026-09-09. Both feeds this signer wrote to are abandoned by design.
  try:
    manager = fut["manager"]
    oi = total_position(rpc, future, manager)
    if oi == 0:
      print(f"no open interest on {future} (manager {manager}); nothing to margin, mark alert n/a")
      return 0
  except Exception as exc:
    # Fail LOUD: if we cannot establish that open interest is zero, we must not assume it.
    alert(webhook, f"NUMO MARK ALERT\nOPEN INTEREST CHECK FAILED (cannot confirm the mark alert is safe to skip): {exc}")
    return 1

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
