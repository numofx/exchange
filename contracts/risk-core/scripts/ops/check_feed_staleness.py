#!/usr/bin/env python3
"""Feed staleness monitor for the Base deliverable FX market.

Reads each LyraSpotFeed's packed spotDetail word (slot 6: uint96 price,
uint64 confidence, uint64 timestamp) via raw JSON-RPC and alerts a webhook
when the last update is older than the warning threshold — before the
on-chain heartbeat hard-freezes the market.

Alert thresholds (warn early, well inside the heartbeat):
  cNGN spot feed:  120s  (heartbeat 180s — stale feed freezes all trading)
  stable feed:    3000s  (heartbeat 3600s)

Env (or ~/.numo-feeds.env):
  RPC_URL             Base mainnet RPC
  ALERT_WEBHOOK_URL   Slack/Discord-compatible webhook (optional; logs only if unset)

Run every minute via systemd timer (see numo-feed-alert.timer) or cron:
  * * * * * cd /path/to/risk-core && python3 scripts/ops/check_feed_staleness.py
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent.parent
SPOT_DETAIL_SLOT = "0x6"
CNGN_WARN_SEC = 120
STABLE_WARN_SEC = 3000


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip().removeprefix("export ").strip(), value.strip())


def rpc(url: str, method: str, params: list) -> str:
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(
    url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-feed-monitor/1"}
  )
  with urllib.request.urlopen(req, timeout=15) as resp:
    out = json.loads(resp.read())
  if "error" in out:
    raise RuntimeError(out["error"])
  return out["result"]


def feed_age(url: str, feed: str) -> tuple[int, float]:
  word = int(rpc(url, "eth_getStorageAt", [feed, SPOT_DETAIL_SLOT, "latest"]), 16)
  ts = (word >> 160) & 0xFFFFFFFFFFFFFFFF
  price = (word & (1 << 96) - 1) / 1e18
  return int(time.time()) - ts, price


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
  load_env_file(Path.home() / ".numo-feeds.env")
  url = os.environ.get("RPC_URL", "https://mainnet.base.org")
  webhook = os.environ.get("ALERT_WEBHOOK_URL")

  fut = json.loads((ROOT_DIR / "deployments/8453/CNGN_SEP16_2026_FUTURE.json").read_text())
  core = json.loads((ROOT_DIR / "deployments/8453/core.json").read_text())
  feeds = [
    ("cNGN spot feed", fut["spotFeed"], CNGN_WARN_SEC),
    ("stable feed", core["stableFeed"], STABLE_WARN_SEC),
  ]

  problems = []
  for name, addr, warn in feeds:
    try:
      age, price = feed_age(url, addr)
      if age > warn:
        problems.append(f"{name} {addr} STALE: last update {age}s ago (warn {warn}s), price {price:.2f}")
      else:
        print(f"ok: {name} age {age}s price {price:.2f}")
    except Exception as exc:
      problems.append(f"{name} {addr} CHECK FAILED: {exc}")

  if problems:
    alert(webhook, "NUMO FEED ALERT\n" + "\n".join(problems))
    return 1
  return 0


if __name__ == "__main__":
  sys.exit(main())
