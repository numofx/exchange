#!/usr/bin/env python3
"""Delivery keeper for the SEP-16 cNGN deliverable future — the one-shot expiry settlement.

Physical delivery is a scheduled, one-time event (Sep 16 2026), not a loop. Run the phases IN ORDER
at expiry; each is idempotent and fail-closed. See docs/physical-delivery-runbook.md for the full flow
(proven end-to-end by test/fork/DeliverableFXManagerBaseFork.t.sol).

  --preview  READ-ONLY status: series phase (trading/frozen/expired), the manager float account's
             USDC+cNGN balance, and every account's position + delivery readiness + preview amounts.
             ALWAYS SAFE — run this first, and between the other phases.

  --fix      FIXING. At/after lastTradeTime, the owner (MPC vault) sets the settlement price via
             setSettlementPrice(subId, price). Defaults to the on-chain spot (getSpot); override with
             --price <1e18>. Must be within the future's maxMarkDeviation of the LAST mark (keep the
             mark keeper running into the close). MPC-vault-signed through the SAME client signer as the
             mark keeper. --dry-run prints the calldata and target without submitting.
             Needs MPCVAULT_TOKEN/VAULT + VAULT_ADDRESS  ->  run via scripts/ops/run-with-ssm-mark.sh

  --settle   DELIVERY. At/after expiry, sweeps accounts 1..lastAccountId and calls
             settleDeliverableFuture(future, acc, subId) for each nonzero, delivery-ready, unsettled
             position. This is a PUBLIC call — a plain RELAYER_KEY tx, no MPC signing. Unready accounts
             are skipped and logged (they lack the deliverable asset / reservation, or the manager float
             account is short the payout token). Idempotent (already-settled accounts are skipped).
             Needs RELAYER_KEY  ->  run via scripts/ops/run-with-ssm.sh

Reuses mark_keeper.py (submit_via_mpcvault, run, artifact, get_spot, load_env_file).
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from pathlib import Path

from mark_keeper import artifact, get_spot, load_env_file, run, submit_via_mpcvault  # noqa: E402

SETTLE_GAS_LIMIT = "1200000"  # settleDeliverableFuture does VM settle + 2 symmetric transfers


def _call(rpc: str, to: str, sig: str, *args: str) -> str:
  return run(["cast", "call", to, sig, *args, "--rpc-url", rpc]).strip()


def get_series_full(rpc: str, future: str, sub_id: str) -> dict:
  sig = ("getSeries(uint96)((bool,uint64,uint64,address,address,uint128,uint128,uint128,"
         "uint96,uint64,uint96,bool,int256,uint8))")
  vals = [f.strip().split()[0] for f in _call(rpc, future, sig, sub_id).strip("()").split(",")]
  return {
    "listed": vals[0] == "true", "expiry": int(vals[1]), "lastTradeTime": int(vals[2]),
    "baseAsset": vals[3], "quoteAsset": vals[4], "contractSizeBase": int(vals[5]),
    "markPrice": int(vals[8]), "settlementPrice": int(vals[10]), "settlementPriceSet": vals[11] == "true",
  }


def _positions(rpc: str, subaccounts: str, future: str, sub_id: str, last_acc: int) -> list[tuple[int, int]]:
  """Return (accountId, position) for every account holding a nonzero position in the series."""
  out = []
  for acc in range(1, last_acc + 1):
    bal = int(_call(rpc, subaccounts, "getBalance(uint256,address,uint256)(int256)", str(acc), future, sub_id).split()[0])
    if bal != 0:
      out.append((acc, bal))
  return out


def _fmt(x: int) -> str:
  return f"{x / 1e18:.4f}"


def cmd_preview(rpc: str) -> int:
  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  core = artifact("core.json")
  future, sub_id, manager = fut["future"], str(fut["subId"]), fut["manager"]
  subaccounts = core["subAccounts"]
  s = get_series_full(rpc, future, sub_id)
  acc_id = int(_call(rpc, manager, "accId()(uint256)").split()[0])
  last_acc = int(_call(rpc, subaccounts, "lastAccountId()(uint256)").split()[0])
  now = int(time.time())
  phase = "TRADING" if now < s["lastTradeTime"] else ("FROZEN (awaiting fix/expiry)" if now < s["expiry"] else "EXPIRED (deliverable)")

  print(f"=== SEP16 delivery preview ({time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(now))} UTC) ===")
  print(f"  phase: {phase}  | lastTradeTime={s['lastTradeTime']} expiry={s['expiry']}")
  print(f"  mark={_fmt(s['markPrice'])}  settlementPriceSet={s['settlementPriceSet']}  settlementPrice={_fmt(s['settlementPrice'])}")

  # manager float account (accId): must hold USDC (to pay longs) + cNGN (to pay shorts)
  fb = int(_call(rpc, subaccounts, "getBalance(uint256,address,uint256)(int256)", str(acc_id), s["baseAsset"], "0").split()[0])
  qb = int(_call(rpc, subaccounts, "getBalance(uint256,address,uint256)(int256)", str(acc_id), s["quoteAsset"], "0").split()[0])
  print(f"  float account {acc_id}: USDC={_fmt(fb)}  cNGN={_fmt(qb)}")

  positions = _positions(rpc, subaccounts, future, sub_id, last_acc)
  if not positions:
    print("  no open positions.")
    return 0
  print(f"  {len(positions)} account(s) with a position:")
  need_base = need_quote = 0
  for acc, pos in positions:
    settled = _call(rpc, manager, "accountSettled(uint256,uint96)(bool)", str(acc), sub_id).split()[0] == "true"
    ready = _call(rpc, manager, "isDeliveryReady(uint256)(bool)", str(acc)).split()[0] == "true"
    can = _call(rpc, future, "previewSettlement(uint256,uint96)((int256,uint256,uint256,uint256,bool))", str(acc), sub_id).strip("()").split(",")[4].strip() == "true"
    # Compute amounts ourselves so the cNGN float need is visible BEFORE the fixing (previewSettlement
    # returns quoteAmount=0 until settlementPrice is set). Use settlementPrice if set, else the mark as proxy.
    eff_price = s["settlementPrice"] if s["settlementPriceSet"] else s["markPrice"]
    base_amt = abs(pos) * s["contractSizeBase"] // 10**18
    quote_amt = base_amt * eff_price // 10**18
    side = "LONG" if pos > 0 else "SHORT"
    # float needs: USDC to pay longs, cNGN to pay shorts
    if pos > 0:
      need_base += base_amt
    else:
      need_quote += quote_amt
    print(f"    acct {acc}: {side} pos={_fmt(pos)} -> delivers "
          + (f"{_fmt(quote_amt)} cNGN, gets {_fmt(base_amt)} USDC" if pos > 0 else f"{_fmt(base_amt)} USDC, gets {_fmt(quote_amt)} cNGN")
          + f" | ready={ready} settled={settled} canSettle={can}")
  est = "" if s["settlementPriceSet"] else " (cNGN est. at current mark; exact after --fix)"
  print(f"  FLOAT ACCOUNT {acc_id} MUST HOLD >= {_fmt(need_base)} USDC and >= {_fmt(need_quote)} cNGN to cover payouts{est}"
        f"  (has USDC={_fmt(fb)} cNGN={_fmt(qb)}"
        + ("  ✅" if fb >= need_base and qb >= need_quote else "  ❌ UNDERFUNDED") + ")")
  return 0


def cmd_fix(rpc: str, price: int | None, dry_run: bool) -> int:
  token, vault_uuid, vault_addr = os.environ.get("MPCVAULT_TOKEN"), os.environ.get("MPCVAULT_VAULT"), os.environ.get("VAULT_ADDRESS")
  if not dry_run and not (token and vault_uuid and vault_addr):
    print("--fix needs MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS (run via run-with-ssm-mark.sh)", file=sys.stderr)
    return 1
  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  future, feed, sub_id = fut["future"], fut["spotFeed"], str(fut["subId"])
  s = get_series_full(rpc, future, sub_id)
  now = int(time.time())
  if s["settlementPriceSet"]:
    print(f"settlementPrice already set ({_fmt(s['settlementPrice'])}); nothing to fix.")
    return 0
  if now < s["lastTradeTime"]:
    print(f"REFUSING: still TRADING (now < lastTradeTime {s['lastTradeTime']}). Fix only after the freeze.", file=sys.stderr)
    return 1
  target = price if price is not None else get_spot(rpc, feed)  # getSpot raises if the feed is stale
  # deviation guard mirrors the on-chain _checkDeviation against the last mark
  dev_bps = abs(target - s["markPrice"]) * 10_000 // s["markPrice"] if s["markPrice"] else 10_000
  calldata = run(["cast", "calldata", "setSettlementPrice(uint96,uint256)", sub_id, str(target)])
  print(f"[fix] setSettlementPrice({sub_id}, {target}) = {_fmt(target)}  (last mark {_fmt(s['markPrice'])}, {dev_bps}bps)")
  if dry_run:
    print(f"[fix] dry-run — calldata={calldata} (not submitted)")
    return 0
  tx = submit_via_mpcvault(token, vault_uuid, vault_addr, future, calldata)
  print(f"[fix] setSettlementPrice submitted tx={tx}")
  return 0


def cmd_settle(rpc: str, dry_run: bool) -> int:
  relayer = os.environ.get("RELAYER_KEY")
  if not dry_run and not relayer:
    print("--settle needs RELAYER_KEY (run via run-with-ssm.sh)", file=sys.stderr)
    return 1
  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  core = artifact("core.json")
  future, sub_id, manager = fut["future"], str(fut["subId"]), fut["manager"]
  subaccounts = core["subAccounts"]
  s = get_series_full(rpc, future, sub_id)
  now = int(time.time())
  if not s["settlementPriceSet"]:
    print("REFUSING: settlementPrice not set — run --fix first.", file=sys.stderr)
    return 1
  if now < s["expiry"]:
    print(f"REFUSING: not yet expired (now < expiry {s['expiry']}).", file=sys.stderr)
    return 1
  last_acc = int(_call(rpc, subaccounts, "lastAccountId()(uint256)").split()[0])
  positions = _positions(rpc, subaccounts, future, sub_id, last_acc)
  settled = skipped = 0
  for acc, pos in positions:
    if _call(rpc, manager, "accountSettled(uint256,uint96)(bool)", str(acc), sub_id).split()[0] == "true":
      continue
    can = _call(rpc, manager, "canSettleDeliverableFuture(address,uint256,uint96)(bool)", future, str(acc), sub_id).split()[0] == "true"
    if not can:
      print(f"  acct {acc}: SKIP (not delivery-ready — missing deliverable/reservation or float short)")
      skipped += 1
      continue
    if dry_run:
      print(f"  acct {acc}: would settleDeliverableFuture (pos {_fmt(pos)})")
      settled += 1
      continue
    out = run(["cast", "send", manager, "settleDeliverableFuture(address,uint256,uint96)", future, str(acc), sub_id,
               "--gas-limit", SETTLE_GAS_LIMIT, "--rpc-url", rpc, "--private-key", relayer, "--json"])
    import json
    tx = json.loads(out)
    if tx.get("status") not in ("0x1", 1):
      print(f"  acct {acc}: REVERTED tx={tx.get('transactionHash')}", file=sys.stderr)
      skipped += 1
    else:
      print(f"  acct {acc}: settled tx={tx['transactionHash']}")
      settled += 1
  print(f"[settle] done: {settled} settled, {skipped} skipped of {len(positions)} positions.")
  return 1 if skipped else 0


def main() -> int:
  p = argparse.ArgumentParser()
  g = p.add_mutually_exclusive_group(required=True)
  g.add_argument("--preview", action="store_true")
  g.add_argument("--fix", action="store_true")
  g.add_argument("--settle", action="store_true")
  p.add_argument("--price", type=int, default=None, help="settlement price, 1e18-scaled (default: on-chain spot)")
  p.add_argument("--dry-run", action="store_true")
  p.add_argument("--rpc-url", default=None)
  a = p.parse_args()

  load_env_file(Path.home() / ".numo-feeds.env")
  rpc = a.rpc_url or os.environ.get("RPC_URL") or "https://mainnet.base.org"
  if a.preview:
    return cmd_preview(rpc)
  if a.fix:
    return cmd_fix(rpc, a.price, a.dry_run)
  return cmd_settle(rpc, a.dry_run)


if __name__ == "__main__":
  sys.exit(main())
