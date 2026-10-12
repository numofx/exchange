#!/usr/bin/env python3
"""Propose MarginEngine's two vault batches to MPCVault, from deploy-margin-engine.s.sol's artifacts.

  setup   MARGIN_ENGINE_VAULT_ACTIONS.json: accept the four contracts the deployer nominated (engine, viewer,
          future, forward feed), wire the engine into the perp stack's cash, cNGN escrow (with its cap), perp
          and auction, and grant it the SRM's guardian. Opens nothing.
  enable  MARGIN_ENGINE_ENABLE_VAULT_ACTIONS.json: the perp's cap under the engine, the future's cap, then the
          future on the perp TradeModule. The only actions that open the engine. Proposed only while every gate
          below passes, re-read before each action. Making the live SRM close-only is not here: it is set to
          the live open interest at the cutover, once markets-service refuses orders that would increase it.

Every action in the file is rebuilt here from the deployment artifact and must match it exactly (to,
calldata, value), and its digest is recomputed (keccak(to || keccak(data)), the convention of
deploy-margin-engine.s.sol). An action whose postcondition already holds is skipped, so a re-run
proposes only what is left.

Enable gates (all read live, all required):
  custody   the vault owns the engine, viewer, future and forward feed; the setup batch has landed (cash,
            escrow, perp and auction take the engine, the escrow cap and guardian are set); the engine is
            closed (its perp and futures caps are 0, the future is not on the TradeModule)
  feeds     the index answers and is <= 600s old
  marks     the future has been marked within FORWARD_MARK_LATE (2h): the keeper is publishing
  reserve   the VM pool holds its cNGN reserve: 30% of one side's notional at the cap being opened, in
            cNGN at the index (check_perp_pager.future_reserve_target_cngn). Seed it first: a cNGN
            deposit into the pool account, which is not a vault action
  escrow    the escrow cap still has a reserve's worth of headroom after the seed, so a top-up fits
  sm        the SecurityModule's cash covers a 25% step across the perp's open interest now (under the
            live SRM, until the cutover) and the future's one side at the cap being opened
            (check_perp_pager.sm_required_usd)
  pager     check_perp_pager.py ran OK within 3 minutes, with a provider and a dead-man's switch

pool-withdraw  engine.withdrawFromPool(asset, amount, recipient): take cNGN or cash out of the VM pool, e.g. to
          rebalance it (the USDC losers paid in, out to buy cNGN). withdrawFromPool has no risk check, so the
          gate is here: a cNGN withdrawal must leave the pool at or above its reserve target (30% of one side at
          the cap, check_perp_pager.future_reserve_target_cngn), a cash one must leave its cash at or above 0.

It NEVER signs, executes or broadcasts. Without --propose it prints the gates and the sheet. With
--propose each action goes to the MPCVault app for a human to approve, one at a time, from the vault.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.

  python3 scripts/ops/propose_margin_engine_batch.py setup              # check + sheet, proposes nothing
  python3 scripts/ops/propose_margin_engine_batch.py setup --propose
  python3 scripts/ops/propose_margin_engine_batch.py enable             # gates + sheet
  python3 scripts/ops/propose_margin_engine_batch.py enable --propose
  python3 scripts/ops/propose_margin_engine_batch.py pool-withdraw --asset cash --amount 250000000 --recipient 0x...
  python3 scripts/ops/propose_margin_engine_batch.py --self-test
  python3 scripts/ops/propose_margin_engine_batch.py enable --local --dir deployments/31337 --json
                                                                 # a fork (31337): never proposes
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_feed_staleness import feed_age  # noqa: E402
from check_perp_pager import (  # noqa: E402  one implementation of the reserve and coverage rules
  future_reserve_target_cngn,
  read_one_side_usd,
  read_perp_im,
  sm_required_usd,
)
from propose_cngn_spot_batch import (  # noqa: E402  one implementation of the MPCVault transport
  CONFIRM_POLL_SEC,
  CONFIRM_TIMEOUT_SEC,
  EXPECTED_VAULT,
  confirm_on_chain,
  load_env_file,
  propose,
  request_tx_hash,
  rpc,
)
from propose_perp_enable_batch import gate_pager  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
NAME = "MARGIN_ENGINE"
FILES = {"setup": f"{NAME}_VAULT_ACTIONS.json", "enable": f"{NAME}_ENABLE_VAULT_ACTIONS.json"}
FEED_MAX_AGE_SEC = 600
MARK_MAX_AGE_SEC = 2 * 3600  # FORWARD_MARK_LATE_MS: an hourly pull, one missed
SUB_ACCOUNTS = "0x7019244E25FA416e6Ca2ed2F3cA25277aef72843"

# `cast sig` of each, pinned in --self-test
SIGNATURES = {
  "acceptOwnership": "acceptOwnership()",
  "owner": "owner()",
  "pendingOwner": "pendingOwner()",
  "setWhitelistManager": "setWhitelistManager(address,bool)",
  "whitelistedManager": "whitelistedManager(address)",
  "managerWhitelisted": "managerWhitelisted(address)",
  "setTotalPositionCap": "setTotalPositionCap(address,uint256)",
  "totalPositionCap": "totalPositionCap(address)",
  "totalPosition": "totalPosition(address)",
  "setDatedFutureAsset": "setDatedFutureAsset(address,bool)",
  "isDatedFutureAsset": "isDatedFutureAsset(address)",
  "futureContracts": "futureContracts(uint256)",
  "contractSize": "contractSize()",
  "futureMarginRequirements": "futureMarginRequirements(uint256)",
  "setGuardian": "setGuardian(address)",
  "withdrawFromPool": "withdrawFromPool(address,uint256,address)",
  "wrappedAsset": "wrappedAsset()",
  "decimals": "decimals()",
  "guardian": "guardian()",
  "getBalance": "getBalance(uint256,address,uint256)",
  "getSpot": "getSpot()",
}
PINNED = {
  "acceptOwnership": "0x79ba5097", "owner": "0x8da5cb5b", "pendingOwner": "0xe30c3978",
  "setWhitelistManager": "0xe64cc9da", "whitelistedManager": "0x97d51c04", "managerWhitelisted": "0x9c7105d1",
  "setTotalPositionCap": "0x40a557bd", "totalPositionCap": "0x745ab570", "totalPosition": "0xa9578774",
  "setDatedFutureAsset": "0x0ddd8a04", "isDatedFutureAsset": "0x761822ef", "futureContracts": "0xc3c74b34",
  "contractSize": "0x3d7cc610", "futureMarginRequirements": "0x84033e5e", "getBalance": "0x0806e640",
  "getSpot": "0x2b37269c", "setGuardian": "0x8a0dac4a", "guardian": "0x452a9320",
  "withdrawFromPool": "0xfac95a9e", "wrappedAsset": "0xd9a1836a", "decimals": "0x313ce567",
}


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


def word_address(address: str) -> str:
  return "0" * 24 + address.lower().removeprefix("0x")


def word_uint(value: int) -> str:
  return format(value, "064x")


def digest(to: str, data: str) -> str:
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


@dataclass
class Gate:
  name: str
  ok: bool
  detail: str


# ---------------------------------------------------------------------------------------------
# the actions, rebuilt from the deployment artifact
# ---------------------------------------------------------------------------------------------

def owned(d: dict) -> list[str]:
  return [d["manager"], d["viewer"], d["future"], d["forwardFeed"]]


def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as the deploy script writes them."""
  manager = word_address(d["manager"])
  if batch == "setup":
    return [*[(c, selector("acceptOwnership")) for c in owned(d)],
            (d["cash"], selector("setWhitelistManager") + manager + word_uint(1)),
            (d["cngnEscrow"], selector("setWhitelistManager") + manager + word_uint(1)),
            (d["cngnEscrow"], selector("setTotalPositionCap") + manager + word_uint(int(d["engineCngnCap"]))),
            (d["perp"], selector("setWhitelistManager") + manager + word_uint(1)),
            (d["auction"], selector("setWhitelistManager") + manager + word_uint(1)),
            (d["manager"], selector("setGuardian") + word_address(d["guardian"]))]
  return [(d["perp"], selector("setTotalPositionCap") + manager + word_uint(int(d["perpOICap"]))),
          (d["future"], selector("setTotalPositionCap") + manager + word_uint(int(d["futureOICap"]))),
          (d["perpTradeModule"], selector("setDatedFutureAsset") + word_address(d["future"]) + word_uint(1))]


def verify_actions(batch: str, d: dict, actions: list[dict]) -> None:
  """Refuses a file that is not exactly what the deployment implies: a wrong target, manager, cap,
  value or digest, or an action added, dropped or reordered."""
  want = expected_actions(batch, d)
  if len(actions) != len(want):
    raise SystemExit(f"{batch}: {len(actions)} actions in the file, {len(want)} expected")
  for i, (action, (to, data)) in enumerate(zip(actions, want)):
    if action["to"].lower() != to.lower() or action["data"].lower() != data.lower():
      raise SystemExit(f"{batch} action {i} ({action.get('description')}) is not what the deployment implies")
    if str(action.get("value", "0")) != "0":
      raise SystemExit(f"{batch} action {i} carries value")
    if action["digest"].lower() != digest(to, data).lower():
      raise SystemExit(f"{batch} action {i}: digest {action['digest']} does not match its own to and data")


# ---------------------------------------------------------------------------------------------
# chain reads
# ---------------------------------------------------------------------------------------------

class Chain:
  def __init__(self, url: str):
    self.url = url

  def call(self, to: str, data: str) -> str:
    return rpc(self.url, "eth_call", [{"to": to, "data": data}, "latest"]).removeprefix("0x")

  def word(self, to: str, data: str, index: int = 0) -> int:
    return int(self.call(to, data)[index * 64:(index + 1) * 64], 16)

  def address(self, to: str, name: str) -> str:
    return "0x" + self.call(to, selector(name))[24:64]

  def balance(self, account: int, asset: str) -> int:
    value = self.word(SUB_ACCOUNTS, selector("getBalance") + word_uint(account) + word_address(asset) + word_uint(0))
    return value - (1 << 256) if value >= 1 << 255 else value

  def head(self) -> int:
    return int(rpc(self.url, "eth_getBlockByNumber", ["latest", False])["timestamp"], 16)


def landed(chain: Chain, batch: str, d: dict, i: int, vault: str) -> bool:
  """Whether action i's postcondition already holds."""
  m = word_address(d["manager"])
  if batch == "setup":
    if i < 4:
      return chain.address(owned(d)[i], "owner").lower() == vault.lower()
    return [
      lambda: chain.word(d["cash"], selector("whitelistedManager") + m) == 1,
      lambda: chain.word(d["cngnEscrow"], selector("whitelistedManager") + m) == 1,
      lambda: chain.word(d["cngnEscrow"], selector("totalPositionCap") + m) == int(d["engineCngnCap"]),
      lambda: chain.word(d["perp"], selector("whitelistedManager") + m) == 1,
      lambda: chain.word(d["auction"], selector("managerWhitelisted") + m) == 1,
      lambda: chain.address(d["manager"], "guardian").lower() == d["guardian"].lower(),
    ][i - 4]()
  return [
    lambda: chain.word(d["perp"], selector("totalPositionCap") + m) == int(d["perpOICap"]),
    lambda: chain.word(d["future"], selector("totalPositionCap") + m) == int(d["futureOICap"]),
    lambda: chain.word(d["perpTradeModule"], selector("isDatedFutureAsset") + word_address(d["future"])) == 1,
  ][i]()


# ---------------------------------------------------------------------------------------------
# gates
# ---------------------------------------------------------------------------------------------

def gate_setup(chain: Chain, d: dict, vault: str) -> list[Gate]:
  """Before setup: each of the four is nominated to the vault (or already accepted), and the vault owns
  what it is about to wire."""
  pending = [c for c in owned(d)
             if chain.address(c, "owner").lower() != vault.lower() and chain.address(c, "pendingOwner").lower() != vault.lower()]
  reused = [c for c in (d["cash"], d["cngnEscrow"], d["perp"], d["auction"])
            if chain.address(c, "owner").lower() != vault.lower()]
  return [
    Gate("nominated", not pending, f"not nominated to the vault: {', '.join(pending)}" if pending else "all four nominated to or owned by the vault"),
    Gate("reused", not reused, f"vault does not own {', '.join(reused)}" if reused else "vault owns the perp cash, escrow, perp and auction"),
  ]


def reserve_gate(pool_cngn: float, target: float) -> Gate:
  if target <= 0:
    return Gate("reserve", False, "reserve target is zero (index unreadable?)")
  if pool_cngn < target:
    return Gate("reserve", False, f"VM pool holds {pool_cngn:,.0f} cNGN, under its {target:,.0f} reserve: seed the pool account before opening")
  return Gate("reserve", True, f"VM pool holds {pool_cngn:,.0f} cNGN (reserve {target:,.0f})")


def escrow_gate(used: float, cap: float, target: float) -> Gate:
  headroom = cap - used
  if headroom < target:
    return Gate("escrow", False, f"escrow cap {cap:,.0f} cNGN, {used:,.0f} used: {headroom:,.0f} left, under one reserve ({target:,.0f}); a top-up would revert")
  return Gate("escrow", True, f"escrow cap {cap:,.0f} cNGN, {used:,.0f} used, {headroom:,.0f} left")


def sm_gate(sm_cash: float, books: dict[str, tuple[float, float]]) -> Gate:
  required = sm_required_usd(list(books.values()))
  parts = ", ".join(f"{n} one side ${o:,.0f} at IM {im * 100:.0f}%" for n, (o, im) in books.items())
  if sm_cash < required:
    return Gate("sm", False, f"SecurityModule ${sm_cash:,.0f} is under the ${required:,.0f} a 25% step costs across {parts}: fund it, or open a lower cap")
  return Gate("sm", True, f"SecurityModule ${sm_cash:,.0f} covers ${required:,.0f} across {parts}")


def gate_enable(chain: Chain, d: dict, stack: dict, vault: str) -> list[Gate]:
  gates: list[Gate] = []
  m = word_address(d["manager"])

  not_owned = [c for c in owned(d) if chain.address(c, "owner").lower() != vault.lower()]
  unwired = [i for i in range(4, 10) if not landed(chain, "setup", d, i, vault)]
  perp_cap = chain.word(d["perp"], selector("totalPositionCap") + m)
  cap = chain.word(d["future"], selector("totalPositionCap") + m)
  registered = chain.word(d["perpTradeModule"], selector("isDatedFutureAsset") + word_address(d["future"]))
  problems = ([f"vault does not own {', '.join(not_owned)}"] if not_owned else []) + \
             ([f"setup actions {unwired} have not landed"] if unwired else []) + \
             ([f"engine is not closed (perp cap {perp_cap}, future cap {cap}, registered {bool(registered)})"]
              if perp_cap or cap or registered else [])
  gates.append(Gate("custody", not problems, "; ".join(problems) or "vault owns all four; setup landed; engine closed"))

  try:
    age, _ = feed_age(chain.url, d["indexFeed"])
    spot = chain.word(d["indexFeed"], selector("getSpot")) / 1e18
    gates.append(Gate("feeds", age <= FEED_MAX_AGE_SEC, f"index {age}s old (limit {FEED_MAX_AGE_SEC}s)"))
  except Exception as exc:  # noqa: BLE001 -- unreadable is a failed gate
    spot = 0.0
    gates.append(Gate("feeds", False, f"index unreadable: {str(exc)[:80]}"))

  last_mark = chain.word(d["future"], selector("futureContracts") + word_uint(int(d["subId"])), 4)
  mark_age = chain.head() - last_mark
  gates.append(Gate("marks", mark_age <= MARK_MAX_AGE_SEC,
                    f"last mark {mark_age}s ago (limit {MARK_MAX_AGE_SEC}s){'' if mark_age <= MARK_MAX_AGE_SEC else ': is the keeper publishing?'}"))

  size = chain.word(d["future"], selector("contractSize")) / 1e18
  oi_cap = int(d["futureOICap"]) / 1e18
  target = future_reserve_target_cngn(oi_cap, size, spot)
  pool_cngn = chain.balance(int(d["poolAccount"]), d["cngnEscrow"]) / 1e18
  gates.append(reserve_gate(pool_cngn, target))
  used = chain.word(d["cngnEscrow"], selector("totalPosition") + m) / 1e18
  escrow_cap = chain.word(d["cngnEscrow"], selector("totalPositionCap") + m) / 1e18
  gates.append(escrow_gate(used, escrow_cap, target))

  try:
    sm_cash = chain.balance(int(stack["securityModuleAccount"]), stack["cash"]) / 1e18
    future_im = chain.word(d["manager"], selector("futureMarginRequirements") + word_uint(int(d["marketId"])), 1) / 1e18
    books = {"perp": (read_one_side_usd(chain.url, stack), read_perp_im(chain.url, stack)),
             "future at the cap": (oi_cap / 2 * size, future_im)}
    gates.append(sm_gate(sm_cash, books))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("sm", False, f"SecurityModule coverage unreadable: {str(exc)[:80]}"))

  gates.append(gate_pager(Path(os.environ.get("PAGER_STATE_FILE", Path.home() / ".numo-perp-pager.json"))))
  return gates


def report(gates: list[Gate]) -> bool:
  print()
  for g in gates:
    print(f"  [{'PASS' if g.ok else 'FAIL'}] {g.name:<9} {g.detail}")
  return all(g.ok for g in gates)


# ---------------------------------------------------------------------------------------------
# pool withdrawals
# ---------------------------------------------------------------------------------------------

def withdraw_action(d: dict, kind: str, amount: int, recipient: str) -> dict:
  """engine.withdrawFromPool(asset, amount, recipient): `amount` in the token's own units."""
  asset = d["cngnEscrow"] if kind == "cngn" else d["cash"]
  data = selector("withdrawFromPool") + word_address(asset) + word_uint(amount) + word_address(recipient)
  return {"description": f"engine.withdrawFromPool({kind}, {amount}, {recipient}) [out of the VM pool]",
          "to": d["manager"], "value": "0", "data": data, "digest": digest(d["manager"], data)}


def withdraw_gate(held18: int, amount18: int, floor18: int, kind: str) -> Gate:
  """The pool must keep `floor18` (18dp) after the withdrawal: its reserve target in cNGN, or 0 in cash."""
  after = held18 - amount18
  what = "its cNGN reserve target" if kind == "cngn" else "zero cash"
  if amount18 <= 0:
    return Gate("withdraw", False, "nothing to withdraw")
  if after < floor18:
    return Gate("withdraw", False, f"leaves the pool at {after / 1e18:,.2f} {kind}, under {what} ({floor18 / 1e18:,.2f})")
  return Gate("withdraw", True, f"leaves the pool at {after / 1e18:,.2f} {kind} (floor {floor18 / 1e18:,.2f}, {what})")


def gate_pool_withdraw(chain: Chain, d: dict, kind: str, amount: int, recipient: str, vault: str) -> list[Gate]:
  gates = [Gate("custody", chain.address(d["manager"], "owner").lower() == vault.lower(), "vault owns the engine")]
  if int(recipient, 16) == 0 or recipient.lower() == d["manager"].lower():
    gates.append(Gate("recipient", False, f"recipient {recipient} is zero or the engine"))
  asset = d["cngnEscrow"] if kind == "cngn" else d["cash"]
  token = chain.address(asset, "wrappedAsset")
  decimals = chain.word(token, selector("decimals"))
  amount18 = amount * 10 ** (18 - decimals)
  held18 = chain.balance(int(d["poolAccount"]), asset)
  if kind == "cngn":
    spot = chain.word(d["indexFeed"], selector("getSpot")) / 1e18
    size = chain.word(d["future"], selector("contractSize")) / 1e18
    m = word_address(d["manager"])
    cap = chain.word(d["future"], selector("totalPositionCap") + m) / 1e18
    floor18 = int(future_reserve_target_cngn(cap, size, spot) * 1e18)
  else:
    floor18 = 0
  gates.append(withdraw_gate(held18, amount18, floor18, kind))
  return gates


# ---------------------------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------------------------

def self_test() -> int:
  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"
  for name, want in PINNED.items():
    assert selector(name) == want, f"{name}: {selector(name)} != {want}"
  assert set(PINNED) == set(SIGNATURES), "every signature pinned"

  # A deployment, its batches as the deploy script writes them, and each way a file can be wrong.
  a = lambda n: "0x" + format(n, "040x")  # noqa: E731
  d = {"manager": a(1), "viewer": a(2), "future": a(3), "forwardFeed": a(4), "cash": a(5), "cngnEscrow": a(6),
       "auction": a(7), "perpTradeModule": a(8), "perp": a(9), "guardian": a(10),
       "engineCngnCap": str(100_000_000 * 10**18), "futureOICap": str(30 * 10**18), "perpOICap": str(50_000_000 * 10**18)}
  for batch in ("setup", "enable"):
    good = [{"description": str(i), "to": to, "value": "0", "data": data, "digest": digest(to, data)}
            for i, (to, data) in enumerate(expected_actions(batch, d))]
    verify_actions(batch, d, good)
    broken = {
      "target": lambda acts: acts[0].update(to=a(99)),
      "calldata": lambda acts: acts[-1].update(data=acts[-1]["data"][:-1] + "0"),
      "value": lambda acts: acts[0].update(value="1"),
      "digest": lambda acts: acts[0].update(digest="0x" + "00" * 32),
      "dropped": lambda acts: acts.pop(),
      "reordered": lambda acts: acts.reverse(),
    }
    for what, mutate in broken.items():
      acts = json.loads(json.dumps(good))
      mutate(acts)
      try:
        verify_actions(batch, d, acts)
      except SystemExit:
        continue
      raise AssertionError(f"{batch}: a wrong {what} was accepted")
  # The cap in the escrow action is the artifact's, and the OI cap in the enable action likewise.
  assert expected_actions("setup", d)[6][1].endswith(word_uint(100_000_000 * 10**18))
  assert expected_actions("setup", d)[-1] == (a(1), selector("setGuardian") + word_address(a(10)))
  assert expected_actions("enable", d)[0][1].endswith(word_uint(50_000_000 * 10**18))
  assert expected_actions("enable", d)[1][1].endswith(word_uint(30 * 10**18))
  # The digest convention: keccak(to || keccak(data)), checked on a known action.
  assert digest(a(1), selector("acceptOwnership")) == "0x" + keccak(bytes.fromhex(a(1)[2:]) + keccak(bytes.fromhex("79ba5097"))).hex()

  # Gates: the reserve, the escrow headroom after it, and coverage across both books.
  target = future_reserve_target_cngn(30, 1_000, 1 / 1_363.7)
  assert not reserve_gate(0, target).ok and not reserve_gate(target - 1, target).ok and reserve_gate(target, target).ok
  assert not reserve_gate(1, 0).ok
  assert escrow_gate(target, 50_000_000, target).ok
  assert not escrow_gate(50_000_000 - target + 1, 50_000_000, target).ok
  # a full cNGN-margined book (~20.5M) beside the reserve: a 30M cap has under a reserve left, 50M has plenty
  assert not escrow_gate(20_500_000 + target, 30_000_000, target).ok
  assert escrow_gate(20_500_000 + target, 50_000_000, target).ok
  # The launch cap is sized to the module as it stands: $3,250 covers the perp's $134 and a $15,000 futures
  # side at IM 25% ($2,812.50), $2,947 in all. A 40-contract cap ($20,000 a side, $3,884 in all) is refused.
  assert sm_gate(3_250, {"perp": (801, 1 / 3)}).ok
  assert sm_gate(3_250, {"perp": (801, 1 / 3), "future at the cap": (15_000, 0.25)}).ok
  assert not sm_gate(3_250, {"perp": (801, 1 / 3), "future at the cap": (20_000, 0.25)}).ok
  assert sm_gate(3_900, {"perp": (801, 1 / 3), "future at the cap": (20_000, 0.25)}).ok
  # Pool withdrawals: the action is withdrawFromPool on the engine; cNGN keeps the reserve, cash keeps zero.
  w = withdraw_action(d, "cash", 250 * 10**6, a(11))
  assert w["to"] == d["manager"] and w["data"] == selector("withdrawFromPool") + word_address(d["cash"]) + word_uint(250 * 10**6) + word_address(a(11))
  assert withdraw_action(d, "cngn", 1, a(11))["data"].startswith(selector("withdrawFromPool") + word_address(d["cngnEscrow"]))
  reserve = int(6_000_000 * 1e18)
  assert withdraw_gate(int(7_000_000 * 1e18), int(1_000_000 * 1e18), reserve, "cngn").ok, "down to the reserve exactly"
  assert not withdraw_gate(int(7_000_000 * 1e18), int(1_000_001 * 1e18), reserve, "cngn").ok, "one cNGN under it"
  assert withdraw_gate(300 * 10**18, 300 * 10**18, 0, "cash").ok, "the pool's cash down to zero"
  assert not withdraw_gate(300 * 10**18, 301 * 10**18, 0, "cash").ok, "never below zero"
  assert not withdraw_gate(-50 * 10**18, 1, 0, "cash").ok, "nothing out of a negative pool"
  assert not withdraw_gate(100, 0, 0, "cash").ok, "a zero withdrawal is refused"
  with tempfile.TemporaryDirectory() as tmp:
    os.environ["PAGER_STATE_FILE"] = str(Path(tmp) / "none.json")
    assert not gate_pager(Path(os.environ["PAGER_STATE_FILE"])).ok
    os.environ.pop("PAGER_STATE_FILE")
  print("self-test ok: selectors match their `cast sig` values; a wrong target, calldata, value, digest, "
        "count or order is refused; reserve, escrow and coverage gates sized")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the cNGN future's vault batches")
  ap.add_argument("batch", nargs="?", choices=("setup", "enable", "pool-withdraw"))
  ap.add_argument("--asset", choices=("cngn", "cash"), help="pool-withdraw: which balance")
  ap.add_argument("--amount", type=int, help="pool-withdraw: in the token's own units (USDC and cNGN: 6dp)")
  ap.add_argument("--recipient", help="pool-withdraw: where the tokens go")
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--local", action="store_true", help="a fork (chain 31337) only; never proposes")
  ap.add_argument("--dir", type=Path, default=ROOT / "deployments" / "8453", help="where the deploy wrote its artifacts")
  ap.add_argument("--stack", type=Path, default=ROOT / "deployments" / "8453" / "CNGN_PERP_STACK.json")
  ap.add_argument("--json", action="store_true", help="print the gates as JSON on the last line")
  args = ap.parse_args()

  if args.self_test:
    return self_test()
  if not args.batch:
    ap.error("name a batch: setup or enable")

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  load_env_file(Path("/etc/numo/perp-pager.env"))
  rpc_url = os.environ.get("RPC_URL") or os.environ.get("BASE_RPC_URL", "")
  if not rpc_url:
    raise SystemExit("RPC_URL (or BASE_RPC_URL) is required")
  chain_id = int(rpc(rpc_url, "eth_chainId", []), 16)
  if args.local and (chain_id != 31337 or args.propose):
    raise SystemExit("--local is for a fork (31337) and never proposes")
  if not args.local and chain_id != 8453:
    raise SystemExit(f"expected Base mainnet (8453), got chain {chain_id}; use --local for a fork")
  vault = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault} is not the recorded vault {EXPECTED_VAULT}")

  d = json.loads((args.dir / f"{NAME}.json").read_text())
  if args.batch == "pool-withdraw":
    return run_pool_withdraw(args, d, Chain(rpc_url), rpc_url, vault)
  actions = json.loads((args.dir / FILES[args.batch]).read_text())
  verify_actions(args.batch, d, actions)
  stack = json.loads(args.stack.read_text())
  chain = Chain(rpc_url)

  def gates() -> list[Gate]:
    return gate_setup(chain, d, vault) if args.batch == "setup" else gate_enable(chain, d, stack, vault)

  current = gates()
  passed = report(current)
  done = [landed(chain, args.batch, d, i, vault) for i in range(len(actions))]
  print()
  for i, a in enumerate(actions):
    print(f"  {i}  {'landed ' if done[i] else 'pending'}  {a['to']}  {a['digest']}  {a['description']}")
  if args.json:
    print(json.dumps({"gates": [asdict(g) for g in current], "landed": done}))
  if all(done):
    print(f"\n{args.batch}: every action has landed; nothing to propose.")
    return 0
  if not passed:
    print("\nGATES FAILED: nothing proposed.")
    return 1
  if not args.propose:
    print("\ndry run: nothing proposed. Re-run with --propose; compare each digest with MPCVault before approving.")
    return 0

  token, vault_uuid = os.environ.get("MPCVAULT_TOKEN", ""), os.environ.get("MPCVAULT_VAULT", "")
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh on the ops box)")
  for i, a in enumerate(actions):
    if landed(chain, args.batch, d, i, vault):
      print(f"  [{i}] already landed, skipped: {a['description']}")
      continue
    # Re-read before each: an approval can take a while, and a feed, keeper or pager that died in the
    # meantime must stop the rest. Between the two enable actions the cap is raised, so custody is
    # expected to fail there on "market is not closed"; every other gate must still hold.
    if i > 0:
      again = [g for g in gates() if not (args.batch == "enable" and g.name == "custody")]
      if not report(again):
        raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    uuid = propose(token, vault_uuid, vault, a)
    print(f"  [{i}] proposed uuid={uuid}\n       {a['description']}\n       digest {a['digest']}\n       -> approve in MPCVault now")
    deadline, tx_hash = time.time() + CONFIRM_TIMEOUT_SEC, None
    while time.time() < deadline and not tx_hash:
      time.sleep(CONFIRM_POLL_SEC)
      tx_hash = request_tx_hash(token, uuid)
    if not tx_hash:
      raise SystemExit(f"action {i} not approved within the timeout")
    confirm_on_chain(rpc_url, tx_hash)
    if not landed(chain, args.batch, d, i, vault):
      raise SystemExit(f"action {i} mined but its postcondition does not hold: stop and investigate")
  print(f"\n{args.batch}: done." + (" The future is open: markets-service can list it." if args.batch == "enable" else ""))
  return 0


def run_pool_withdraw(args, d: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  if not (args.asset and args.amount is not None and args.recipient):
    raise SystemExit("pool-withdraw needs --asset, --amount and --recipient")
  if args.amount <= 0:
    raise SystemExit(f"--amount must be a positive number of token units, got {args.amount}")
  if not (args.recipient.startswith("0x") and len(args.recipient) == 42):
    raise SystemExit(f"--recipient {args.recipient} is not an address")
  action = withdraw_action(d, args.asset, args.amount, args.recipient)
  gates = gate_pool_withdraw(chain, d, args.asset, args.amount, args.recipient, vault)
  passed = report(gates)
  print(f"\n  {action['to']}  {action['digest']}  {action['description']}")
  if args.json:
    print(json.dumps({"gates": [asdict(g) for g in gates], "landed": [False]}))
  if not passed:
    print("\nGATES FAILED: nothing proposed.")
    return 1
  if not args.propose:
    print("\ndry run: nothing proposed. Re-run with --propose; compare the digest with MPCVault before approving.")
    return 0
  token, vault_uuid = os.environ.get("MPCVAULT_TOKEN", ""), os.environ.get("MPCVAULT_VAULT", "")
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh on the ops box)")
  uuid = propose(token, vault_uuid, vault, action)
  print(f"  proposed uuid={uuid}\n       {action['description']}\n       digest {action['digest']}\n       -> approve in MPCVault now")
  deadline, tx_hash = time.time() + CONFIRM_TIMEOUT_SEC, None
  while time.time() < deadline and not tx_hash:
    time.sleep(CONFIRM_POLL_SEC)
    tx_hash = request_tx_hash(token, uuid)
  if not tx_hash:
    raise SystemExit("not approved within the timeout")
  confirm_on_chain(rpc_url, tx_hash)
  print("pool-withdraw: done.")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
