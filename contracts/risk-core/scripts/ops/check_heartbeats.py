#!/usr/bin/env python3
"""Daily: is every monitor's dead-man's switch actually armed?

A healthchecks.io check pages when its pings stop -- but only once it has been pinged. A check that
has never received a ping sits in "new" forever and never alerts, and a "paused" one never alerts
either. That is exactly the shape of the failure this exists for: `rebalance check` was never
scheduled anywhere, so a heartbeat for it would have stayed "new" and silent.

So once a day this reads every check in the project and reports:
  - any check whose status is "new" or "paused" -- its switch is not armed;
  - any expected monitor (HEARTBEAT_EXPECTED) with no check of that name at all.

"down" and "grace" are not reported here: healthchecks.io already pages for those.

A finding posts to ALERT_WEBHOOK_URL and exits 1, which run-with-heartbeat.sh turns into a failed
ping on this job's own check -- so an unarmed switch reaches the pager too, not only Slack.

Env:
  HEALTHCHECKS_API_KEY  read-only API key for the project (SSM /numo/pager/healthchecks_api_key)
  HEARTBEAT_EXPECTED    comma-separated check names that must exist (they match the names under
                        SSM /numo/pager/heartbeats/)
  ALERT_WEBHOOK_URL     Slack/Discord-compatible webhook (optional; prints only if unset)
  HEALTHCHECKS_API      default https://healthchecks.io/api/v3
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request

UNARMED = ("new", "paused")


def findings(checks: list[dict], expected: list[str]) -> list[str]:
  out = []
  names = {c.get("name", "") for c in checks}
  for name in expected:
    if name not in names:
      out.append(f"no healthchecks.io check named '{name}' -- that monitor has no dead-man's switch at all")
  for c in checks:
    if c.get("status") in UNARMED:
      why = "has never been pinged" if c["status"] == "new" else "is paused"
      out.append(f"check '{c.get('name', '?')}' {why} -- it will never page, whatever happens to its monitor")
  return out


def fetch_checks(api: str, key: str) -> list[dict]:
  req = urllib.request.Request(f"{api.rstrip('/')}/checks/", headers={"X-Api-Key": key, "User-Agent": "numo-heartbeats/1"})
  with urllib.request.urlopen(req, timeout=20) as resp:
    return json.loads(resp.read())["checks"]


def post(webhook: str | None, msg: str) -> None:
  print(msg, file=sys.stderr)
  if not webhook:
    return
  body = json.dumps({"text": msg, "content": msg}).encode()
  req = urllib.request.Request(webhook, data=body, headers={"Content-Type": "application/json"})
  urllib.request.urlopen(req, timeout=15).read()


def self_test() -> None:
  checks = [
    {"name": "settlement-canary", "status": "up"},
    {"name": "rebalance-check", "status": "new"},
    {"name": "feed-alert", "status": "paused"},
    {"name": "signer-balance-alert", "status": "down"},
  ]
  got = findings(checks, ["settlement-canary", "rebalance-check", "feed-alert", "signer-balance-alert", "heartbeats"])
  assert any("'heartbeats'" in f and "no healthchecks.io check" in f for f in got), got
  assert any("'rebalance-check' has never been pinged" in f for f in got), got
  assert any("'feed-alert' is paused" in f for f in got), got
  assert not any("signer-balance-alert" in f for f in got), "down is healthchecks.io's to page, not this job's"
  assert not any("settlement-canary" in f for f in got), got
  assert findings([{"name": "a", "status": "up"}], ["a"]) == []


def main() -> int:
  if "--self-test" in sys.argv:
    self_test()
    print("self-test ok")
    return 0
  key = os.environ.get("HEALTHCHECKS_API_KEY", "").strip()
  if not key:
    print("HEALTHCHECKS_API_KEY is not set; nothing can be checked", file=sys.stderr)
    return 2
  expected = [n.strip() for n in os.environ.get("HEARTBEAT_EXPECTED", "").split(",") if n.strip()]
  checks = fetch_checks(os.environ.get("HEALTHCHECKS_API", "https://healthchecks.io/api/v3"), key)
  found = findings(checks, expected)
  prefix = "[TEST] " if "--test" in sys.argv else ""
  if found:
    post(os.environ.get("ALERT_WEBHOOK_URL"),
         f"{prefix}NUMO HEARTBEATS NOT ARMED\nThese monitors would fail silently:\n" + "\n".join(f"  - {f}" for f in found))
    return 1
  print(f"ok: {len(checks)} checks, all armed: " + ", ".join(f"{c['name']}={c['status']}" for c in checks))
  return 0


if __name__ == "__main__":
  sys.exit(main())
