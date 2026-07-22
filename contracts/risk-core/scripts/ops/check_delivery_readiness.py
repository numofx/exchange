#!/usr/bin/env python3
"""Proactive delivery-readiness monitor for the SEP-16 cNGN deliverable future.

Physical delivery is a one-shot event that can't be re-run, and its two silent-until-too-late gaps are
(a) the manager float account (accId=4) not being funded with the USDC+cNGN it must pay out, and
(b) an account holding a position it can't physically deliver (e.g. the cash-only MM still long — a long
owes cNGN it doesn't hold). This warns to Slack with lead time, mirroring the feed-signer balance alert.

GATED ON TIME-TO-EXPIRY: silent until within DELIVERY_WARN_DAYS of expiry (default 14), so it doesn't
nag now when the known gaps aren't yet urgent. Inside the window it alerts (and exits non-zero) until the
float is funded and every open position can deliver; after expiry it alerts on any unsettled position.

Env (or ~/.numo-feeds.env):
  RPC_URL              Base mainnet RPC
  ALERT_WEBHOOK_URL    Slack/Discord webhook (optional; logs only if unset)
  DELIVERY_WARN_DAYS   start warning this many days before expiry (default 14)

Run daily via systemd timer (numo-delivery-alert.timer).
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

# reuse the keeper's on-chain readers (scripts/ is on sys.path via the parent dir at runtime)
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from delivery_keeper import _call, _fmt, _positions, get_series_full  # noqa: E402
from mark_keeper import artifact, load_env_file  # noqa: E402

DEFAULT_WARN_DAYS = 14.0


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


def _bal(rpc: str, subaccounts: str, acc: int, asset: str) -> int:
  return int(_call(rpc, subaccounts, "getBalance(uint256,address,uint256)(int256)", str(acc), asset, "0").split()[0])


def main() -> int:
  load_env_file(Path.home() / ".numo-feeds.env")
  rpc = os.environ.get("RPC_URL", "https://mainnet.base.org")
  webhook = os.environ.get("ALERT_WEBHOOK_URL")
  warn_days = float(os.environ.get("DELIVERY_WARN_DAYS", DEFAULT_WARN_DAYS))

  try:
    fut = artifact("CNGN_SEP16_2026_FUTURE.json")
    core = artifact("core.json")
    future, sub_id, manager = fut["future"], str(fut["subId"]), fut["manager"]
    subaccounts = core["subAccounts"]
    s = get_series_full(rpc, future, sub_id)
    acc_id = int(_call(rpc, manager, "accId()(uint256)").split()[0])
    last_acc = int(_call(rpc, subaccounts, "lastAccountId()(uint256)").split()[0])
  except Exception as exc:
    alert(webhook, f"NUMO DELIVERY CHECK FAILED\n{exc}")
    return 1

  now = int(time.time())
  days_to_expiry = (s["expiry"] - now) / 86400.0

  # Gate: silent until inside the warn window (and always active from the freeze onward).
  if now < s["lastTradeTime"] and days_to_expiry > warn_days:
    print(f"ok: {days_to_expiry:.1f} days to expiry (> {warn_days:.0f}-day window); silent")
    return 0

  positions = _positions(rpc, subaccounts, future, sub_id, last_acc)
  eff_price = s["settlementPrice"] if s["settlementPriceSet"] else s["markPrice"]

  problems: list[str] = []
  need_base = need_quote = 0  # float acct4 must pay USDC to longs, cNGN to shorts
  for acc, pos in positions:
    base_amt = abs(pos) * s["contractSizeBase"] // 10**18
    quote_amt = base_amt * eff_price // 10**18
    settled = _call(rpc, manager, "accountSettled(uint256,uint96)(bool)", str(acc), sub_id).split()[0] == "true"
    if now >= s["expiry"] and not settled:
      problems.append(f"acct {acc} still UNSETTLED after expiry (pos {_fmt(pos)})")
    if pos > 0:  # LONG owes cNGN, receives USDC
      need_base += base_amt
      held = _bal(rpc, subaccounts, acc, s["quoteAsset"])
      if held < quote_amt:
        problems.append(f"acct {acc} LONG cannot deliver: holds {_fmt(held)} cNGN, owes {_fmt(quote_amt)}")
    else:        # SHORT owes USDC, receives cNGN
      need_quote += quote_amt
      held = _bal(rpc, subaccounts, acc, s["baseAsset"])
      if held < base_amt:
        problems.append(f"acct {acc} SHORT cannot deliver: holds {_fmt(held)} USDC, owes {_fmt(base_amt)}")

  fb, qb = _bal(rpc, subaccounts, acc_id, s["baseAsset"]), _bal(rpc, subaccounts, acc_id, s["quoteAsset"])
  if fb < need_base or qb < need_quote:
    problems.append(f"float acct {acc_id} UNDERFUNDED: has {_fmt(fb)} USDC / {_fmt(qb)} cNGN, "
                    f"needs {_fmt(need_base)} USDC / {_fmt(need_quote)} cNGN")

  if problems:
    hdr = f"NUMO DELIVERY NOT READY ({days_to_expiry:.1f} days to expiry, {len(positions)} open positions)"
    est = "" if s["settlementPriceSet"] else " [cNGN est. at current mark]"
    alert(webhook, hdr + est + "\n" + "\n".join(problems))
    return 1

  print(f"ok: delivery-ready — {len(positions)} positions, float funded, {days_to_expiry:.1f} days to expiry")
  return 0


if __name__ == "__main__":
  sys.exit(main())
