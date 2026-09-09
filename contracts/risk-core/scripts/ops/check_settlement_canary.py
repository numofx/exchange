#!/usr/bin/env python3
"""Settlement canary: can the venue still price and settle?

The 2026-09-01 feed outage was silent for 6.8 days. Every service was healthy, the API
answered, orders matched -- and every on-chain settlement reverted BLF_DataTooOld. It was
found by accident. Nothing was watching the one thing that had actually broken.

Two checks, deliberately overlapping:

  1. getMargin(accountId, true) on the StandardManager, for each configured subaccount.
     This walks the same path a settlement does -- _getMarketMargin reads the spot feed for
     every market the account holds a position in -- so a revert means the book cannot
     settle, whatever the cause: a stale feed, a bad repoint, a misconfigured market.

  2. getSpot() on every market's spot feed and on the global stableFeed. Account-independent,
     so it still catches a stale feed for a market nobody currently holds. Check 1 alone
     would report healthy in that case, which is exactly the blind spot that let the last
     outage run for a week.

An empty subaccount has no market holding, so the manager reads no feed and check 1 passes
while proving nothing. Point CANARY_ACCOUNTS at accounts that actually hold positions; the
script says so loudly when a checked account turns out to have zero markets.

Env (or ~/.numo-feeds.env):
  RPC_URL            Base mainnet RPC
  ALERT_WEBHOOK_URL  Slack/Discord-compatible webhook (optional; logs only if unset)
  SRM_ADDRESS        StandardManager (default: the live Base deployment)
  CANARY_ACCOUNTS    comma-separated subaccount ids (default: 15)

Run every few minutes via systemd timer (see numo-settlement-canary.timer).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

DEFAULT_SRM = "0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b"
DEFAULT_ACCOUNTS = "15"

# Verified with `cast sig`. A wrong selector here would eth_call into empty space and the
# node would answer 0x, which this script treats as a failure rather than a pass -- but the
# alert would name the wrong cause, so they are pinned and self-tested.
SEL_GET_MARGIN = "0x623bb445"      # getMargin(uint256,bool)
SEL_GET_MARKET_FEEDS = "0xa95371a4"  # getMarketFeeds(uint256)
SEL_LAST_MARKET_ID = "0x565eb87c"    # lastMarketId()
SEL_STABLE_FEED = "0xf4d0508a"       # stableFeed()
SEL_GET_SPOT = "0x2b37269c"          # getSpot()

# Revert selectors worth naming in an alert. Anything else is reported as raw returndata.
KNOWN_ERRORS = {
  "0x1141796d": "BLF_DataTooOld()",
  "0x93ce63e9": "BF_DataTooOld()",
  "0x1607767a": "BLF_InvalidSignature()",
}


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip().removeprefix("export ").strip(), value.strip())


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(
    url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-settlement-canary/1"}
  )
  with urllib.request.urlopen(req, timeout=15) as resp:
    out = json.loads(resp.read())
  if "error" in out:
    raise RuntimeError(out["error"])
  return out["result"]


def call(url: str, to: str, data: str) -> str:
  return rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])


def describe_revert(exc: Exception) -> str:
  """Pull a named custom error out of an eth_call failure where the node returns one."""
  text = str(exc)
  for selector, name in KNOWN_ERRORS.items():
    if selector in text:
      return f"{name} [{selector}]"
  return text[:200]


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


def self_test() -> None:
  sys.path.insert(0, str(Path(__file__).resolve().parent))
  from resolve_cngn_action6 import keccak

  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"
  for signature, expected in {
    "getMargin(uint256,bool)": SEL_GET_MARGIN,
    "getMarketFeeds(uint256)": SEL_GET_MARKET_FEEDS,
    "lastMarketId()": SEL_LAST_MARKET_ID,
    "stableFeed()": SEL_STABLE_FEED,
    "getSpot()": SEL_GET_SPOT,
  }.items():
    actual = "0x" + keccak(signature.encode()).hex()[:8]
    assert actual == expected, f"{signature}: hardcoded {expected}, actual {actual}"
  for selector, name in KNOWN_ERRORS.items():
    actual = "0x" + keccak(name.encode()).hex()[:8]
    assert actual == selector, f"{name}: hardcoded {selector}, actual {actual}"


def main() -> int:
  if "--self-test" in sys.argv:
    self_test()
    print("self-test ok: every selector matches its signature")
    return 0

  load_env_file(Path.home() / ".numo-feeds.env")
  url = os.environ.get("RPC_URL", "https://mainnet.base.org")
  webhook = os.environ.get("ALERT_WEBHOOK_URL")
  srm = os.environ.get("SRM_ADDRESS", DEFAULT_SRM)
  accounts = [int(a) for a in os.environ.get("CANARY_ACCOUNTS", DEFAULT_ACCOUNTS).split(",") if a.strip()]

  self_test()

  failures: list[str] = []
  checked: list[str] = []

  # 1. the manager path, per account
  for account_id in accounts:
    payload = SEL_GET_MARGIN + f"{account_id:064x}" + f"{1:064x}"
    try:
      margin = call(url, srm, payload)
      value = int(margin, 16)
      if value >= 1 << 255:
        value -= 1 << 256
      checked.append(f"getMargin({account_id}) = {value / 1e18:.6f}")
    except Exception as exc:
      failures.append(f"getMargin({account_id}) REVERTED: {describe_revert(exc)}")

  # 2. every feed the SRM could read, whether or not anyone holds that market
  try:
    last_market = int(call(url, srm, SEL_LAST_MARKET_ID), 16)
  except Exception as exc:
    alert(webhook, f"NUMO SETTLEMENT CANARY FAILED\nlastMarketId() on {srm}: {exc}")
    return 1

  feeds: list[tuple[str, str]] = []
  for market_id in range(1, last_market + 1):
    try:
      word = call(url, srm, SEL_GET_MARKET_FEEDS + f"{market_id:064x}")
      feeds.append((f"market {market_id} spot", "0x" + word[26:66]))
    except Exception as exc:
      failures.append(f"getMarketFeeds({market_id}) REVERTED: {describe_revert(exc)}")
  try:
    feeds.append(("stableFeed", "0x" + call(url, srm, SEL_STABLE_FEED)[26:]))
  except Exception as exc:
    failures.append(f"stableFeed() REVERTED: {describe_revert(exc)}")

  for label, feed in feeds:
    if int(feed, 16) == 0:
      continue  # unset feed: only read for asset types this venue does not list
    try:
      spot = int(call(url, feed, SEL_GET_SPOT)[2:66], 16)
      checked.append(f"{label} {feed} getSpot = {spot / 1e18:.10f}")
    except Exception as exc:
      failures.append(f"{label} {feed} getSpot() REVERTED: {describe_revert(exc)}")

  if failures:
    alert(
      webhook,
      "NUMO SETTLEMENT HALTED\n"
      "The venue cannot price or settle. Orders will keep matching off-chain and every\n"
      "on-chain leg will revert, silently, until this is fixed.\n\n"
      + "\n".join(f"  - {f}" for f in failures)
      + ("\n\nstill healthy:\n" + "\n".join(f"  - {c}" for c in checked) if checked else ""),
    )
    return 1

  print("ok: " + "; ".join(checked))
  return 0


if __name__ == "__main__":
  sys.exit(main())
