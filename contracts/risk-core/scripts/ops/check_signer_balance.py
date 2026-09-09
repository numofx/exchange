#!/usr/bin/env python3
"""Feed-signer gas-balance monitor for the Base deliverable FX market.

The feed publisher signs each cNGN/stable acceptData tx from a hot EOA. If that
wallet runs out of gas the feed stops publishing and getSpot() goes stale, which
FREEZES all trading. This has now happened three times: 2026-07-21, 2026-09-01
(dead for 6.8 days, found by accident while debugging something else) and
2026-09-09. The staleness alert only fires AFTER the feed has already died; this
checks the balance and warns while there's still days of runway, so it's a
proactive top-up reminder.

Env (or ~/.numo-feeds.env):
  RPC_URL             Base mainnet RPC
  ALERT_WEBHOOK_URL   Slack/Discord-compatible webhook (optional; logs only if unset)
  SIGNER_ADDRESS      feed-signer EOA (default: the live 0xC9F1... wallet)
  BURN_ETH_PER_DAY    daily gas burn (default 0.0012 ETH, measured 2026-09-09)
  WARN_RUNWAY_DAYS    alert when runway drops below this many days (default 7)

Run every few hours via systemd timer (see numo-signer-balance-alert.timer).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

DEFAULT_SIGNER = "0xC9F1FfdEd29f7051538ad3a72729C3d07F920FDc"

# Measured, not estimated. Between 2026-09-08 17:50Z and 2026-09-09 13:20Z the signer
# spent 0.000977 ETH over 1183 transactions (nonce 61552 -> 62735): 0.0012 ETH/day, or
# 8.3e-7 per tx. The previous 0.0004 was 3x optimistic, which is why the "3-day" warning
# actually fired with ~24 hours left and the wallet still emptied twice.
#
# Re-measure this if the publish cadence changes -- it is the denominator of the runway,
# so an understated burn silently shortens every warning.
DEFAULT_BURN_PER_DAY = 0.0012

# A week, so an alert that lands on a Friday evening is still actionable on Monday.
# At the measured burn this warns at ~0.0084 ETH.
DEFAULT_WARN_DAYS = 7.0


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
    url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-balance-monitor/1"}
  )
  with urllib.request.urlopen(req, timeout=15) as resp:
    out = json.loads(resp.read())
  if "error" in out:
    raise RuntimeError(out["error"])
  return out["result"]


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
  signer = os.environ.get("SIGNER_ADDRESS", DEFAULT_SIGNER)
  burn = float(os.environ.get("BURN_ETH_PER_DAY", DEFAULT_BURN_PER_DAY))
  warn_days = float(os.environ.get("WARN_RUNWAY_DAYS", DEFAULT_WARN_DAYS))

  try:
    balance_eth = int(rpc(url, "eth_getBalance", [signer, "latest"]), 16) / 1e18
  except Exception as exc:
    alert(webhook, f"NUMO FEED-SIGNER BALANCE CHECK FAILED\n{signer}: {exc}")
    return 1

  runway = balance_eth / burn if burn > 0 else float("inf")
  if runway < warn_days:
    alert(
      webhook,
      "NUMO FEED-SIGNER LOW GAS\n"
      f"{signer} has {balance_eth:.6f} ETH (~{runway:.1f} days at {burn} ETH/day).\n"
      f"Below the {warn_days:.0f}-day warn threshold — top it up or the feed will go stale and freeze trading.",
    )
    return 1

  print(f"ok: {signer} balance {balance_eth:.6f} ETH (~{runway:.1f} days runway)")
  return 0


if __name__ == "__main__":
  sys.exit(main())
