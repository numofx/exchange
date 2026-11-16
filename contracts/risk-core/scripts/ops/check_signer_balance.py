#!/usr/bin/env python3
"""Gas-balance monitor for every hot wallet that posts on a timer (feed signer, forward and report relayers).

The feed publisher signs each cNGN/stable acceptData tx from a hot EOA. If that
wallet runs out of gas the feed stops publishing and getSpot() goes stale, which
FREEZES all trading. This has now happened three times: 2026-07-21, 2026-09-01
(dead for 6.8 days, found by accident while debugging something else) and
2026-09-09. The staleness alert only fires AFTER the feed has already died; this
checks the balance and warns while there's still days of runway, so it's a
proactive top-up reminder.

It watched one address until 2026-11-16, when the EURC v3 keeper's relayer emptied unwatched and the live
EURC-30NOV26 index went stale (its burn is 20x the feed signer's: 0.002 ETH lasted ~17 hours). Every wallet in
WALLETS is checked against its own measured burn; a new keeper's relayer goes in that list the day it is funded.

Env (or ~/.numo-feeds.env):
  RPC_URL             Base mainnet RPC
  ALERT_WEBHOOK_URL   Slack/Discord-compatible webhook (optional; logs only if unset)
  WATCH_WALLETS       optional override of WALLETS: "name=0xaddr@burn_eth_per_day,..."
  WARN_RUNWAY_DAYS    alert when any wallet's runway drops below this many days (default 7)

  python3 scripts/ops/check_signer_balance.py --self-test

Run every few hours via systemd timer (see numo-signer-balance-alert.timer).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

# (name, address, ETH burned per day). Measured, not estimated: balance and nonce at Base blocks 57,817,850 and
# 58,249,850 (2026-11-15 14:45 to 2026-11-16 14:45 UTC); the v3 relayer over 05:41-09:01 UTC on 2026-11-16, while it
# still posted. Each is rounded UP: the burn is the runway's denominator, so an understated one silently shortens
# every warning (the feed signer's first 0.0004 was 3x optimistic and the wallet emptied twice). Re-measure when a
# cadence changes. The v3 canary relayer (0x35ee...bDD5) is left out: its keeper is disabled.
WALLETS: list[tuple[str, str, float]] = [
  ("feed signer", "0xC9F1FfdEd29f7051538ad3a72729C3d07F920FDc", 0.0012),  # 0.00063/day measured; 2026-09-09's 0.0012 kept
  ("vol relayer (v1 forward's key)", "0xE5b8541dC2558f3db65aF88A2374e464AE4ae6de", 0.0002),  # 0.00014/day, 285 tx
  ("forward relayer v2 EURC", "0xEEa45ea4f68cb62b5eDe84E1d9F82F6d253C5321", 0.00005),  # 0.000023/day, 46 tx
  ("forward relayer v2 cNGN", "0x3ACeFDe146161D1b9ca2fdB8a3B38122818d763f", 0.00005),  # 0.000020/day, 46 tx
  ("EURC v3 keeper relayer", "0x0AbAac33E5ab7E62dED100Be465032A3636b12e5", 0.0035),  # 0.0029/day, ~2,700 tx
  # The vault no longer marks (6 tx/day, 0.0000014 ETH/day), but a dry vault cannot approve a batch at all.
  ("vault", "0x1dcA42ab54Bd3862853A821F84B29BF65245F435", 0.00001),
]

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


def parse_wallets(spec: str) -> list[tuple[str, str, float]]:
  """WATCH_WALLETS: "name=0xaddr@burn,..." -> [(name, address, burn)]. A malformed entry raises: never a silent drop."""
  out = []
  for item in filter(None, (x.strip() for x in spec.split(","))):
    name, rest = item.split("=", 1)
    address, burn = rest.split("@", 1)
    if not (address.startswith("0x") and len(address) == 42) or float(burn) <= 0:
      raise ValueError(f"WATCH_WALLETS entry {item!r}: need name=0x<40 hex>@<burn > 0>")
    out.append((name.strip(), address, float(burn)))
  if not out:
    raise ValueError("WATCH_WALLETS is set but names no wallet")
  return out


def verdict(name: str, address: str, balance_eth: float, burn: float, warn_days: float) -> str | None:
  """The alert line for a wallet under its runway threshold, or None."""
  runway = balance_eth / burn
  if runway >= warn_days:
    return None
  return f"{name} {address}: {balance_eth:.6f} ETH, ~{runway:.1f} days at {burn} ETH/day"


def main() -> int:
  load_env_file(Path.home() / ".numo-feeds.env")
  url = os.environ.get("RPC_URL", "https://mainnet.base.org")
  webhook = os.environ.get("ALERT_WEBHOOK_URL")
  wallets = parse_wallets(os.environ["WATCH_WALLETS"]) if os.environ.get("WATCH_WALLETS") else WALLETS
  warn_days = float(os.environ.get("WARN_RUNWAY_DAYS", DEFAULT_WARN_DAYS))

  low, failed = [], []
  for name, address, burn in wallets:
    try:
      balance_eth = int(rpc(url, "eth_getBalance", [address, "latest"]), 16) / 1e18
    except Exception as exc:  # noqa: BLE001 -- one unreadable wallet is reported, the rest still checked
      failed.append(f"{name} {address}: {exc}")
      continue
    line = verdict(name, address, balance_eth, burn, warn_days)
    if line:
      low.append(line)
    else:
      print(f"ok: {name} {address} {balance_eth:.6f} ETH (~{balance_eth / burn:.1f} days)")

  if low:
    alert(webhook, "NUMO HOT WALLET LOW GAS\n" + "\n".join(low)
          + f"\nBelow the {warn_days:.0f}-day threshold: top up, or the feed or keeper stops and its market freezes.")
  if failed:
    alert(webhook, "NUMO HOT WALLET BALANCE CHECK FAILED\n" + "\n".join(failed))
    return 2
  return 1 if low else 0


def self_test() -> int:
  assert all(addr.startswith("0x") and len(addr) == 42 and burn > 0 for _, addr, burn in WALLETS)
  assert len({addr.lower() for _, addr, _ in WALLETS}) == len(WALLETS), "a wallet listed twice"
  assert "0x0AbAac33E5ab7E62dED100Be465032A3636b12e5" in [a for _, a, _ in WALLETS], "the EURC v3 relayer is watched"
  # 2026-11-16: the v3 relayer at 0.002 ETH had under a day; the threshold must have fired at funding
  assert verdict("v3", "0x" + "0" * 40, 0.002, 0.0035, 7.0) is not None
  assert verdict("x", "0x" + "0" * 40, 0.0084, 0.0012, 7.0) is None, "exactly 7 days is not low"
  assert verdict("x", "0x" + "0" * 40, 0.0083, 0.0012, 7.0) is not None
  assert parse_wallets("a=0x" + "1" * 40 + "@0.001, b=0x" + "2" * 40 + "@0.5") == [
    ("a", "0x" + "1" * 40, 0.001), ("b", "0x" + "2" * 40, 0.5)]
  for bad in ("a=0x12@0.1", "a=0x" + "1" * 40 + "@0", "a=0x" + "1" * 40, ",", "noequals"):
    try:
      parse_wallets(bad)
    except ValueError:
      continue
    raise AssertionError(f"WATCH_WALLETS {bad!r} accepted")
  print(f"self-test ok: {len(WALLETS)} wallets, each with a measured burn; a malformed override is refused")
  return 0


# Exit codes, read by run-with-heartbeat.sh (HEARTBEAT_FINDING_EXIT=1): 0 healthy, 1 a finding
# (posted to Slack; paged at LOW priority), 2 the check could not run (paged at HIGH priority, like
# a missed run -- a monitor that cannot see is not a quiet one).
if __name__ == "__main__":
  try:
    sys.exit(self_test() if "--self-test" in sys.argv[1:] else main())
  except Exception as exc:  # noqa: BLE001
    print(f"signer balance check FAILED to run: {exc}", file=sys.stderr)
    sys.exit(2)
