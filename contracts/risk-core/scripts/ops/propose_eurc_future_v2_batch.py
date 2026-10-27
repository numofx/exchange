#!/usr/bin/env python3
"""Propose EURC-<expiry>'s vault batches on MarginEngine v2 to MPCVault (docs/margin-engine-v2.md, EURC-30NOV26).

  eurc-future-setup   EURC_FUTURE_V2_VAULT_ACTIONS.json, from deploy-eurc-future-v2.s.sol: accept the future and its
                      forward feed, list the future on v2's market 2 (whitelistAsset(future, 2, Future)) and set market
                      2's futures margin (setFutureMarginRequirements(2, mm, im)). Opens nothing: the cap stays 0 and
                      the TradeModule does not know the future.
  eurc-future-enable  EURC_FUTURE_V2_ENABLE_VAULT_ACTIONS.json: the future's cap under v2, then the future on the
                      TradeModule. Proposed only while every gate below passes, re-read before each action. A later
                      resize is propose_margin_engine_v2_batch.py's `cap`, which reads only the cNGN artifact: until it
                      takes a series, resize by a hand-checked action gated like enable.

Every artifact action is rebuilt here from EURC_FUTURE_V2.json and must match the file exactly (to, calldata, value),
its digest recomputed (keccak(to || keccak(data))). An action whose postcondition already holds is skipped.

Setup gates (all read live):
  nominated  the future and the forward feed are nominated to (or owned by) the vault
  engine     the vault owns v2; v2 lists exactly NGN and EUR, EUR's base is the artifact's EURC escrow, EUR lists no
             other future and no perp; v2's own setup has landed (the cash takes v2)
  series     no other market's future lists this expiry: one subId on two futures couples their close-outs
  parity     the future and feed as deployed; the deployer holds nothing and has sent nothing since

Enable gates (all read live, all required unless marked):
  custody    the vault owns both; setup has landed; the future is closed (cap 0, not on the TradeModule)
  feed       the EURC index (Chainlink EURC/USD via the EUR market's spot feed): the vault's, its aggregator and 3h limit,
             answering inside 0.8-1.6 USD (propose_eurc_spot_batch's feed gate)
  marks      the future was marked within 2h: its forward publisher is running
  sm         the SecurityModule's cash covers an SM_MOVE (15%) step on this future's one side at the cap, ON TOP of what
             it covers for cNGN-30NOV26 at its live cap (one module for every v2 series)
  gaps       informational: the cap the rest of the module covers against a 8/10/15% EUR gap, every contract a long
             opened at IM
  pager      check_perp_pager.py ran OK within 3 minutes with a provider and a dead-man's switch, and its last run read
             this future (`futures` in its state; no pager reads it until #258 adds it)
  keeper     v2's liquidation keeper (ENGINE_V2_KEEPER_HEALTH_URL): live, not DRY_RUN, manager v2, reporting this future
             among its `futures`; its funding account holds neither future and the IM for one full side of each at its
             cap (this one at the cap being opened)
  fills      markets-service lists the future (asset_address, sub_id) as the artifact's symbol (EURC-30NOV26) with
             fill_band_enforced and the chain's band, index -/+ markIndexBand(expiry), in USDC per EURC (no inversion)
  rfq        the RfqModule is not on the TradeModule's Matching
  parity     as at setup, and now the engine: market 2's future is this one, at the artifact's margin

It NEVER signs, executes or broadcasts. Without --propose it prints the gates and the sheet. With --propose each action
goes to the MPCVault app for a human to approve, one at a time, from the vault, through perp_cap_guard.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.

  python3 scripts/ops/propose_eurc_future_v2_batch.py eurc-future-setup             # check + sheet, proposes nothing
  python3 scripts/ops/propose_eurc_future_v2_batch.py eurc-future-setup --propose
  python3 scripts/ops/propose_eurc_future_v2_batch.py eurc-future-enable
  python3 scripts/ops/propose_eurc_future_v2_batch.py --self-test
  python3 scripts/ops/propose_eurc_future_v2_batch.py eurc-future-enable --local --dir deployments/31337 --json   # a fork
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

import propose_margin_engine_v2_batch as v2p  # noqa: E402  the cNGN series' proposer: its chain reads and gates
import propose_eurc_spot_batch as eurc  # noqa: E402  the EURC feed gate, one implementation
from check_perp_pager import SM_MOVE, sm_required_usd_linear  # noqa: E402
from perp_cap_guard import opens_a_perp_cap  # noqa: E402
from propose_cngn_spot_batch import EXPECTED_VAULT, gates_after_mining, load_env_file, rpc  # noqa: E402
from propose_perp_enable_batch import gate_pager, http_json, keeper_gate  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

v1p = v2p.v1p
Gate, Chain, report = v1p.Gate, v1p.Chain, v1p.report
word_address, word_uint, digest = v1p.word_address, v1p.word_uint, v1p.digest

ROOT = v1p.ROOT
NAME = "EURC_FUTURE_V2"
ENGINE_NAME = v2p.NAME
FILES = {"eurc-future-setup": f"{NAME}_VAULT_ACTIONS.json", "eurc-future-enable": f"{NAME}_ENABLE_VAULT_ACTIONS.json"}
MARK_MAX_AGE_SEC = v1p.MARK_MAX_AGE_SEC
MARKET_ID = eurc.MARKET_ID
BASE, FUTURE, PERP = v2p.BASE, v2p.FUTURE, v2p.PERP
UNIT = "USDC per EURC"
# EUR gaps the informational table reads: past IM (6%) and well past any daily EUR/USD move on record
GAPS = (0.08, 0.10, 0.15)

SIGNATURES = {**v2p.SIGNATURES, "whitelistAsset": "whitelistAsset(address,uint256,uint8)",
              "setFutureMarginRequirements": "setFutureMarginRequirements(uint256,uint256,uint256)"}
PINNED = {**v2p.PINNED, "whitelistAsset": "0xbd798569", "setFutureMarginRequirements": "0xe3124388"}


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


def owned(d: dict) -> list[str]:
  return [d["future"], d["forwardFeed"]]


# ---------------------------------------------------------------------------------------------
# the artifact batches
# ---------------------------------------------------------------------------------------------

def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as deploy-eurc-future-v2.s.sol writes them."""
  m = word_address(d["manager"])
  if batch == "eurc-future-setup":
    return [*[(c, selector("acceptOwnership")) for c in owned(d)],
            (d["manager"], selector("whitelistAsset") + word_address(d["future"]) + word_uint(MARKET_ID) + word_uint(FUTURE)),
            (d["manager"], selector("setFutureMarginRequirements") + word_uint(MARKET_ID)
             + word_uint(int(d["futureMMReq"])) + word_uint(int(d["futureIMReq"])))]
  return [(d["future"], selector("setTotalPositionCap") + m + word_uint(int(d["futureOICap"]))),
          (d["tradeModule"], selector("setDatedFutureAsset") + word_address(d["future"]) + word_uint(1))]


def postconditions(chain: Chain, batch: str, d: dict, vault: str) -> list:
  """One read per action, aligned with expected_actions: whether it has landed."""
  m = word_address(d["manager"])
  w = lambda to, name, *args, index=0: chain.word(to, selector(name) + "".join(args), index)  # noqa: E731
  if batch == "eurc-future-setup":
    return [*[(lambda c=c: chain.address(c, "owner").lower() == vault.lower()) for c in owned(d)],
            lambda: future_on_market(chain, d).lower() == d["future"].lower(),
            lambda: (w(d["manager"], "futureMarginRequirements", word_uint(MARKET_ID), index=0),
                     w(d["manager"], "futureMarginRequirements", word_uint(MARKET_ID), index=1))
            == (int(d["futureMMReq"]), int(d["futureIMReq"]))]
  return [lambda: w(d["future"], "totalPositionCap", m) == int(d["futureOICap"]),
          lambda: w(d["tradeModule"], "isDatedFutureAsset", word_address(d["future"])) == 1]


def verify_actions(batch: str, d: dict, actions: list[dict]) -> None:
  """Refuses a file that is not exactly what the deployment implies."""
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


def check_artifact(d: dict, engine: dict) -> None:
  """The artifact is for v2's EUR market, from the engine artifact this directory holds."""
  if d["manager"].lower() != engine["manager"].lower():
    raise SystemExit(f"{NAME}.json names engine {d['manager']}, not {ENGINE_NAME}.json's {engine['manager']}")
  if int(d["marketId"]) != MARKET_ID:
    raise SystemExit(f"{NAME}.json is for market {d['marketId']}, not EUR ({MARKET_ID})")
  if int(d["subId"]) != int(d["expiry"]):
    raise SystemExit(f"{NAME}.json: subId {d['subId']} is not its expiry")
  if int(d["futureMMReq"]) <= 0 or int(d["futureMMReq"]) > int(d["futureIMReq"]) or int(d["futureIMReq"]) >= 10**18:
    raise SystemExit(f"{NAME}.json: futures margin MM {d['futureMMReq']} / IM {d['futureIMReq']} is not 0 < MM <= IM < 1")


# ---------------------------------------------------------------------------------------------
# chain reads
# ---------------------------------------------------------------------------------------------

def future_on_market(chain: Chain, d: dict, market: int = MARKET_ID) -> str:
  return "0x" + chain.call(d["manager"], selector("assetMap") + word_uint(market) + word_uint(FUTURE))[24:64]


def mark(chain: Chain, d: dict) -> float:
  return chain.word(d["future"], selector("futureContracts") + word_uint(int(d["subId"])), 5) / 1e18


def futures_sharing_series(listed: dict[int, bool]) -> list[int]:
  """The markets (other than EUR) whose future lists this subId: {market: listed}."""
  return sorted(m for m, yes in listed.items() if yes and m != MARKET_ID)


def series_gate(chain: Chain, d: dict) -> Gate:
  last = chain.word(d["manager"], selector("lastMarketId"))
  listed = {}
  for market in range(1, last + 1):
    other = future_on_market(chain, d, market)
    if int(other, 16) == 0 or other.lower() == d["future"].lower():
      continue
    listed[market] = chain.word(other, selector("futureContracts") + word_uint(int(d["subId"]))) == 1
  shared = futures_sharing_series(listed)
  if shared:
    return Gate("series", False, f"market(s) {shared} list a series at {d['subId']}: closeOutExpired would hold each "
                                 "close-out until both have fixed. Redeploy at another expiry")
  return Gate("series", True, f"no other market lists a series at {d['subId']}")


# ---------------------------------------------------------------------------------------------
# gates
# ---------------------------------------------------------------------------------------------

def engine_gate(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  m, problems = d["manager"], []
  if chain.address(m, "owner").lower() != vault.lower():
    problems.append("the vault does not own v2")
  if chain.word(m, selector("lastMarketId")) != 2:
    problems.append("v2 does not list exactly NGN and EUR")
  base = "0x" + chain.call(m, selector("assetMap") + word_uint(MARKET_ID) + word_uint(BASE))[24:64]
  if base.lower() != d["escrow"].lower():
    problems.append(f"EUR's base is {base}, not the EURC escrow {d['escrow']}")
  listed = future_on_market(chain, d)
  if int(listed, 16) != 0 and listed.lower() != d["future"].lower():
    problems.append(f"EUR already lists another future {listed}")
  if attached and listed.lower() != d["future"].lower():
    problems.append("EUR does not list the future: eurc-future-setup has not landed")
  perp = "0x" + chain.call(m, selector("assetMap") + word_uint(MARKET_ID) + word_uint(PERP))[24:64]
  if int(perp, 16) != 0:
    problems.append("EUR lists a perp")
  if chain.word(d["cash"], selector("whitelistedManager") + word_address(m)) != 1:
    problems.append("the cash does not take v2: v2's setup has not landed")
  return Gate("engine", not problems, "; ".join(problems) or "v2 is the vault's, lists NGN and EUR, EUR's base the EURC "
              "escrow and no other future; v2's setup landed")


def gate_setup(chain: Chain, d: dict, vault: str) -> list[Gate]:
  pending = [c for c in owned(d) if vault.lower() not in
             (chain.address(c, "owner").lower(), chain.address(c, "pendingOwner").lower())]
  return [Gate("nominated", not pending, f"not nominated to the vault: {', '.join(pending)}" if pending
               else "the future and its forward feed nominated to or owned by the vault"),
          engine_gate(chain, d, vault, attached=False), series_gate(chain, d), gate_parity(chain, d, vault, attached=False)]


def one_side_usd(cap_contracts: float, size_eurc: float, mark_usdc: float) -> float:
  return v2p.one_side_usd(cap_contracts, size_eurc, mark_usdc)


def gap_max_caps(sm_cash: float, contract_usd: float, im: float) -> list[tuple[float, int | None]]:
  """(gap, the largest cap the module covers) for each EUR gap: every contract a long opened at IM, bankrupt past it.
  None where the gap does not pass IM (no bad debt)."""
  return [(g, math.floor(sm_cash / (contract_usd * (g - im))) if g > im else None) for g in GAPS]


def gaps_gate(sm_cash: float, contract_usd: float, im: float, cap: float) -> Gate:
  """Informational: never fails."""
  caps = gap_max_caps(sm_cash, contract_usd, im)
  over = [f"{g * 100:.0f}%" for g, c in caps if c is not None and cap > c]
  return Gate("gaps", True, "max cap at a " + ", ".join(f"{g * 100:.0f}% gap {c if c is not None else 'any'}" for g, c in caps)
              + f" (opening {cap:g}" + (f": NOT covered at {', '.join(over)})" if over else ")"))


def gate_sm(chain: Chain, d: dict, cngn: dict, stack: dict, cap: float) -> list[Gate]:
  """This series' SM_MOVE step on one side, on top of cNGN-30NOV26's at its live cap."""
  try:
    sm_cash = chain.balance(int(stack["securityModuleAccount"]), d["cash"]) / 1e18
    size = chain.word(d["future"], selector("contractSize")) / 1e18
    price = mark(chain, d)
    im = int(d["futureIMReq"]) / 1e18
    held = v2p.series_sm_usd(chain, cngn)
    return [v2p.sm_gate(sm_cash, one_side_usd(cap, size, price), held, "cNGN-30NOV26 at its cap"),
            gaps_gate(sm_cash - held, size * price, im, cap)]
  except Exception as exc:  # noqa: BLE001 -- unreadable is a failed gate
    return [Gate("sm", False, f"SecurityModule coverage unreadable: {str(exc)[:80]}")]


def gate_marks(chain: Chain, d: dict) -> Gate:
  age = chain.head() - chain.word(d["future"], selector("futureContracts") + word_uint(int(d["subId"])), 4)
  return Gate("marks", age <= MARK_MAX_AGE_SEC, f"last mark {age}s ago (limit {MARK_MAX_AGE_SEC}s)"
              + ("" if age <= MARK_MAX_AGE_SEC else ": is the EURC forward publisher running?"))


def pager_reads(state: dict, future: str) -> bool:
  return future.lower() in [str(f).lower() for f in state.get("futures") or []]


def gate_pager_reads_eurc(d: dict) -> Gate:
  state_file = v2p.pager_state()
  base = gate_pager(state_file, future_manager=d["manager"])
  if not base.ok:
    return base
  state = json.loads(state_file.read_text())
  if not pager_reads(state, d["future"]):
    return Gate("pager", False, f"the pager's last run did not read the EURC future {d['future']} (`futures` in its "
                                "state): it would not page on its marks, VM pool or SecurityModule cover")
  return Gate("pager", True, base.detail + f", and the EURC future {d['future']}")


def keeper_floor(sides: list[tuple[float, float, float, float]]) -> float:
  """The IM for one full side of each series: (cap, size, mark, im) each."""
  return sum(v2p.engine_keeper_min_cash(cap, size, price, im) for cap, size, price, im in sides)


def keeper_reports(health: dict, future: str) -> bool:
  return future.lower() in [str(f).lower() for f in health.get("futures") or []]


def gate_keeper(chain: Chain, d: dict, cngn: dict, cap: float) -> Gate:
  url = os.environ.get("ENGINE_V2_KEEPER_HEALTH_URL", "")
  if not url:
    return Gate("keeper", False, "ENGINE_V2_KEEPER_HEALTH_URL is not set: v2 needs its own keeper (#258)")
  try:
    m = word_address(cngn["manager"])
    cngn_cap = chain.word(cngn["future"], selector("totalPositionCap") + m) / 1e18
    floor = keeper_floor([
      (cap, int(d["contractSize"]) / 1e18, mark(chain, d), int(d["futureIMReq"]) / 1e18),
      (cngn_cap, chain.word(cngn["future"], selector("contractSize")) / 1e18, v2p.mark_usdc_per_cngn(chain, cngn),
       chain.word(cngn["manager"], selector("futureMarginRequirements") + word_uint(int(cngn["marketId"])), 1) / 1e18),
    ])
    health = http_json(url)
  except Exception as exc:  # noqa: BLE001
    return Gate("keeper", False, f"the keeper's floor or health unreadable: {str(exc)[:80]}")
  if not keeper_reports(health, d["future"]):
    return Gate("keeper", False, f"the keeper does not report the EURC future {d['future']} among its `futures`: "
                                 "it would not bid on an EURC-future account")
  return keeper_gate(chain.url, d["manager"], "MarginEngine v2", d["cash"],
                     [(cngn["future"], int(cngn["subId"])), (d["future"], int(d["subId"]))], url, floor,
                     v1p.ENGINE_KEEPER_MIN_ETH)


def listing_gate(listing: dict | None, symbol: str) -> Gate | None:
  """markets-service lists it under the artifact's symbol, not v1's naming (`FutureSymbol`)."""
  if listing is not None and listing.get("market") != symbol:
    return Gate("fills", False, f"markets-service lists the future as {listing.get('market')!r}, not {symbol!r}")
  return None


def gate_fills(chain: Chain, d: dict, markets_url: str) -> Gate:
  try:
    listing = v2p.find_listing(v2p.markets(markets_url), d["future"], d["subId"])
  except Exception as exc:  # noqa: BLE001
    return Gate("fills", False, f"markets-service /v1/markets unreadable: {str(exc)[:80]}")
  wrong = listing_gate(listing, d["symbol"])
  if wrong:
    return wrong
  try:
    low, high = v2p.chain_fill_band(chain.word(d["indexFeed"], selector("getSpot")),
                                    chain.word(d["future"], selector("markIndexBand") + word_uint(int(d["expiry"]))))
  except Exception as exc:  # noqa: BLE001
    return Gate("fills", False, f"the chain's fill band unreadable: {str(exc)[:80]}")
  return v1p.fills_gate(listing, low, high, unit=UNIT)


def gate_feed(chain: Chain, d: dict, vault: str) -> Gate:
  try:
    return eurc.gate_feed(chain.url, {"spotFeed": d["indexFeed"]}, vault)
  except Exception as exc:  # noqa: BLE001
    return Gate("feed", False, f"the EURC index unreadable: {str(exc)[:80]}")


def gate_parity(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  """Every setting the deploy made, re-read against the artifact; once attached, the engine's too."""
  future, feed = d["future"], d["forwardFeed"]
  w = lambda to, name, *args, index=0: chain.word(to, selector(name) + "".join(args), index)  # noqa: E731
  a = lambda to, name, *args: "0x" + chain.call(to, selector(name) + "".join(args))[24:64]  # noqa: E731
  m = word_address(d["manager"])
  pairs: list[tuple[str, object, object]] = [
    ("contract size", w(future, "contractSize"), int(d["contractSize"])),
    ("future index", a(future, "indexFeed"), d["indexFeed"]),
    ("future forward feed", a(future, "forwardFeed"), feed),
    ("forward feed's index", a(feed, "spotFeed"), d["indexFeed"]),
    ("forward signer", w(feed, "isSigner", word_address(d["forwardSigner"])), 1),
    ("forward quorum", w(feed, "requiredSigners"), 1),
    ("forward heartbeat", w(feed, "heartbeat"), int(d["forwardHeartbeat"])),
    ("future whitelists v2", w(future, "whitelistedManager", m), 1),
    ("series listed", w(future, "futureContracts", word_uint(int(d["subId"]))), 1),
    ("series expiry", w(future, "futureContracts", word_uint(int(d["subId"])), index=2), int(d["expiry"])),
    ("series last trade", w(future, "futureContracts", word_uint(int(d["subId"])), index=3), int(d["lastTradeTime"])),
    ("EUR's spot feed is the index", a(d["manager"], "getMarketFeeds", word_uint(MARKET_ID)), d["indexFeed"]),
    ("future OI fee", w(d["viewer"], "OIFeeRateBPS", word_address(future)), 0),
  ]
  for name in ("maxMarkDeviation", "maxMarkDelay", "maxMarkIndexDeviation", "minMarkIndexDeviation", "bandNarrowingPeriod",
               "fixingWindow", "maxSampleGap", "fallbackDelay", "minMarkInterval"):
    pairs.append((f"future {name}", w(future, name), int(d[name])))
  if attached:
    mk = word_uint(MARKET_ID)
    pairs += [("EUR's future", future_on_market(chain, d), future),
              ("EUR futures MM", w(d["manager"], "futureMarginRequirements", mk, index=0), int(d["futureMMReq"])),
              ("EUR futures IM", w(d["manager"], "futureMarginRequirements", mk, index=1), int(d["futureIMReq"]))]
  deployer = d["deployer"]
  sent = int(rpc(chain.url, "eth_getTransactionCount", [deployer, "latest"]), 16)
  pairs += [("deployer transactions since the deploy", sent - int(d["deployerNonce"]), 0),
            ("deployer signs the forward", w(feed, "isSigner", word_address(deployer)), 0)]
  for c in owned(d):
    # before setup the deployer owns it with the vault its nominee; once attached, the vault owns it
    holder = a(c, "owner").lower() if attached else (a(c, "owner").lower(), a(c, "pendingOwner").lower())
    pairs.append((f"{c} is the vault's" if attached else f"{c} is nominated to the vault",
                  holder == vault.lower() if attached else vault.lower() in holder, True))
  bad = v1p.parity_mismatches(pairs)
  if bad:
    return Gate("parity", False, f"{len(bad)} setting(s) differ from the deploy: " + "; ".join(bad[:4]))
  return Gate("parity", True, f"all {len(pairs)} settings as deployed; deployer {deployer} has sent nothing since")


def gate_enable(chain: Chain, d: dict, cngn: dict, stack: dict, vault: str) -> list[Gate]:
  m = word_address(d["manager"])
  not_owned = [c for c in owned(d) if chain.address(c, "owner").lower() != vault.lower()]
  unwired = [i for i, holds in enumerate(postconditions(chain, "eurc-future-setup", d, vault)) if not holds()]
  cap = chain.word(d["future"], selector("totalPositionCap") + m)
  registered = chain.word(d["tradeModule"], selector("isDatedFutureAsset") + word_address(d["future"]))
  problems = ([f"vault does not own {', '.join(not_owned)}"] if not_owned else []) + \
             ([f"eurc-future-setup actions {unwired} have not landed"] if unwired else []) + \
             ([f"the future is not closed (cap {cap}, registered {bool(registered)})"] if cap or registered else [])
  oi_cap = int(d["futureOICap"]) / 1e18
  return [Gate("custody", not problems, "; ".join(problems) or "vault owns both; setup landed; the future closed"),
          engine_gate(chain, d, vault, attached=True), series_gate(chain, d), gate_feed(chain, d, vault),
          gate_marks(chain, d), *gate_sm(chain, d, cngn, stack, oi_cap), gate_pager_reads_eurc(d),
          gate_keeper(chain, d, cngn, oi_cap), gate_fills(chain, d, os.environ.get("MARKETS_URL", "https://api.numofx.com")),
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
  d = {"manager": a(1), "future": a(3), "forwardFeed": a(4), "cash": a(5), "escrow": a(7), "tradeModule": a(9),
       "futureOICap": str(18 * e18), "futureMMReq": str(4 * 10**16), "futureIMReq": str(6 * 10**16),
       "marketId": 2, "subId": 1796054400, "expiry": 1796054400}
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
  setup = expected_actions("eurc-future-setup", d)
  assert setup == [
    (a(3), "0x79ba5097"), (a(4), "0x79ba5097"),
    (a(1), "0xbd798569" + word_address(a(3)) + word_uint(2) + word_uint(4)),
    (a(1), "0xe3124388" + word_uint(2) + word_uint(4 * 10**16) + word_uint(6 * 10**16)),
  ], setup
  enable = expected_actions("eurc-future-enable", d)
  assert enable == [(a(3), "0x40a557bd" + word_address(a(1)) + word_uint(18 * e18)),
                    (a(9), "0x0ddd8a04" + word_address(a(3)) + word_uint(1))], enable
  for to, data in setup + enable:
    assert not opens_a_perp_cap({"to": to, "data": data}), (to, data[:10])
  # A market other than EUR, a subId that is not the expiry, or a margin MM over IM is refused.
  engine = {"manager": a(1)}
  check_artifact(d, engine)
  for bad in ({"marketId": 1}, {"subId": 1796047200}, {"futureMMReq": str(7 * 10**16)}, {"manager": a(2)}):
    try:
      check_artifact({**d, **bad}, engine)
    except SystemExit:
      continue
    raise AssertionError(f"artifact {bad} accepted")

  # One subId on two markets' futures couples their close-outs: refused.
  assert futures_sharing_series({1: True}) == [1] and futures_sharing_series({1: False}) == []
  assert futures_sharing_series({2: True}) == [], "EUR's own listing is not a clash"

  # Coverage at 2026-10-27 readings (SM $3,250, EURC 1.1138, cNGN 0.000713260 at a cap of 30): cNGN holds $1,604.84;
  # 18 EURC contracts ($1,503.63 more) fit, 20 ($1,670.70) do not. With cNGN at 0, 38 fit.
  cngn_held = sm_required_usd_linear(v2p.one_side_usd(30, 1_000_000, 0.000713260))
  assert abs(cngn_held - 1_604.835) < 0.01, cngn_held
  assert v2p.sm_gate(3_250, one_side_usd(18, 1_000, 1.1138), cngn_held, "cNGN").ok
  assert not v2p.sm_gate(3_250, one_side_usd(20, 1_000, 1.1138), cngn_held, "cNGN").ok
  assert v2p.sm_gate(3_250, one_side_usd(38, 1_000, 1.1138)).ok and not v2p.sm_gate(3_250, one_side_usd(40, 1_000, 1.1138)).ok
  assert SM_MOVE == 0.15
  # EUR gaps: $1,113.80 contracts at IM 6% cost $22.28 / $44.55 / $100.24 past bankruptcy at 8 / 10 / 15%.
  assert [c for _, c in gap_max_caps(1_645, 1_113.8, 0.06)] == [73, 36, 16]
  assert gap_max_caps(1_645, 1_113.8, 0.10)[0][1] is None, "a gap under IM costs nothing"
  assert "NOT covered at 15%" in gaps_gate(1_645, 1_113.8, 0.06, 18).detail and gaps_gate(1_645, 1_113.8, 0.06, 18).ok
  # The keeper's floor: one full side of each at its cap: EURC 9 x $1,113.80 x 6% + cNGN 15 x $713.26 x 25%.
  assert abs(keeper_floor([(18, 1_000, 1.1138, 0.06), (30, 1_000_000, 0.00071326, 0.25)]) - (601.452 + 2_674.725)) < 1e-6
  # The pager and the keeper must name this future.
  assert pager_reads({"futures": [a(3).upper()]}, a(3)) and not pager_reads({"futureManager": a(1)}, a(3))
  assert keeper_reports({"futures": [a(3)]}, a(3)) and not keeper_reports({}, a(3))
  # The listing: the artifact's symbol, not v1's `USDC-...` naming; the band in USDC per EURC, as the chain reads it.
  assert listing_gate({"market": "EURC-30NOV26"}, "EURC-30NOV26") is None
  assert not listing_gate({"market": "USDC-EURC-30NOV26"}, "EURC-30NOV26").ok
  assert listing_gate(None, "EURC-30NOV26") is None, "absent is fills_gate's to refuse"
  low, high = v2p.chain_fill_band(1_113_788_840_000_000_000, 3 * 10**16)
  assert abs(low - 1.11378884 * 0.97) < 1e-12 and abs(high - 1.11378884 * 1.03) < 1e-12
  listed = {"fill_band_enforced": True, "fill_band_low": str(low), "fill_band_high": str(high)}
  assert v1p.fills_gate(listed, low, high, unit=UNIT).ok
  assert not v1p.fills_gate({**listed, "fill_band_low": str(1 / high), "fill_band_high": str(1 / low)}, low, high).ok, \
    "an inverted (EURC per USDC) band is refused"

  import inspect
  for fn in (main, run_batch):
    assert "propose(token" not in inspect.getsource(fn), f"{fn.__name__} calls propose() directly"
  print("self-test ok: selectors compiled and pinned; a wrong target, calldata, value, digest, count or order is refused; "
        "a shared expiry is refused; SecurityModule cover counts cNGN's draw; keeper, pager and fill band read the EURC "
        "future in USDC per EURC")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def run_batch(args, d: dict, cngn: dict, stack: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  actions = json.loads((args.dir / FILES[args.batch]).read_text())
  verify_actions(args.batch, d, actions)

  def gates() -> list[Gate]:
    if args.batch == "eurc-future-setup":
      return gate_setup(chain, d, vault)
    return gate_enable(chain, d, cngn, stack, vault)

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
    # Re-read before each. Between the two enable actions the cap is raised, so custody ("closed") is expected to
    # fail there.
    if i > first:
      again = gates_after_mining(lambda: [g for g in gates() if not (args.batch == "eurc-future-enable" and g.name == "custody")])
      if not report(again):
        raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    v2p.await_approval(token, vault_uuid, vault, a, rpc_url, holds[i])
  print(f"\n{args.batch}: done." + (f" {d['symbol']} is open: markets-service can list it." if args.batch == "eurc-future-enable" else ""))
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the EURC future's vault batches on MarginEngine v2")
  ap.add_argument("batch", nargs="?", choices=tuple(FILES))
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--local", action="store_true", help="a fork (chain 31337) only; never proposes")
  ap.add_argument("--dir", type=Path, default=ROOT / "deployments" / "8453", help="where the deploys wrote their artifacts")
  ap.add_argument("--stack", type=Path, default=ROOT / "deployments" / "8453" / "CNGN_PERP_STACK.json")
  ap.add_argument("--json", action="store_true", help="print the gates as JSON on the last line")
  args = ap.parse_args()

  if args.self_test:
    return self_test()
  if not args.batch:
    ap.error("name a batch: eurc-future-setup or eurc-future-enable")

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

  artifact = args.dir / f"{NAME}.json"
  if not artifact.exists():
    raise SystemExit(f"{artifact} does not exist: the EURC future is not deployed (deploy-eurc-future-v2.s.sol writes it)")
  d = json.loads(artifact.read_text())
  cngn = json.loads((args.dir / f"{ENGINE_NAME}.json").read_text())
  check_artifact(d, cngn)
  return run_batch(args, d, cngn, json.loads(args.stack.read_text()), Chain(rpc_url), rpc_url, vault)


if __name__ == "__main__":
  raise SystemExit(main())
