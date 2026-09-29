#!/usr/bin/env python3
"""Propose the USDCcNGN-PERP ENABLE batch to MPCVault -- only once every launch gate passes.

The perp deploys closed twice over: its OI cap is 0 (closed to every path, including accounts that
move perp between themselves with SubAccounts.submitTransfers) and its TradeModule is not allowlisted
on Matching (closed to the venue). Neither deploy batch changes that. This is the one action that
opens the market:

  0. perp.setTotalPositionCap(srm, launchOICap)     every path, bounded
  1. matching.setAllowedModule(perpTradeModule, true)   the venue

Gates, all read live and all required (re-checked before EACH action is proposed):

  custody   the vault owns every stack contract and the module; the SRM has a guardian that is not the
            vault (the stack batch's last action); the market is still closed
  feeds     index, mark and both impact feeds answer and are fresh (index <= 600s, diffs <= 600s)
  keeper    its /health says a pass completed OK within 3 poll intervals and DRY_RUN is off; its
            funding account is owned by the keeper EOA, sits under the perp SRM, holds only cash, and holds >= --min-keeper-cash;
            its EOA holds >= --min-keeper-eth for gas
  sm        the security module's account holds at least a third of ONE side's notional at the launch
            cap (cap / 2 NGN at the live index), and never less than --min-sm-cash
  quoter    the perp book on markets-service has a bid and an ask, each with >= --min-quote-usd of
            depth within 2% of the index (optionally from --quoter-owner)

It NEVER signs, executes or broadcasts. Without --propose it prints the gate report and the sheet.
With --propose each action goes to the MPCVault app for a human to approve, one at a time.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL, and
  KEEPER_HEALTH_URL   e.g. http://127.0.0.1:9464/health on the ops box
  MARKETS_URL         default https://api.numofx.com

Usage:
  python3 scripts/ops/propose_perp_enable_batch.py              # gates + sheet, proposes nothing
  python3 scripts/ops/propose_perp_enable_batch.py --propose    # gated, one action at a time
  python3 scripts/ops/propose_perp_enable_batch.py --self-test  # offline selector check
  python3 scripts/ops/propose_perp_enable_batch.py --local --stack <json> --module <json> --write <out>
                                                               # local fork (chain 31337): gates, then
                                                               # write the actions for the local tool
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_feed_staleness import diff_feed_age, feed_age  # noqa: E402
from propose_cngn_spot_batch import (  # noqa: E402  single implementation of the MPCVault transport
  CONFIRM_POLL_SEC,
  CONFIRM_TIMEOUT_SEC,
  EXPECTED_VAULT,
  confirm_on_chain,
  load_env_file,
  propose,
  request_tx_hash,
  rpc,
)
from resolve_cngn_action6 import keccak  # noqa: E402  zero-dependency, vector-checked

ROOT = Path(__file__).resolve().parent.parent.parent
STACK_ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_PERP_STACK.json"
MODULE_ARTIFACT = ROOT.parent / "execution" / "deployments" / "8453" / "CNGN_PERP_TRADE_MODULE.json"
OUT_ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_PERP_ENABLE_VAULT_ACTIONS.json"

SUB_ACCOUNTS = "0x7019244E25FA416e6Ca2ed2F3cA25277aef72843"
FEED_MAX_AGE_SEC = 600
QUOTE_BAND = 0.02

SIGNATURES = {
  "owner": "owner()",
  "guardian": "guardian()",
  "ownerOf": "ownerOf(uint256)",
  "allowedModules": "allowedModules(address)",
  "totalPositionCap": "totalPositionCap(address)",
  "setTotalPositionCap": "setTotalPositionCap(address,uint256)",
  "setAllowedModule": "setAllowedModule(address,bool)",
  "getBalance": "getBalance(uint256,address,uint256)",
  "manager": "manager(uint256)",
  "ownerOf": "ownerOf(uint256)",
  "getSpot": "getSpot()",
  "getResult": "getResult()",
}


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


def word_address(address: str) -> str:
  return "0" * 24 + address.lower().removeprefix("0x")


def word_uint(value: int) -> str:
  return format(value, "064x")


def call(rpc_url: str, to: str, data: str) -> str:
  return rpc(rpc_url, "eth_call", [{"to": to, "data": data}, "latest"])


def uint_at(raw: str, index: int = 0) -> int:
  body = raw.removeprefix("0x")
  return int(body[index * 64:(index + 1) * 64], 16)


def int_at(raw: str, index: int = 0) -> int:
  value = uint_at(raw, index)
  return value - (1 << 256) if value >= 1 << 255 else value


def address_at(raw: str) -> str:
  return "0x" + raw.removeprefix("0x")[24:64]


@dataclass
class Gate:
  name: str
  ok: bool
  detail: str


@dataclass
class Venue:
  perp: str
  srm: str
  cash: str
  module: str
  matching: str
  index_feed: str
  diff_feeds: dict[str, str]
  sm_account: int
  launch_cap: int
  owned: list[str]


def load_venue(stack_path: Path, module_path: Path) -> Venue:
  stack = json.loads(stack_path.read_text())
  module = json.loads(module_path.read_text())
  # The local tool's artifact lists them as "owned"; the 8453 artifact names each one.
  owned = list(stack["owned"]) if "owned" in stack else [
    stack[k] for k in ("cash", "srmViewer", "srm", "securityModule", "auction", "stableFeed",
                       "indexFeed", "markFeed", "impactAskFeed", "impactBidFeed", "perp") if k in stack]
  owned.append(module["tradePerp"])
  return Venue(
    perp=stack["perp"], srm=stack["srm"], cash=stack["cash"], module=module["tradePerp"],
    matching=module.get("matching", "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"),
    index_feed=stack["indexFeed"],
    diff_feeds={"mark": stack["markFeed"], "impact ask": stack["impactAskFeed"], "impact bid": stack["impactBidFeed"]},
    sm_account=int(stack["securityModuleAccount"]),
    launch_cap=int(stack.get("launchOICap", 50_000_000 * 10**18)),
    owned=owned,
  )


def http_json(url: str) -> dict:
  req = urllib.request.Request(url, headers={"accept": "application/json", "User-Agent": "numo-ops/1.0"})
  with urllib.request.urlopen(req, timeout=15) as resp:
    return json.loads(resp.read())


def gate_custody(rpc_url: str, v: Venue, vault: str) -> Gate:
  not_owned = [c for c in v.owned if address_at(call(rpc_url, c, selector("owner"))).lower() != vault.lower()]
  if not_owned:
    return Gate("custody", False, f"vault does not own {', '.join(not_owned)}")
  # The stack batch ends with srm.setGuardian: without a guardian nobody but the vault can pause.
  guardian = address_at(call(rpc_url, v.srm, selector("guardian")))
  if int(guardian, 16) == 0:
    return Gate("custody", False, "srm has no guardian: the stack vault batch did not finish (setGuardian is its last action)")
  if guardian.lower() == vault.lower():
    return Gate("custody", False, "srm guardian is the vault: set the hot ops key, or no one can pause without signers")
  allowed = uint_at(call(rpc_url, v.matching, selector("allowedModules") + word_address(v.module)))
  cap = uint_at(call(rpc_url, v.perp, selector("totalPositionCap") + word_address(v.srm)))
  if allowed or cap:
    return Gate("custody", False, f"market is not closed (module allowed={bool(allowed)}, cap={cap}); nothing to enable")
  return Gate("custody", True, f"vault owns all {len(v.owned)} contracts; guardian {guardian}; market closed (cap 0, module not allowed)")


def gate_feeds(rpc_url: str, v: Venue) -> Gate:
  problems = []
  try:
    age, _ = feed_age(rpc_url, v.index_feed)
    call(rpc_url, v.index_feed, selector("getSpot"))
    if age > FEED_MAX_AGE_SEC:
      problems.append(f"index {age}s old")
  except Exception as exc:  # noqa: BLE001 -- any failure to read is a failed gate
    problems.append(f"index unreadable: {exc}")
  for name, feed in v.diff_feeds.items():
    try:
      age = diff_feed_age(rpc_url, feed)
      call(rpc_url, feed, selector("getResult"))
      if age > FEED_MAX_AGE_SEC:
        problems.append(f"{name} {age}s old")
    except Exception as exc:  # noqa: BLE001
      problems.append(f"{name} unreadable: {exc}")
  if problems:
    return Gate("feeds", False, "; ".join(problems))
  return Gate("feeds", True, f"index and 3 diff feeds answer, all <= {FEED_MAX_AGE_SEC}s old")


def gate_keeper(rpc_url: str, v: Venue, health_url: str, min_cash: float, min_eth: float) -> Gate:
  if not health_url:
    return Gate("keeper", False, "KEEPER_HEALTH_URL not set")
  try:
    health = http_json(health_url)
  except Exception as exc:  # noqa: BLE001
    return Gate("keeper", False, f"health unreachable: {exc}")
  if health.get("dryRun", True):
    return Gate("keeper", False, "keeper is in DRY_RUN")
  stale_after = 3 * max(int(health.get("pollIntervalMs", 15_000)) // 1000, 20)
  age = int(time.time()) - int(health.get("lastPassAt", 0))
  if not health.get("lastPassOk") or age > stale_after:
    return Gate("keeper", False, f"last pass ok={health.get('lastPassOk')} {age}s ago (limit {stale_after}s)")
  account = int(health["keeperAccount"])
  manager = address_at(call(rpc_url, SUB_ACCOUNTS, selector("manager") + word_uint(account)))
  if manager.lower() != v.srm.lower():
    return Gate("keeper", False, f"funding account #{account} is not under the perp SRM")
  # An account opened through the app or SubAccountCreator is held by Matching: the keeper could not
  # move its cash into a bid account, and every bid would fail.
  owner = address_at(call(rpc_url, SUB_ACCOUNTS, selector("ownerOf") + word_uint(account)))
  if owner.lower() != str(health.get("keeperAddress", "")).lower():
    return Gate("keeper", False, f"funding account #{account} is owned by {owner}, not the keeper EOA {health.get('keeperAddress')}")
  balance = lambda asset: int_at(call(rpc_url, SUB_ACCOUNTS, selector("getBalance") + word_uint(account) + word_address(asset) + word_uint(0)))  # noqa: E731
  cash, perp = balance(v.cash) / 1e18, balance(v.perp)
  if perp != 0:
    return Gate("keeper", False, f"funding account #{account} holds perp: it can no longer fund bid accounts")
  if cash < min_cash:
    return Gate("keeper", False, f"funding account #{account} holds {cash:,.2f} cash (< {min_cash:,.2f})")
  eth = int(rpc(rpc_url, "eth_getBalance", [health["keeperAddress"], "latest"]), 16) / 1e18
  if eth < min_eth:
    return Gate("keeper", False, f"keeper EOA holds {eth:.4f} ETH (< {min_eth})")
  return Gate("keeper", True, f"live, not dry-run, last pass {age}s ago; account #{account} {cash:,.2f} cash; {eth:.4f} ETH")


def sm_seed_required(launch_cap: int, index_usd_per_ngn: float, floor: float) -> float:
  """The seed rule (docs/cngn-perp-go-live.md): at least a third of ONE side's notional at the cap
  being opened. The cap sums both sides, so one side is cap / 2 NGN. A third is the initial margin
  on that side; the fork test (testSecurityModuleLossFromIndexJumpAtFullCap) shows the worst-case
  SecurityModule payout reaching it at a ~50% index jump."""
  one_side_usd = (launch_cap / 2 / 1e18) * index_usd_per_ngn
  return max(floor, one_side_usd / 3)


def gate_security_module(rpc_url: str, v: Venue, min_cash: float) -> Gate:
  raw = call(rpc_url, SUB_ACCOUNTS, selector("getBalance") + word_uint(v.sm_account) + word_address(v.cash) + word_uint(0))
  cash = int_at(raw) / 1e18
  try:
    index = uint_at(call(rpc_url, v.index_feed, selector("getSpot"))) / 1e18
  except Exception as exc:  # noqa: BLE001
    return Gate("sm", False, f"index unreadable, cannot size the seed: {exc}")
  required = sm_seed_required(v.launch_cap, index, min_cash)
  if cash < required:
    return Gate("sm", False, f"security module holds {cash:,.2f} (< {required:,.2f}: a third of one side at the {v.launch_cap // 10**18:,} NGN cap)")
  return Gate("sm", True, f"security module holds {cash:,.2f} (>= {required:,.2f}, a third of one side at the cap)")


def gate_quoter(rpc_url: str, v: Venue, markets_url: str, min_usd: float, owner: str | None) -> Gate:
  try:
    index = uint_at(call(rpc_url, v.index_feed, selector("getSpot"))) / 1e18
    book = http_json(f"{markets_url}/v1/book?asset_address={v.perp.lower()}&sub_id=0")
  except Exception as exc:  # noqa: BLE001
    return Gate("quoter", False, f"book or index unreadable: {exc}")
  depth = {}
  for side in ("bids", "asks"):
    usd = 0.0
    for order in book.get(side) or []:
      if owner and order.get("owner_address", "").lower() != owner.lower():
        continue
      price = float(order["limit_price"])
      if abs(price - index) / index > QUOTE_BAND:
        continue
      remaining = float(order["desired_amount"]) - float(order["filled_amount"])
      usd += remaining * price
    depth[side] = usd
  if min(depth.values()) < min_usd:
    return Gate("quoter", False, f"depth within {QUOTE_BAND:.0%} of index: bids ${depth['bids']:,.0f}, asks ${depth['asks']:,.0f} (< ${min_usd:,.0f})")
  return Gate("quoter", True, f"two-sided within {QUOTE_BAND:.0%}: bids ${depth['bids']:,.0f}, asks ${depth['asks']:,.0f}")


def run_gates(rpc_url: str, v: Venue, args, vault: str) -> list[Gate]:
  return [
    gate_custody(rpc_url, v, vault),
    gate_feeds(rpc_url, v),
    gate_keeper(rpc_url, v, os.environ.get("KEEPER_HEALTH_URL", ""), args.min_keeper_cash, args.min_keeper_eth),
    gate_security_module(rpc_url, v, args.min_sm_cash),
    gate_quoter(rpc_url, v, os.environ.get("MARKETS_URL", "https://api.numofx.com"), args.min_quote_usd, args.quoter_owner),
  ]


def build_actions(v: Venue) -> list[dict]:
  specs = [
    (v.perp, selector("setTotalPositionCap") + word_address(v.srm) + word_uint(v.launch_cap),
     f"perp.setTotalPositionCap(srm, {v.launch_cap // 10**18:,} NGN) [opens every path, bounded]"),
    (v.matching, selector("setAllowedModule") + word_address(v.module) + word_uint(1),
     "matching.setAllowedModule(perpTradeModule, true) [opens the venue]"),
  ]
  actions = []
  for to, data, description in specs:
    digest = "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()
    actions.append({"description": description, "to": to, "value": "0", "data": data, "digest": digest})
  return actions


def report(gates: list[Gate]) -> bool:
  print()
  for g in gates:
    print(f"  [{'PASS' if g.ok else 'FAIL'}] {g.name:<8} {g.detail}")
  return all(g.ok for g in gates)


def self_test() -> int:
  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"
  pinned = {"setTotalPositionCap": "0x40a557bd", "setAllowedModule": "0xb1b62825", "allowedModules": "0x8ba5a0c2",
            "totalPositionCap": "0x745ab570", "guardian": "0x452a9320", "ownerOf": "0x6352211e"}
  for name, want in pinned.items():
    got = selector(name)
    assert got == want, f"{name}: {got} != {want}"
  # 50M NGN cap at 1374 NGN/USD: 25M NGN a side is $18,195, a third of it $6,065.
  assert round(sm_seed_required(50_000_000 * 10**18, 1 / 1374, 5_000)) == 6065
  assert sm_seed_required(1 * 10**18, 1 / 1374, 5_000) == 5_000
  print("self-test ok: selectors match their `cast sig` values; seed rule sized")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Gated proposal of the USDCcNGN-PERP enable batch")
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--local", action="store_true", help="local fork (chain 31337) only; never proposes")
  ap.add_argument("--stack", type=Path, default=STACK_ARTIFACT)
  ap.add_argument("--module", type=Path, default=MODULE_ARTIFACT)
  ap.add_argument("--write", type=Path, help="write the actions here (default: the 8453 artifact)")
  ap.add_argument("--min-sm-cash", type=float, default=5_000)
  ap.add_argument("--min-keeper-cash", type=float, default=1_000)
  ap.add_argument("--min-keeper-eth", type=float, default=0.005)
  ap.add_argument("--min-quote-usd", type=float, default=1_000)
  ap.add_argument("--quoter-owner", help="require the quotes to come from this owner address")
  args = ap.parse_args()

  if args.self_test:
    return self_test()

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc_url = os.environ.get("RPC_URL") or os.environ.get("BASE_RPC_URL", "")
  if not rpc_url:
    raise SystemExit("RPC_URL (or BASE_RPC_URL) is required")
  chain_id = int(rpc(rpc_url, "eth_chainId", []), 16)
  if args.local and chain_id != 31337:
    raise SystemExit(f"--local is for a local fork (31337); this RPC is chain {chain_id}")
  if not args.local and chain_id != 8453:
    raise SystemExit(f"expected Base mainnet (8453), got chain {chain_id}; use --local for a fork")
  if args.local and args.propose:
    raise SystemExit("--local never proposes")

  vault = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault} is not the recorded vault {EXPECTED_VAULT}")

  venue = load_venue(args.stack, args.module)
  actions = build_actions(venue)
  passed = report(run_gates(rpc_url, venue, args, vault))
  print()
  for i, a in enumerate(actions):
    print(f"  {i}  {a['to']}  {a['digest']}  {a['description']}")
  if not passed:
    print("\nGATES FAILED: nothing written, nothing proposed.")
    return 1

  out = args.write or OUT_ARTIFACT
  out.write_text(json.dumps(actions, indent=2) + "\n")
  print(f"\nall gates pass; wrote {out}")
  if not args.propose:
    print("dry run: nothing proposed. Re-run with --propose; compare each digest with MPCVault before approving.")
    return 0

  token, vault_uuid = os.environ.get("MPCVAULT_TOKEN", ""), os.environ.get("MPCVAULT_VAULT", "")
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  for i, a in enumerate(actions):
    # Gates are re-read before each action: the first can take a while to be approved, and a keeper
    # or feed that died in the meantime must stop the second.
    if i > 0 and not report(run_gates_after_cap(rpc_url, venue, args, vault)):
      raise SystemExit(f"a gate failed before action {i}; the cap is raised but the venue is not open. Stop and investigate.")
    uuid = propose(token, vault_uuid, vault, a)
    print(f"  [{i}] proposed uuid={uuid}\n       {a['description']}\n       digest {a['digest']}\n       -> approve in MPCVault now")
    deadline, tx_hash = time.time() + CONFIRM_TIMEOUT_SEC, None
    while time.time() < deadline and not tx_hash:
      time.sleep(CONFIRM_POLL_SEC)
      tx_hash = request_tx_hash(token, uuid)
    if not tx_hash:
      raise SystemExit(f"action {i} not approved within the timeout")
    confirm_on_chain(rpc_url, tx_hash)
  print("\nUSDCcNGN-PERP enabled. markets-service will report trading_enabled within 30s.")
  return 0


def run_gates_after_cap(rpc_url: str, v: Venue, args, vault: str) -> list[Gate]:
  """The gates between the two actions: custody now expects the cap raised and the module still off."""
  allowed = uint_at(call(rpc_url, v.matching, selector("allowedModules") + word_address(v.module)))
  cap = uint_at(call(rpc_url, v.perp, selector("totalPositionCap") + word_address(v.srm)))
  custody = Gate("custody", cap == v.launch_cap and not allowed, f"cap={cap} module allowed={bool(allowed)}")
  return [custody, *run_gates(rpc_url, v, args, vault)[1:]]


if __name__ == "__main__":
  raise SystemExit(main())
