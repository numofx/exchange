#!/usr/bin/env python3
"""Propose the EURC-30NOV26 v3 series' vault batches on MarginEngine v2 (docs/eurc-usdc-futures-spec.md, A1.2, A3).

  eurc-v3-setup   EURC_FUTURE_V3_VAULT_ACTIONS.json, from deploy-eurc-future-v3.s.sol: accept the future and its
                  forward feed, list the future on market 2 (whitelistAsset(future, 2, Future)), REPLACING the retired
                  v2 EURC-30NOV26 in the market's one future slot, and set market 2's futures margin. Opens nothing.
  eurc-v3-enable  EURC_FUTURE_V3_ENABLE_VAULT_ACTIONS.json: the future's cap under v2, then the future on the
                  TradeModule.

Every action is rebuilt here from EURC_FUTURE_V3.json and must match the file exactly (to, calldata, value), digest
recomputed (keccak(to || keccak(data))). An action whose postcondition already holds is skipped. Gates are re-read
before every action.

Setup gates (all read live, all required):
  nominated  the future and the forward feed are nominated to (or owned by) the vault
  engine     the vault owns v2; v2 lists exactly NGN and EUR; EUR lists no perp; EUR's future is the retired v2 series
             (or already this one)
  slot       the retired series is empty: open interest 0, cap 0, off the TradeModule, and no account with VM pending
             on its series (every account scanned). whitelistAsset de-lists it, so an account still holding it, or owed
             VM on it, would be cut off. Re-read immediately before the whitelistAsset action.
  series     no other market lists this expiry: one subId on two futures couples their close-outs
  parity     the adapter, index feed, future and forward feed as deployed; the deployer has sent nothing unaudited;
             the canary series (spec A1.4), if deployed, listed on its own short fixing params and settling before
             the production series' window opens

Enable gates (all read live, all required unless marked):
  custody    the vault owns both; setup has landed; the future is closed (cap 0, not on the TradeModule)
  engine     as at setup, and EUR's future is this one
  series     as at setup
  index      EurcIndexFeed answers: both streams' reports are within indexMaxAge, so the v3 keeper is posting
  marks      the future was marked within 2h and its mark sits inside the index band: the forward publisher runs
  oi-cap     the artifact's cap is no more than the latest A6.0a measurement allows (OI_CAP_LIMIT, with its date), or is
             UNCAPPED, the owner's recorded decision (OI_UNCAPPED_DECIDED). Uncapped, sm and keeper still hold for
             cNGN-30NOV26 at its cap, and sm-capacity / keeper-capacity report how many EURC contracts each covers;
             the pager pages when open interest passes them (sm-coverage, keeper-capacity-v2)
  sm, gaps   SecurityModule cover, as for the v2 series (gaps informational)
  pager      the pager's last run read this future
  keeper     v2's liquidation keeper reports this future, with the floor for one side of each series at its cap
  fills      markets-service lists (asset_address, sub_id) as EURC-30NOV26 with the chain's fill band
  rfq        the RfqModule is not on the TradeModule's Matching
  parity     as at setup, and EUR's future and margin as set

It NEVER signs, executes or broadcasts. Without --propose it prints the gates and the sheet. With --propose each action
goes to the MPCVault app for a human to approve, one at a time, from the vault, through perp_cap_guard.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.

  python3 scripts/ops/propose_eurc_future_v3_batch.py eurc-v3-setup             # check + sheet, proposes nothing
  python3 scripts/ops/propose_eurc_future_v3_batch.py eurc-v3-setup --propose
  python3 scripts/ops/propose_eurc_future_v3_batch.py eurc-v3-enable
  python3 scripts/ops/propose_eurc_future_v3_batch.py --self-test
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import propose_eurc_future_v2_batch as e2  # noqa: E402  the v2 EURC series' proposer: shared gates and the retire reads
import propose_margin_engine_v2_batch as v2p  # noqa: E402
from perp_cap_guard import opens_a_perp_cap  # noqa: E402
from propose_cngn_spot_batch import EXPECTED_VAULT, gates_after_mining, load_env_file, rpc  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

v1p = v2p.v1p
Gate, Chain, report = v1p.Gate, v1p.Chain, v1p.report
word_address, word_uint, digest = v1p.word_address, v1p.word_uint, v1p.digest

ROOT = v1p.ROOT
NAME = "EURC_FUTURE_V3"
RETIRED_NAME = "EURC_FUTURE_V2"
ENGINE_NAME = v2p.NAME
SETUP, ENABLE = "eurc-v3-setup", "eurc-v3-enable"
FILES = {SETUP: f"{NAME}_VAULT_ACTIONS.json", ENABLE: f"{NAME}_ENABLE_VAULT_ACTIONS.json"}
MARKET_ID = e2.MARKET_ID
FUTURE, PERP = v2p.FUTURE, v2p.PERP
MARK_MAX_AGE_SEC = e2.MARK_MAX_AGE_SEC
# The latest A6.0a measurement (docs/eurc-usdc-futures-spec.md): Base-only, 2% sell depth 10,665 EURC on 2026-11-15
# allows a cap of 4 contracts (both sides). Raise it only with a newer measurement recorded in the spec.
OI_CAP_LIMIT = 4 * 10**18
OI_CAP_MEASURED = "2026-11-15 (A6.0a measurement 1)"
# No cap at all: setTotalPositionCap(engine, type(uint256).max). Accepted only because it is recorded here and in the spec.
UNCAPPED = 2**256 - 1
OI_UNCAPPED_DECIDED = ("2026-11-15: the owner chose no OI cap, accepting index-manipulation, SecurityModule and keeper "
                       "risk beyond what they hold (spec A6.0a)")
# The Data Streams verifier proxy and feeds the adapter must use (spec A2.1)
VERIFIER_PROXY = "0xDE1A28D87Afd0f546505B28AB50410A5c3a7387a"
EURC_USD_FEED = 0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb
USDC_USD_FEED = 0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992

SIGNATURES = {**e2.SIGNATURES, "adapter": "adapter()", "verifierProxy": "verifierProxy()", "baseFeedId": "baseFeedId()",
              "quoteFeedId": "quoteFeedId()", "indexMaxAge": "indexMaxAge()", "feedTimelock": "feedTimelock()",
              "recoveryDelay": "recoveryDelay()", "seriesFixing": "seriesFixing(uint256)"}
PINNED = {**e2.PINNED, "adapter": "0x03eadcfc", "verifierProxy": "0x47f77bc0", "baseFeedId": "0x99b447af",
          "quoteFeedId": "0x05cdccbf", "indexMaxAge": "0xf1edb35b", "feedTimelock": "0x5258a69d",
          "recoveryDelay": "0x3758ca7a", "seriesFixing": "0x066f2a37"}


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


def owned(d: dict) -> list[str]:
  return [d["future"], d["forwardFeed"]]


# ---------------------------------------------------------------------------------------------
# the artifact batches
# ---------------------------------------------------------------------------------------------

def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as deploy-eurc-future-v3.s.sol writes them."""
  m = word_address(d["manager"])
  if batch == SETUP:
    return [*[(c, selector("acceptOwnership")) for c in owned(d)],
            (d["manager"], selector("whitelistAsset") + word_address(d["future"]) + word_uint(MARKET_ID) + word_uint(FUTURE)),
            (d["manager"], selector("setFutureMarginRequirements") + word_uint(MARKET_ID)
             + word_uint(int(d["futureMMReq"])) + word_uint(int(d["futureIMReq"])))]
  # TradeModule first: until it is registered a fill carries no price and skips the band check, and the cap is still 0
  return [(d["tradeModule"], selector("setDatedFutureAsset") + word_address(d["future"]) + word_uint(1)),
          (d["future"], selector("setTotalPositionCap") + m + word_uint(int(d["futureOICap"])))]


# The action whose landing replaces market 2's future: the slot gate is re-read right before it.
REPLACING_ACTION = 2


def postconditions(chain: Chain, batch: str, d: dict, vault: str) -> list:
  m = word_address(d["manager"])
  w = lambda to, name, *args, index=0: chain.word(to, selector(name) + "".join(args), index)  # noqa: E731
  if batch == SETUP:
    return [*[(lambda c=c: chain.address(c, "owner").lower() == vault.lower()) for c in owned(d)],
            lambda: e2.future_on_market(chain, d).lower() == d["future"].lower(),
            lambda: (w(d["manager"], "futureMarginRequirements", word_uint(MARKET_ID), index=0),
                     w(d["manager"], "futureMarginRequirements", word_uint(MARKET_ID), index=1))
            == (int(d["futureMMReq"]), int(d["futureIMReq"]))]
  return [lambda: w(d["future"], "totalPositionCap", m) == int(d["futureOICap"]),
          lambda: w(d["tradeModule"], "isDatedFutureAsset", word_address(d["future"])) == 1]


def verify_actions(batch: str, d: dict, actions: list[dict]) -> None:
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


def check_artifact(d: dict, engine: dict, retired: dict) -> None:
  if d["manager"].lower() != engine["manager"].lower():
    raise SystemExit(f"{NAME}.json names engine {d['manager']}, not {ENGINE_NAME}.json's {engine['manager']}")
  if int(d["marketId"]) != MARKET_ID:
    raise SystemExit(f"{NAME}.json is for market {d['marketId']}, not EUR ({MARKET_ID})")
  if int(d["subId"]) != int(d["expiry"]):
    raise SystemExit(f"{NAME}.json: subId {d['subId']} is not its expiry")
  if d["replaces"].lower() != retired["future"].lower():
    raise SystemExit(f"{NAME}.json replaces {d['replaces']}, not {RETIRED_NAME}.json's {retired['future']}")
  canary = int(d.get("canarySubId", 0))
  if canary and not canary + int(d["canaryRecoveryDelay"]) + int(d["canaryFixingWindow"]) < int(d["lastTradeTime"]):
    raise SystemExit(f"{NAME}.json: canary {canary} does not settle before the production series' last trade")
  if int(d["futureMMReq"]) <= 0 or int(d["futureMMReq"]) > int(d["futureIMReq"]) or int(d["futureIMReq"]) >= 10**18:
    raise SystemExit(f"{NAME}.json: futures margin MM {d['futureMMReq']} / IM {d['futureIMReq']} is not 0 < MM <= IM < 1")


# ---------------------------------------------------------------------------------------------
# gates
# ---------------------------------------------------------------------------------------------

def engine_gate(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  m, problems = d["manager"], []
  if chain.address(m, "owner").lower() != vault.lower():
    problems.append("the vault does not own v2")
  if chain.word(m, selector("lastMarketId")) != 2:
    problems.append("v2 does not list exactly NGN and EUR")
  perp = "0x" + chain.call(m, selector("assetMap") + word_uint(MARKET_ID) + word_uint(PERP))[24:64]
  if int(perp, 16) != 0:
    problems.append("EUR lists a perp")
  listed = e2.future_on_market(chain, d).lower()
  if attached and listed != d["future"].lower():
    problems.append(f"EUR's future is {listed}, not this one: {SETUP} has not landed")
  if not attached and listed not in (d["future"].lower(), d["replaces"].lower()):
    problems.append(f"EUR's future is {listed}: neither the retired series {d['replaces']} nor this one. Stop")
  return Gate("engine", not problems, "; ".join(problems) or "v2 is the vault's, lists NGN and EUR and no perp; EUR's "
              + ("future is this one" if attached else "future is the retired series or this one"))


def slot_verdict(holder: str, retired: str, new: str, oi: int, cap: int, on_module: bool, pending: dict[int, int]) -> Gate:
  """Whether whitelistAsset may replace market 2's future: the holder is empty, or already this one."""
  if holder.lower() == new.lower():
    return Gate("slot", True, "EUR's future is already this one")
  if holder.lower() != retired.lower():
    return Gate("slot", False, f"EUR's future is {holder}, not the retired series {retired}")
  problems = ([f"open interest {oi / 1e18:g}"] if oi else []) + ([f"cap {cap / 1e18:g}"] if cap else []) + \
             (["still on the TradeModule"] if on_module else []) + \
             ([f"VM pending on {len(pending)} account(s): {pending}"] if pending else [])
  return Gate("slot", not problems, "the retired series is " + ("in use: " + "; ".join(problems) if problems else
                                                              "empty: no open interest, cap 0, off the TradeModule, no VM pending"))


def gate_slot(chain: Chain, d: dict, retired: dict) -> Gate:
  try:
    m = word_address(d["manager"])
    return slot_verdict(e2.future_on_market(chain, d), retired["future"], d["future"],
                        e2.open_interest(chain, retired), chain.word(retired["future"], selector("totalPositionCap") + m),
                        chain.word(d["tradeModule"], selector("isDatedFutureAsset") + word_address(retired["future"])) == 1,
                        e2.pending_vm_accounts(chain, retired))
  except Exception as exc:  # noqa: BLE001 -- unreadable holds
    return Gate("slot", False, f"the retired series unreadable: {str(exc)[:120]}")


def canary_expected(d: dict) -> list[tuple[str, int, int]]:
  """The canary series as the artifact records it: (name, field index in its getter, expected), or none."""
  canary = int(d.get("canarySubId", 0))
  if not canary:
    return []
  window = int(d["canaryFixingWindow"])
  return [("futureContracts", 0, 1), ("futureContracts", 2, canary), ("futureContracts", 3, canary - window),
          ("seriesFixing", 0, window), ("seriesFixing", 1, int(d["maxSampleGap"])),
          ("seriesFixing", 2, int(d["canaryRecoveryDelay"]))]


def gate_parity(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  future, feed, index, adapter = d["future"], d["forwardFeed"], d["indexFeed"], d["adapter"]
  w = lambda to, name, *args, index=0: chain.word(to, selector(name) + "".join(args), index)  # noqa: E731
  a = lambda to, name, *args: "0x" + chain.call(to, selector(name) + "".join(args))[24:64]  # noqa: E731
  m = word_address(d["manager"])
  s = word_uint(int(d["subId"]))
  pairs: list[tuple[str, object, object]] = [
    ("adapter verifier", a(adapter, "verifierProxy").lower(), VERIFIER_PROXY.lower()),
    ("adapter base feed", w(adapter, "baseFeedId"), EURC_USD_FEED),
    ("adapter quote feed", w(adapter, "quoteFeedId"), USDC_USD_FEED),
    ("index feed's adapter", a(index, "adapter"), adapter),
    ("index max age", w(index, "indexMaxAge"), int(d["indexMaxAge"])),
    ("contract size", w(future, "contractSize"), int(d["contractSize"])),
    ("future index", a(future, "indexFeed"), index),
    ("feed timelock", w(future, "feedTimelock"), int(d["feedTimelock"])),
    ("recovery delay", w(future, "recoveryDelay"), int(d["recoveryDelay"])),
    ("future forward feed", a(future, "forwardFeed"), feed),
    ("forward feed's index", a(feed, "spotFeed"), index),
    ("forward signer", w(feed, "isSigner", word_address(d["forwardSigner"])), 1),
    ("forward quorum", w(feed, "requiredSigners"), 1),
    ("forward heartbeat", w(feed, "heartbeat"), int(d["forwardHeartbeat"])),
    ("future whitelists v2", w(future, "whitelistedManager", m), 1),
    ("series listed", w(future, "futureContracts", s), 1),
    ("series expiry", w(future, "futureContracts", s, index=2), int(d["expiry"])),
    ("series last trade", w(future, "futureContracts", s, index=3), int(d["lastTradeTime"])),
    # what the fixing actually runs on: the series' own copy, fixed at listing (the defaults below are for new series)
    ("series fixing window", w(future, "seriesFixing", s, index=0), int(d["fixingWindow"])),
    ("series sample gap", w(future, "seriesFixing", s, index=1), int(d["maxSampleGap"])),
    ("series recovery delay", w(future, "seriesFixing", s, index=2), int(d["recoveryDelay"])),
    *[(f"canary {name}[{i}]", w(future, name, word_uint(int(d["canarySubId"])), index=i), want)
      for name, i, want in canary_expected(d)],
    # the reverting index is never the market's spot feed (spec A2.3): margin checks would stop
    ("EUR's spot feed is not the index", a(d["manager"], "getMarketFeeds", word_uint(MARKET_ID)).lower() != index.lower(), True),
  ]
  for name in ("maxMarkDeviation", "maxMarkDelay", "maxMarkIndexDeviation", "minMarkIndexDeviation", "bandNarrowingPeriod",
               "fixingWindow", "maxSampleGap", "minMarkInterval"):
    pairs.append((f"future {name}", w(future, name), int(d[name])))
  if attached:
    mk = word_uint(MARKET_ID)
    pairs += [("EUR's future", e2.future_on_market(chain, d), future),
              ("EUR futures MM", w(d["manager"], "futureMarginRequirements", mk, index=0), int(d["futureMMReq"])),
              ("EUR futures IM", w(d["manager"], "futureMarginRequirements", mk, index=1), int(d["futureIMReq"]))]
  deployer = d["deployer"]
  pairs += [("deployer transactions since the deploy, unaudited",
             v2p.unaudited_deployer_txs(chain.url, deployer, int(d["deployerNonce"])), 0),
            ("deployer signs the forward", w(feed, "isSigner", word_address(deployer)), 0)]
  for c in owned(d):
    holder = a(c, "owner").lower() if attached else (a(c, "owner").lower(), a(c, "pendingOwner").lower())
    pairs.append((f"{c} is the vault's" if attached else f"{c} is nominated to the vault",
                  holder == vault.lower() if attached else vault.lower() in holder, True))
  bad = v1p.parity_mismatches(pairs)
  if bad:
    return Gate("parity", False, f"{len(bad)} setting(s) differ from the deploy: " + "; ".join(bad[:4]))
  return Gate("parity", True, f"all {len(pairs)} settings as deployed; deployer {deployer} has sent nothing unaudited since")


def gate_setup(chain: Chain, d: dict, retired: dict, vault: str) -> list[Gate]:
  pending = [c for c in owned(d) if vault.lower() not in
             (chain.address(c, "owner").lower(), chain.address(c, "pendingOwner").lower())]
  return [Gate("nominated", not pending, f"not nominated to the vault: {', '.join(pending)}" if pending
               else "the future and its forward feed nominated to or owned by the vault"),
          engine_gate(chain, d, vault, attached=False), gate_slot(chain, d, retired), e2.series_gate(chain, d),
          gate_parity(chain, d, vault, attached=False)]


def index_gate(answered: bool, detail: str) -> Gate:
  return Gate("index", answered, detail if answered else f"EurcIndexFeed reverts ({detail}): is the v3 keeper posting reports?")


def gate_index(chain: Chain, d: dict) -> Gate:
  try:
    price = chain.word(d["indexFeed"], selector("getSpot")) / 1e18
    return index_gate(True, f"EURC/USDC index {price:.6f}")
  except Exception as exc:  # noqa: BLE001
    return index_gate(False, str(exc)[:80])


def marks_verdict(age: int, mark: int, index: int, band: int) -> Gate:
  if age > MARK_MAX_AGE_SEC:
    return Gate("marks", False, f"last mark {age}s ago (limit {MARK_MAX_AGE_SEC}s): is the forward publisher running?")
  if abs(mark - index) * 10**18 > index * band:
    return Gate("marks", False, f"mark {mark / 1e18:.6f} is outside the index band ({band / 1e16:g}% around {index / 1e18:.6f})")
  return Gate("marks", True, f"last mark {age}s ago, {mark / 1e18:.6f} inside {band / 1e16:g}% of the index {index / 1e18:.6f}")


def gate_marks(chain: Chain, d: dict) -> Gate:
  try:
    s = word_uint(int(d["subId"]))
    age = chain.head() - chain.word(d["future"], selector("futureContracts") + s, 4)
    mark = chain.word(d["future"], selector("futureContracts") + s, 5)
    index = chain.word(d["indexFeed"], selector("getSpot"))
    band = chain.word(d["future"], selector("markIndexBand") + word_uint(int(d["expiry"])))
    return marks_verdict(age, mark, index, band)
  except Exception as exc:  # noqa: BLE001
    return Gate("marks", False, f"mark or index unreadable: {str(exc)[:80]}")


def oi_cap_gate(cap18: int) -> Gate:
  if cap18 == UNCAPPED:
    return Gate("oi-cap", True, f"no cap, as decided: {OI_UNCAPPED_DECIDED}")
  if cap18 > OI_CAP_LIMIT:
    return Gate("oi-cap", False, f"the artifact's cap {cap18 / 1e18:g} is over {OI_CAP_LIMIT / 1e18:g}, the most the latest "
                                 f"manipulation-cost measurement allows ({OI_CAP_MEASURED}): re-measure first")
  return Gate("oi-cap", True, f"cap {cap18 / 1e18:g} within {OI_CAP_LIMIT / 1e18:g} ({OI_CAP_MEASURED})")


def contracts_covered(budget_usd: float, per_contract_usd: float) -> float:
  """Contracts on one side a backstop with `budget_usd` left covers, at `per_contract_usd` each."""
  return max(budget_usd, 0.0) / per_contract_usd if per_contract_usd > 0 else math.inf


def sm_capacity_gate(chain: Chain, d: dict, cngn: dict, stack: dict) -> Gate:
  """Informational, uncapped only: the EURC contracts on one side the SecurityModule covers for an SM_MOVE step, after
  cNGN-30NOV26 at its cap. Never fails: the blocking sm gate still holds for cNGN."""
  try:
    sm_cash = chain.balance(int(stack["securityModuleAccount"]), d["cash"]) / 1e18
    held = v2p.series_sm_usd(chain, cngn)
    contract_usd = chain.word(d["future"], selector("contractSize")) / 1e18 * e2.mark(chain, d)
    n = contracts_covered(sm_cash - held, v2p.sm_required_usd_linear(contract_usd))
    return Gate("sm-capacity", True, f"uncapped: SecurityModule ${sm_cash:,.0f} (less ${held:,.0f} for cNGN-30NOV26) covers "
                                     f"{n:,.1f} EURC contracts on one side for a {v2p.SM_MOVE * 100:.0f}% step; the pager "
                                     "pages past it (sm-coverage)")
  except Exception as exc:  # noqa: BLE001
    return Gate("sm-capacity", True, f"uncapped: SecurityModule capacity unreadable ({str(exc)[:80]})")


def keeper_capacity_gate(chain: Chain, d: dict, cngn: dict) -> Gate:
  """Informational, uncapped only: the EURC contracts on one side v2's keeper can take over at IM, after cNGN-30NOV26's
  side at its cap. Never fails: the blocking keeper gate still checks it is live and covers cNGN."""
  try:
    health = e2.http_json(os.environ["ENGINE_V2_KEEPER_HEALTH_URL"])
    cash = chain.balance(int(health["keeperAccount"]), d["cash"]) / 1e18
    m = word_address(cngn["manager"])
    cngn_floor = e2.keeper_floor([(
      chain.word(cngn["future"], selector("totalPositionCap") + m) / 1e18,
      chain.word(cngn["future"], selector("contractSize")) / 1e18, v2p.mark_usdc_per_cngn(chain, cngn),
      chain.word(cngn["manager"], selector("futureMarginRequirements") + word_uint(int(cngn["marketId"])), 1) / 1e18)])
    contract_im = int(d["contractSize"]) / 1e18 * e2.mark(chain, d) * int(d["futureIMReq"]) / 1e18
    n = contracts_covered(cash - cngn_floor, contract_im)
    return Gate("keeper-capacity", True, f"uncapped: keeper account ${cash:,.0f} (less ${cngn_floor:,.0f} for cNGN-30NOV26) takes "
                                         f"over {n:,.1f} EURC contracts on one side at IM; the pager pages past it "
                                         "(keeper-capacity-v2)")
  except Exception as exc:  # noqa: BLE001
    return Gate("keeper-capacity", True, f"uncapped: keeper capacity unreadable ({str(exc)[:80]})")


def gate_enable(chain: Chain, d: dict, cngn: dict, stack: dict, vault: str) -> list[Gate]:
  m = word_address(d["manager"])
  not_owned = [c for c in owned(d) if chain.address(c, "owner").lower() != vault.lower()]
  unwired = [i for i, holds in enumerate(postconditions(chain, SETUP, d, vault)) if not holds()]
  cap = chain.word(d["future"], selector("totalPositionCap") + m)
  registered = chain.word(d["tradeModule"], selector("isDatedFutureAsset") + word_address(d["future"]))
  problems = ([f"vault does not own {', '.join(not_owned)}"] if not_owned else []) + \
             ([f"{SETUP} actions {unwired} have not landed"] if unwired else []) + \
             ([f"the future is not closed (cap {cap}, registered {bool(registered)})"] if cap else [])
  # Closed is cap 0: nothing fills. Registered on the TradeModule with cap 0 is enable action 0 landed and action 1 not,
  # which a resumed enable must accept (2026-11-15: the unit's read-back timed out after action 0 and the rerun stopped).
  uncapped = int(d["futureOICap"]) == UNCAPPED
  # Uncapped, the blocking sm and keeper gates are sized for cNGN-30NOV26 alone (EURC at 0), and capacity is reported.
  oi_cap = 0.0 if uncapped else int(d["futureOICap"]) / 1e18
  capacity = [sm_capacity_gate(chain, d, cngn, stack), keeper_capacity_gate(chain, d, cngn)] if uncapped else []
  return [Gate("custody", not problems, "; ".join(problems) or "vault owns both; setup landed; the future closed"),
          engine_gate(chain, d, vault, attached=True), e2.series_gate(chain, d), gate_index(chain, d),
          gate_marks(chain, d), oi_cap_gate(int(d["futureOICap"])), *e2.gate_sm(chain, d, cngn, stack, oi_cap),
          e2.gate_pager_reads_eurc(d), e2.gate_keeper(chain, d, cngn, oi_cap), *capacity,
          e2.gate_fills(chain, d, os.environ.get("MARKETS_URL", "https://api.numofx.com")),
          v1p.gate_rfq(chain, {"perpTradeModule": d["tradeModule"]}), gate_parity(chain, d, vault, attached=True)]


# ---------------------------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------------------------

def self_test() -> int:
  from abi_selectors import assert_script
  assert_script(__file__)
  for name, want in PINNED.items():
    assert selector(name) == want, f"{name}: {selector(name)} != {want}"
  assert set(PINNED) == set(SIGNATURES), "every signature pinned"

  a = lambda n: "0x" + format(n, "040x")  # noqa: E731
  e18 = 10**18
  d = {"manager": a(1), "future": a(3), "forwardFeed": a(4), "tradeModule": a(9), "replaces": a(7),
       "futureOICap": str(4 * e18), "futureMMReq": str(4 * 10**16), "futureIMReq": str(6 * 10**16),
       "marketId": 2, "subId": 1796050800, "expiry": 1796050800}
  for batch in FILES:
    good = [{"description": str(i), "to": to, "value": "0", "data": data, "digest": digest(to, data)}
            for i, (to, data) in enumerate(expected_actions(batch, d))]
    verify_actions(batch, d, good)
    broken = {
      "target": lambda acts: acts[0].update(to=a(99)),
      "calldata": lambda acts: acts[-1].update(data=acts[-1]["data"][:-1] + "f"),
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
  setup = expected_actions(SETUP, d)
  assert setup == [
    (a(3), "0x79ba5097"), (a(4), "0x79ba5097"),
    (a(1), "0xbd798569" + word_address(a(3)) + word_uint(2) + word_uint(4)),
    (a(1), "0xe3124388" + word_uint(2) + word_uint(4 * 10**16) + word_uint(6 * 10**16)),
  ], setup
  assert setup[REPLACING_ACTION][1].startswith(PINNED["whitelistAsset"]), "the slot is re-read before whitelistAsset"
  enable = expected_actions(ENABLE, d)
  assert enable == [(a(9), "0x0ddd8a04" + word_address(a(3)) + word_uint(1)),
                    (a(3), "0x40a557bd" + word_address(a(1)) + word_uint(4 * e18))], enable
  for to, data in setup + enable:
    assert not opens_a_perp_cap({"to": to, "data": data}), (to, data[:10])

  # the artifact: EUR, subId the expiry, replacing exactly the retired series' recorded address
  engine, retired = {"manager": a(1)}, {"future": a(7)}
  check_artifact(d, engine, retired)
  for bad in ({"marketId": 1}, {"subId": 1796047200}, {"futureMMReq": str(7 * 10**16)}, {"manager": a(2)},
              {"replaces": a(8)}):
    try:
      check_artifact({**d, **bad}, engine, retired)
    except SystemExit:
      continue
    raise AssertionError(f"artifact {bad} accepted")

  # the canary: none for an artifact without one; listed on its short params, ending before production's last trade
  assert canary_expected(d) == []
  k = {**d, "canarySubId": 1795000000, "canaryFixingWindow": 900, "canaryRecoveryDelay": 300, "maxSampleGap": 120,
       "lastTradeTime": 1796049000}
  check_artifact(k, engine, retired)
  assert canary_expected(k) == [("futureContracts", 0, 1), ("futureContracts", 2, 1795000000),
                                ("futureContracts", 3, 1795000000 - 900), ("seriesFixing", 0, 900),
                                ("seriesFixing", 1, 120), ("seriesFixing", 2, 300)], canary_expected(k)
  try:
    check_artifact({**k, "canarySubId": 1796049000 - 1000}, engine, retired)
  except SystemExit:
    pass
  else:
    raise AssertionError("a canary that settles into the production window was accepted")

  # the slot: empty retired series passes; each way it is still in use holds; a stranger holds; already-this passes
  assert slot_verdict(a(7), a(7), a(3), 0, 0, False, {}).ok
  assert slot_verdict(a(3), a(7), a(3), 5, 5, True, {1: 1}).ok, "already replaced"
  for oi, cap, mod, pend in ((10**15, 0, False, {}), (0, 18 * e18, False, {}), (0, 0, True, {}), (0, 0, False, {40: -1})):
    assert not slot_verdict(a(7), a(7), a(3), oi, cap, mod, pend).ok, (oi, cap, mod, pend)
  assert not slot_verdict(a(5), a(7), a(3), 0, 0, False, {}).ok, "a holder other than the retired series"

  # the index answers; marks fresh and inside the band; the cap no more than the measurement allows
  assert index_gate(True, "x").ok and not index_gate(False, "stale").ok
  assert marks_verdict(60, 1_100 * 10**15, 1_100 * 10**15, 3 * 10**16).ok
  assert not marks_verdict(MARK_MAX_AGE_SEC + 1, e18, e18, 3 * 10**16).ok, "a stale mark"
  assert marks_verdict(60, 1_133 * 10**15, 1_100 * 10**15, 3 * 10**16).ok, "3% exactly"
  assert not marks_verdict(60, 1_134 * 10**15, 1_100 * 10**15, 3 * 10**16).ok, "over 3%"
  assert oi_cap_gate(4 * e18).ok and not oi_cap_gate(6 * e18).ok
  assert oi_cap_gate(UNCAPPED).ok and "decided" in oi_cap_gate(UNCAPPED).detail, "uncapped passes only as the decision"
  assert not oi_cap_gate(UNCAPPED - 1).ok, "a huge cap that is not exactly UNCAPPED is still measured"
  assert contracts_covered(1_000.0, 100.0) == 10.0 and contracts_covered(-5.0, 100.0) == 0.0
  # the capacity reports against a stub chain: they swallow errors into "unreadable", so prove they compute.
  # EURC 1,000 a contract at 1.16, IM 6%; cNGN-30NOV26 cap 30 (15 a side) of 1M at 0.00072, IM 20%: a $10,800 side.
  # SecurityModule $10,000 less cNGN's 15% step ($1,620) over $174 a contract (15% of $1,160): 48.2 contracts.
  # Keeper $5,000 less cNGN's side at IM ($2,160) over $69.60 a contract (6% of $1,160): 40.8 contracts.
  cngn = {"future": a(20), "manager": a(21), "subId": 1796047200, "marketId": 1}
  words = {(a(3), "contractSize"): 1000 * e18, (a(3), "futureContracts", 5): 1_160 * 10**15,
           (a(20), "totalPositionCap"): 30 * e18, (a(20), "contractSize"): 10**6 * e18,
           (a(20), "futureContracts", 5): 72 * 10**13, (a(21), "futureMarginRequirements", 1): 2 * 10**17}

  class Stub:
    def word(self, to, data, index=0):
      name = next(n for n in SIGNATURES if data.startswith(selector(n)))
      return words[(to, name, index) if index else (to, name)]

    def balance(self, account, asset):
      return {9: 10_000 * e18, 77: 5_000 * e18}[account]

  real_http, os.environ["ENGINE_V2_KEEPER_HEALTH_URL"] = e2.http_json, "http://keeper"
  e2.http_json = lambda url: {"keeperAccount": 77}
  try:
    full = {**d, "cash": a(30), "contractSize": str(1000 * e18), "futureIMReq": str(6 * 10**16)}
    sm = sm_capacity_gate(Stub(), full, cngn, {"securityModuleAccount": 9})
    keeper = keeper_capacity_gate(Stub(), full, cngn)
  finally:
    e2.http_json = real_http
    os.environ.pop("ENGINE_V2_KEEPER_HEALTH_URL")
  assert sm.ok and "covers 48.2 EURC contracts" in sm.detail, sm.detail
  assert keeper.ok and "over 40.8 EURC contracts" in keeper.detail, keeper.detail

  import inspect
  for fn in (main, run_batch):
    assert "propose(token" not in inspect.getsource(fn), f"{fn.__name__} calls propose() directly"
  print("self-test ok: selectors compiled and pinned; a wrong target, calldata, value, digest, count or order is refused; "
        "the artifact must replace the recorded retired series; the slot refuses open interest, a cap, a TradeModule "
        "registration, pending VM or a stranger; a stale or out-of-band mark, a silent index and a cap over the "
        "measurement are refused")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def run_batch(args, d: dict, retired: dict, cngn: dict, stack: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  actions = json.loads((args.dir / FILES[args.batch]).read_text())
  verify_actions(args.batch, d, actions)

  def gates() -> list[Gate]:
    return gate_setup(chain, d, retired, vault) if args.batch == SETUP else gate_enable(chain, d, cngn, stack, vault)

  current = gates()
  passed = report(current)
  holds = postconditions(chain, args.batch, d, vault)
  done = [h() for h in holds]
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
  token, vault_uuid = v2p.credentials()
  first = done.index(False)
  for i, a in enumerate(actions):
    if holds[i]():
      print(f"  [{i}] already landed, skipped: {a['description']}")
      continue
    if i > first or (args.batch == SETUP and i == REPLACING_ACTION):
      # Between the enable actions the cap is raised, so custody ("closed") is expected to fail there. Before the
      # action that replaces market 2's future, every setup gate (the slot above all) is read once more.
      again = gates_after_mining(lambda: [g for g in gates() if not (args.batch == ENABLE and g.name == "custody")])
      if not report(again):
        raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    v2p.await_approval(token, vault_uuid, vault, a, rpc_url, holds[i])
  print(f"\n{args.batch}: done." + (f" {d['symbol']} v3 is open." if args.batch == ENABLE else ""))
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the EURC v3 series' vault batches on MarginEngine v2")
  ap.add_argument("batch", nargs="?", choices=tuple(FILES))
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--dir", type=Path, default=ROOT / "deployments" / "8453", help="where the deploys wrote their artifacts")
  ap.add_argument("--stack", type=Path, default=ROOT / "deployments" / "8453" / "CNGN_PERP_STACK.json")
  ap.add_argument("--json", action="store_true", help="print the gates as JSON on the last line")
  args = ap.parse_args()

  if args.self_test:
    return self_test()
  if not args.batch:
    ap.error("name a batch: " + ", ".join(FILES))

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  load_env_file(Path("/etc/numo/perp-pager.env"))
  rpc_url = os.environ.get("RPC_URL") or os.environ.get("BASE_RPC_URL", "")
  if not rpc_url:
    raise SystemExit("RPC_URL (or BASE_RPC_URL) is required")
  chain_id = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain_id != 8453:
    raise SystemExit(f"expected Base mainnet (8453), got chain {chain_id}")
  vault = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault} is not the recorded vault {EXPECTED_VAULT}")

  artifact = args.dir / f"{NAME}.json"
  if not artifact.exists():
    raise SystemExit(f"{artifact} does not exist: the v3 series is not deployed (deploy-eurc-future-v3.s.sol writes it)")
  d = json.loads(artifact.read_text())
  retired = json.loads((args.dir / f"{RETIRED_NAME}.json").read_text())
  cngn = json.loads((args.dir / f"{ENGINE_NAME}.json").read_text())
  check_artifact(d, cngn, retired)
  return run_batch(args, d, retired, cngn, json.loads(args.stack.read_text()), Chain(rpc_url), rpc_url, vault)


if __name__ == "__main__":
  raise SystemExit(main())
