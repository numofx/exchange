#!/usr/bin/env python3
"""Propose cNGN-USDC options' vault batches on MarginEngine v2 to MPCVault (deploy-cngn-options-v2.s.sol).

  cngn-options-setup   CNGN_OPTIONS_V2_VAULT_ACTIONS.json: accept the option and its vol feed; whitelistAsset(option, 1,
                       Option); setOptionMarginParams(1, ...); setOracleContingencyParams(1, ...);
                       setOraclesForMarket(1, index, forward, vol). Opens nothing: the option's cap stays 0.
  cngn-options-enable  CNGN_OPTIONS_V2_ENABLE_VAULT_ACTIONS.json: the option's cap. No TradeModule action: the live
                       TradeModule fills an asset that is neither perp nor dated future as price x amount in cash, which
                       is an option premium (CngnOptionsV2Fork).

Every artifact action is rebuilt here from CNGN_OPTIONS_V2.json and must match the file exactly (to, calldata, value),
its digest recomputed (keccak(to || keccak(data))). An action whose postcondition already holds is skipped.

TWO SETUP ACTIONS REWRITE LIVE SETTINGS of market 1 (cNGN spot and cNGN-30NOV26):
  setOraclesForMarket writes spot, forward and vol together: the artifact's spot is the cNGN index market 1 read at
    deploy. If market 1 reads anything else now, the action would replace it and every cNGN account stops margining.
  setOracleContingencyParams writes all four: perp, base and OCFactor are market 1's at deploy, the option threshold is
    new. If any has moved since, the action would move it back.
The `market1` gate re-reads both before every action and refuses on any difference: redeploy, never hand-edit.

Setup gates (all read live):
  nominated  the option and the vol feed are nominated to (or owned by) the vault
  engine     the vault owns v2; v2 lists NGN and EUR; market 1 lists no other option and its future is v2's cNGN future;
             v2's setup has landed (the cash takes v2)
  market1    market 1's spot feed, contingency params and the future's forward feed are what the artifact writes back
  venue      the TradeModule fills against v2 cash and is NOT a trusted risk assessor (a trusted one is held to MM only)
  series     the cNGN future lists the expiry, unsettled: the options settle at its settlement price
  parity     the option, adapter and vol feed as deployed; the deployer has sent nothing unaudited since

Enable gates (all read live, all required):
  custody    the vault owns both; setup has landed; the option is closed (cap 0)
  engine, market1, venue, series, parity (now also market 1's option, margin params and feeds)
  vol        the vol feed has a live surface for the expiry, at confidence over the option threshold: the publisher runs
  sm         the SecurityModule covers an SM_MOVE (15%) step on one side of the cap taken linearly (an option's delta is
             at most 1: an upper bound), ON TOP of what it covers for the other v2 series at their live caps
  pager      the pager's last run (within 3 minutes) read this vol feed (`volFeeds` in its state)
  keeper     v2's keeper reports this option among its `options`: it sweeps settleOptions at expiry. Without it, an
             expired account cannot be margined or liquidated once the last vol publish ages out
  fills      markets-service lists the option (asset_address)
  rfq        the RfqModule is not on the TradeModule's Matching

It NEVER signs, executes or broadcasts. Without --propose it prints the gates and the sheet. With --propose each action
goes to the MPCVault app for a human to approve, one at a time, from the vault, through perp_cap_guard.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL, ENGINE_V2_KEEPER_HEALTH_URL,
MARKETS_URL.

  python3 scripts/ops/propose_cngn_options_v2_batch.py cngn-options-setup             # check + sheet, proposes nothing
  python3 scripts/ops/propose_cngn_options_v2_batch.py cngn-options-setup --propose
  python3 scripts/ops/propose_cngn_options_v2_batch.py cngn-options-enable
  python3 scripts/ops/propose_cngn_options_v2_batch.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import propose_margin_engine_v2_batch as v2p  # noqa: E402  v2's proposer: its chain reads and gates
from check_perp_pager import SM_MOVE, sm_required_usd_linear  # noqa: E402
from perp_cap_guard import opens_a_perp_cap  # noqa: E402
from propose_cngn_spot_batch import EXPECTED_VAULT, gates_after_mining, load_env_file, rpc  # noqa: E402
from propose_perp_enable_batch import gate_pager as base_pager_gate, http_json  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

v1p = v2p.v1p
Gate, Chain, report = v1p.Gate, v1p.Chain, v1p.report
word_address, word_uint, digest = v1p.word_address, v1p.word_uint, v1p.digest

ROOT = v1p.ROOT
NAME = "CNGN_OPTIONS_V2"
ENGINE_NAME = v2p.NAME
FILES = {"cngn-options-setup": f"{NAME}_VAULT_ACTIONS.json", "cngn-options-enable": f"{NAME}_ENABLE_VAULT_ACTIONS.json"}
MARKET_ID = 1
OPTION, FUTURE = 1, v2p.FUTURE  # IMarginEngine.AssetType

MARGIN_FIELDS = ("maxSpotReq", "minSpotReq", "mmCallSpotReq", "mmPutSpotReq", "MMPutMtMReq", "unpairedIMScale",
                 "unpairedMMScale", "mmOffsetScale")
OC_FIELDS = ("perpThreshold", "optionThreshold", "baseThreshold", "OCFactor")

SIGNATURES = {
  **v2p.SIGNATURES,
  "whitelistAsset": "whitelistAsset(address,uint256,uint8)",
  "setOptionMarginParams":
    "setOptionMarginParams(uint256,(uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256))",
  "setOracleContingencyParams": "setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))",
  "setOraclesForMarket": "setOraclesForMarket(uint256,address,address,address)",
  "optionMarginParams": "optionMarginParams(uint256)",
  "settlementFeed": "settlementFeed()",
  "future": "future()",
  "getExpiryMinConfidence": "getExpiryMinConfidence(uint64)",
  "trustedRiskAssessor": "trustedRiskAssessor(address)",
  "quoteAsset": "quoteAsset()",
}
PINNED = {
  **v2p.PINNED,
  "whitelistAsset": "0xbd798569",
  "setOptionMarginParams": "0x60795bd2",
  "setOracleContingencyParams": "0xeab6bca1",
  "setOraclesForMarket": "0x675b0ebb",
  "optionMarginParams": "0xbe027d0a",
  "settlementFeed": "0xbb78c181",
  "future": "0xa2ec258f",
  "getExpiryMinConfidence": "0xd4435817",
  "trustedRiskAssessor": "0x5b75ad78",
  "quoteAsset": "0xfdf262b7",
}


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


def addr(chain: Chain, to: str, name: str) -> str:
  """An address getter, by this script's own pinned selectors (Chain.address reads v1's table)."""
  return "0x" + chain.call(to, selector(name))[24:64]


def owned(d: dict) -> list[str]:
  return [d["option"], d["volFeed"]]


# ---------------------------------------------------------------------------------------------
# the artifact batches
# ---------------------------------------------------------------------------------------------

def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as deploy-cngn-options-v2.s.sol writes them."""
  e, mk = d["manager"], word_uint(MARKET_ID)
  if batch == "cngn-options-setup":
    return [*[(c, selector("acceptOwnership")) for c in owned(d)],
            (e, selector("whitelistAsset") + word_address(d["option"]) + mk + word_uint(OPTION)),
            (e, selector("setOptionMarginParams") + mk + "".join(word_uint(int(d[f])) for f in MARGIN_FIELDS)),
            (e, selector("setOracleContingencyParams") + mk + "".join(word_uint(int(d[f])) for f in OC_FIELDS)),
            (e, selector("setOraclesForMarket") + mk + word_address(d["indexFeed"]) + word_address(d["forwardFeed"])
             + word_address(d["volFeed"]))]
  return [(d["option"], selector("setTotalPositionCap") + word_address(e) + word_uint(int(d["optionOICap"])))]


def market_feeds(chain: Chain, d: dict) -> tuple[str, str, str]:
  raw = chain.call(d["manager"], selector("getMarketFeeds") + word_uint(MARKET_ID))
  return tuple("0x" + raw[i * 64 + 24:(i + 1) * 64] for i in range(3))  # type: ignore[return-value]


def words(chain: Chain, to: str, data: str, n: int) -> list[int]:
  raw = chain.call(to, data)
  return [int(raw[i * 64:(i + 1) * 64], 16) for i in range(n)]


def option_on_market(chain: Chain, d: dict) -> str:
  return "0x" + chain.call(d["manager"], selector("assetMap") + word_uint(MARKET_ID) + word_uint(OPTION))[24:64]


def postconditions(chain: Chain, batch: str, d: dict, vault: str) -> list:
  """One read per action, aligned with expected_actions: whether it has landed."""
  mk = word_uint(MARKET_ID)
  if batch == "cngn-options-setup":
    return [*[(lambda c=c: addr(chain, c, "owner").lower() == vault.lower()) for c in owned(d)],
            lambda: option_on_market(chain, d).lower() == d["option"].lower(),
            lambda: words(chain, d["manager"], selector("optionMarginParams") + mk, 8) == [int(d[f]) for f in MARGIN_FIELDS],
            lambda: words(chain, d["manager"], selector("oracleContingencyParams") + mk, 4) == [int(d[f]) for f in OC_FIELDS],
            lambda: [a.lower() for a in market_feeds(chain, d)] == [d[k].lower() for k in ("indexFeed", "forwardFeed", "volFeed")]]
  return [lambda: chain.word(d["option"], selector("totalPositionCap") + word_address(d["manager"])) == int(d["optionOICap"])]


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
  """The artifact is for v2's NGN market and v2's cNGN future, from the engine artifact this directory holds."""
  if d["manager"].lower() != engine["manager"].lower():
    raise SystemExit(f"{NAME}.json names engine {d['manager']}, not {ENGINE_NAME}.json's {engine['manager']}")
  if int(d["marketId"]) != MARKET_ID:
    raise SystemExit(f"{NAME}.json is for market {d['marketId']}, not NGN ({MARKET_ID})")
  if d["future"].lower() != engine["future"].lower() or int(d["expiry"]) != int(engine["expiry"]):
    raise SystemExit(f"{NAME}.json settles against {d['future']} at {d['expiry']}, not v2's cNGN future")
  if d["indexFeed"].lower() != engine["indexFeed"].lower():
    raise SystemExit(f"{NAME}.json would write spot {d['indexFeed']} to market 1, not the cNGN index {engine['indexFeed']}")
  if int(d["minSpotReq"]) < 2 * 10**17 or int(d["mmPutSpotReq"]) < 10**17 or int(d["mmCallSpotReq"]) < 10**17:
    raise SystemExit(f"{NAME}.json: option margin under the floors (IM 20%, MM 10% of spot)")


# ---------------------------------------------------------------------------------------------
# gates
# ---------------------------------------------------------------------------------------------

def engine_gate(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  m, problems = d["manager"], []
  if addr(chain, m, "owner").lower() != vault.lower():
    problems.append("the vault does not own v2")
  if chain.word(m, selector("lastMarketId")) != 2:
    problems.append("v2 does not list exactly NGN and EUR")
  future = "0x" + chain.call(m, selector("assetMap") + word_uint(MARKET_ID) + word_uint(FUTURE))[24:64]
  if future.lower() != d["future"].lower():
    problems.append(f"market 1's future is {future}, not v2's cNGN future {d['future']}")
  listed = option_on_market(chain, d)
  if int(listed, 16) != 0 and listed.lower() != d["option"].lower():
    problems.append(f"market 1 already lists another option {listed}")
  if attached and listed.lower() != d["option"].lower():
    problems.append("market 1 does not list the option: cngn-options-setup has not landed")
  if chain.word(d["cash"], selector("whitelistedManager") + word_address(m)) != 1:
    problems.append("the cash does not take v2")
  return Gate("engine", not problems, "; ".join(problems) or "v2 is the vault's; market 1's future is v2's cNGN future; "
              "no other option listed")


def market1_problems(feeds: tuple[str, str, str], oc: list[int], future_forward: str, d: dict, attached: bool) -> list[str]:
  """What market 1 reads now against what the setup batch writes back. Before setup, only the spot and the
  non-option contingency params must match (forward and vol are still unset); after, all of them."""
  problems = []
  spot, forward, vol = (a.lower() for a in feeds)
  if spot != d["indexFeed"].lower():
    problems.append(f"market 1's spot feed is {spot}, the batch writes {d['indexFeed']}: it would replace it")
  for i, field in enumerate(OC_FIELDS):
    if field == "optionThreshold" and not attached:
      continue
    if oc[i] != int(d[field]):
      problems.append(f"market 1's {field} is {oc[i]}, the batch writes {d[field]}")
  if future_forward.lower() != d["forwardFeed"].lower():
    problems.append(f"the future's forward feed is {future_forward}, not the artifact's {d['forwardFeed']}")
  if attached and (forward != d["forwardFeed"].lower() or vol != d["volFeed"].lower()):
    problems.append(f"market 1 reads forward {forward}, vol {vol}: not the artifact's")
  return problems


def gate_market1(chain: Chain, d: dict, attached: bool) -> Gate:
  try:
    problems = market1_problems(market_feeds(chain, d),
                                words(chain, d["manager"], selector("oracleContingencyParams") + word_uint(MARKET_ID), 4),
                                addr(chain, d["future"], "forwardFeed"), d, attached)
  except Exception as exc:  # noqa: BLE001
    return Gate("market1", False, f"market 1 unreadable: {str(exc)[:80]}")
  return Gate("market1", not problems, "; ".join(problems) + (": redeploy, never hand-edit" if problems else "")
              or "market 1's spot, contingency params and forward are what the batch writes back")


def gate_venue(chain: Chain, d: dict) -> Gate:
  tm, problems = d["tradeModule"], []
  if addr(chain, tm, "quoteAsset").lower() != d["cash"].lower():
    problems.append("the TradeModule's quote is not v2 cash")
  if chain.word(d["manager"], selector("trustedRiskAssessor") + word_address(tm)):
    problems.append("the TradeModule is a trusted risk assessor: option writers would be held to MM, not IM")
  if chain.word(tm, selector("isDatedFutureAsset") + word_address(d["option"])):
    problems.append("the option is registered as a dated future: fills would carry no premium")
  return Gate("venue", not problems, "; ".join(problems) or "fills pay premium in v2 cash, held to IM")


def gate_series(chain: Chain, d: dict) -> Gate:
  sub = word_uint(int(d["expiry"]))
  listed = chain.word(d["future"], selector("futureContracts") + sub, 0)
  settled = chain.word(d["future"], selector("futureContracts") + sub, 1)
  expiry = chain.word(d["future"], selector("futureContracts") + sub, 2)
  ok = listed == 1 and settled == 0 and expiry == int(d["expiry"])
  return Gate("series", ok, f"the cNGN future lists {d['expiry']}, unsettled" if ok
              else f"the cNGN future at {d['expiry']}: listed {bool(listed)}, settled {bool(settled)}")


def gate_parity(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  """Every setting the deploy made, re-read against the artifact; once attached, the engine's too."""
  o, v, s = d["option"], d["volFeed"], d["settlementFeed"]
  w = lambda to, name, *args, index=0: chain.word(to, selector(name) + "".join(args), index)  # noqa: E731
  a = lambda to, name: addr(chain, to, name)  # noqa: E731
  pairs: list[tuple[str, object, object]] = [
    ("option settles on the adapter", a(o, "settlementFeed"), s),
    ("adapter reads the cNGN future", a(s, "future"), d["future"]),
    ("option whitelists v2", w(o, "whitelistedManager", word_address(d["manager"])), 1),
    ("vol signer", w(v, "isSigner", word_address(d["volSigner"])), 1),
    ("vol quorum", w(v, "requiredSigners"), 1),
    ("vol heartbeat", w(v, "heartbeat"), int(d["volHeartbeat"])),
    ("option OI fee", w(d["viewer"], "OIFeeRateBPS", word_address(o)), 0),
    ("deployer signs the vol", w(v, "isSigner", word_address(d["deployer"])), 0),
    ("deployer transactions since the deploy, unaudited",
     v2p.unaudited_deployer_txs(chain.url, d["deployer"], int(d["deployerNonce"])), 0),
  ]
  if attached:
    mk = word_uint(MARKET_ID)
    pairs += [("market 1's option", option_on_market(chain, d), o),
              ("option margin", words(chain, d["manager"], selector("optionMarginParams") + mk, 8),
               [int(d[f]) for f in MARGIN_FIELDS])]
  for c in owned(d):
    holder = a(c, "owner").lower() if attached else (a(c, "owner").lower(), a(c, "pendingOwner").lower())
    pairs.append((f"{c} is the vault's" if attached else f"{c} is nominated to the vault",
                  holder == vault.lower() if attached else vault.lower() in holder, True))
  bad = v1p.parity_mismatches(pairs)
  if bad:
    return Gate("parity", False, f"{len(bad)} setting(s) differ from the deploy: " + "; ".join(bad[:4]))
  return Gate("parity", True, f"all {len(pairs)} settings as deployed")


def gate_setup(chain: Chain, d: dict, vault: str) -> list[Gate]:
  pending = [c for c in owned(d) if vault.lower() not in
             (addr(chain, c, "owner").lower(), addr(chain, c, "pendingOwner").lower())]
  return [Gate("nominated", not pending, f"not nominated to the vault: {', '.join(pending)}" if pending
               else "the option and its vol feed nominated to or owned by the vault"),
          engine_gate(chain, d, vault, attached=False), gate_market1(chain, d, attached=False), gate_venue(chain, d),
          gate_series(chain, d), gate_parity(chain, d, vault, attached=False)]


def vol_problem(confidence: int | None, threshold: int) -> str | None:
  if confidence is None:
    return "no live vol surface for the expiry (missing or older than the heartbeat): is the vol publisher running?"
  if confidence < threshold:
    return f"vol confidence {confidence / 1e18:.2f} is under the option threshold {threshold / 1e18:.2f}: IM is penalised"
  return None


def gate_vol(chain: Chain, d: dict) -> Gate:
  try:
    confidence = chain.word(d["volFeed"], selector("getExpiryMinConfidence") + word_uint(int(d["expiry"])))
  except Exception:  # noqa: BLE001 -- the feed reverts when missing or stale
    confidence = None
  problem = vol_problem(confidence, int(d["optionThreshold"]))
  return Gate("vol", problem is None, problem or f"a live surface for {d['expiry']} at confidence {confidence / 1e18:.2f}")


def option_side_usd(cap_cngn: float, index_usdc: float) -> float:
  """One side of the option cap (the cap sums |balance|) in USDC, delta 1: an upper bound on an option's exposure."""
  return cap_cngn / 2 * index_usdc


def gate_sm(chain: Chain, d: dict, engine: dict, stack: dict, artifact_dir: Path) -> Gate:
  try:
    sm_cash = chain.balance(int(stack["securityModuleAccount"]), d["cash"]) / 1e18
    index = chain.word(d["indexFeed"], selector("getSpot")) / 1e18
    held_cngn = v2p.series_sm_usd(chain, engine)
    held_other, what = v2p.other_series_reserved(chain, artifact_dir)
    return v2p.sm_gate(sm_cash, option_side_usd(int(d["optionOICap"]) / 1e18, index), held_cngn + held_other,
                       "cNGN-30NOV26" + (f" and {what}" if what else "") + " at their caps")
  except Exception as exc:  # noqa: BLE001
    return Gate("sm", False, f"SecurityModule coverage unreadable: {str(exc)[:80]}")


def pager_reads_vol(state: dict, vol_feed: str) -> bool:
  return vol_feed.lower() in [str(f).lower() for f in state.get("volFeeds") or []]


def gate_pager(d: dict) -> Gate:
  state_file = v2p.pager_state()
  base = base_pager_gate(state_file, future_manager=d["manager"])
  if not base.ok:
    return base
  if not pager_reads_vol(json.loads(state_file.read_text()), d["volFeed"]):
    return Gate("pager", False, f"the pager's last run did not read the vol feed {d['volFeed']} (`volFeeds` in its "
                                "state): a stale surface would halt option accounts unpaged")
  return Gate("pager", True, base.detail + f", and the vol feed {d['volFeed']}")


def keeper_sweeps(health: dict, option: str) -> bool:
  return option.lower() in [str(o).lower() for o in health.get("options") or []]


def gate_keeper(d: dict) -> Gate:
  url = os.environ.get("ENGINE_V2_KEEPER_HEALTH_URL", "")
  if not url:
    return Gate("keeper", False, "ENGINE_V2_KEEPER_HEALTH_URL is not set")
  try:
    health = http_json(url)
  except Exception as exc:  # noqa: BLE001
    return Gate("keeper", False, f"the keeper's health unreadable: {str(exc)[:80]}")
  if not keeper_sweeps(health, d["option"]):
    return Gate("keeper", False, f"the keeper does not report the option {d['option']} among its `options`: nothing "
                                 "would call settleOptions at expiry")
  return Gate("keeper", True, f"the keeper sweeps settleOptions for {d['option']}")


def listing_for(entries: list[dict], option: str) -> dict | None:
  return next((e for e in entries if str(e.get("asset_address", "")).lower() == option.lower()), None)


def gate_fills(d: dict, markets_url: str) -> Gate:
  try:
    listing = listing_for(v2p.markets(markets_url), d["option"])
  except Exception as exc:  # noqa: BLE001
    return Gate("fills", False, f"markets-service /v1/markets unreadable: {str(exc)[:80]}")
  if listing is None:
    return Gate("fills", False, f"markets-service does not list the option {d['option']}")
  return Gate("fills", True, f"markets-service lists the option as {listing.get('market')!r}")


def gate_enable(chain: Chain, d: dict, engine: dict, stack: dict, vault: str, artifact_dir: Path) -> list[Gate]:
  m = word_address(d["manager"])
  not_owned = [c for c in owned(d) if addr(chain, c, "owner").lower() != vault.lower()]
  unwired = [i for i, holds in enumerate(postconditions(chain, "cngn-options-setup", d, vault)) if not holds()]
  cap = chain.word(d["option"], selector("totalPositionCap") + m)
  problems = ([f"vault does not own {', '.join(not_owned)}"] if not_owned else []) + \
             ([f"cngn-options-setup actions {unwired} have not landed"] if unwired else []) + \
             ([f"the option is not closed (cap {cap})"] if cap else [])
  return [Gate("custody", not problems, "; ".join(problems) or "vault owns both; setup landed; the option closed"),
          engine_gate(chain, d, vault, attached=True), gate_market1(chain, d, attached=True), gate_venue(chain, d),
          gate_series(chain, d), gate_vol(chain, d), gate_sm(chain, d, engine, stack, artifact_dir), gate_pager(d),
          gate_keeper(d), gate_fills(d, os.environ.get("MARKETS_URL", "https://api.numofx.com")),
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
  e17, e18 = 10**17, 10**18
  d = {"manager": a(1), "option": a(3), "volFeed": a(4), "settlementFeed": a(5), "indexFeed": a(6), "forwardFeed": a(7),
       "future": a(8), "tradeModule": a(9), "cash": a(10), "marketId": 1, "expiry": 1796047200,
       "optionOICap": str(30_000_000 * e18),
       "maxSpotReq": str(3 * e17), "minSpotReq": str(25 * 10**16), "mmCallSpotReq": str(15 * 10**16),
       "mmPutSpotReq": str(15 * 10**16), "MMPutMtMReq": str(5 * e17), "unpairedIMScale": str(12 * e17),
       "unpairedMMScale": str(11 * e17), "mmOffsetScale": str(105 * 10**16),
       "perpThreshold": str(55 * 10**16), "optionThreshold": str(8 * e17), "baseThreshold": str(55 * 10**16),
       "OCFactor": str(e18)}
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
      "added": lambda acts: acts.append(dict(acts[0])),
    }
    for what, mutate in broken.items():
      acts = json.loads(json.dumps(good))
      mutate(acts)
      try:
        verify_actions(batch, d, acts)
      except SystemExit:
        continue
      raise AssertionError(f"{batch}: a wrong {what} was accepted")

  setup = expected_actions("cngn-options-setup", d)
  margin = "".join(word_uint(v) for v in (3 * e17, 25 * 10**16, 15 * 10**16, 15 * 10**16, 5 * e17, 12 * e17, 11 * e17,
                                          105 * 10**16))
  oc = "".join(word_uint(v) for v in (55 * 10**16, 8 * e17, 55 * 10**16, e18))
  assert setup == [
    (a(3), "0x79ba5097"), (a(4), "0x79ba5097"),
    (a(1), "0xbd798569" + word_address(a(3)) + word_uint(1) + word_uint(1)),
    (a(1), "0x60795bd2" + word_uint(1) + margin),
    (a(1), "0xeab6bca1" + word_uint(1) + oc),
    (a(1), "0x675b0ebb" + word_uint(1) + word_address(a(6)) + word_address(a(7)) + word_address(a(4))),
  ], setup
  enable = expected_actions("cngn-options-enable", d)
  assert enable == [(a(3), "0x40a557bd" + word_address(a(1)) + word_uint(30_000_000 * e18))], enable
  for to, data in setup + enable:
    assert not opens_a_perp_cap({"to": to, "data": data}), (to, data[:10])

  # The artifact: v2's NGN market, its future and index, margin over the floors.
  engine = {"manager": a(1), "future": a(8), "expiry": 1796047200, "indexFeed": a(6)}
  check_artifact(d, engine)
  for bad in ({"marketId": 2}, {"future": a(2)}, {"expiry": 1796054400}, {"indexFeed": a(2)}, {"manager": a(2)},
              {"minSpotReq": str(e17)}, {"mmPutSpotReq": str(5 * 10**16)}):
    try:
      check_artifact({**d, **bad}, engine)
    except SystemExit:
      continue
    raise AssertionError(f"artifact {bad} accepted")

  # market1: a spot that moved, or a contingency param that moved, is refused; before setup the option threshold and
  # the unset forward and vol are expected to differ.
  live = (a(6), "0x" + "0" * 40, "0x" + "0" * 40)
  live_oc = [55 * 10**16, 55 * 10**16, 55 * 10**16, e18]
  assert market1_problems(live, live_oc, a(7), d, attached=False) == []
  assert market1_problems((a(2), *live[1:]), live_oc, a(7), d, attached=False), "a moved spot feed is refused"
  assert market1_problems(live, [55 * 10**16, 55 * 10**16, 55 * 10**16, e18 // 2], a(7), d, attached=False), \
    "a moved OCFactor is refused"
  assert market1_problems(live, live_oc, a(2), d, attached=False), "a future reading another forward is refused"
  assert market1_problems(live, live_oc, a(7), d, attached=True), "after setup, unset forward and vol are refused"
  assert market1_problems((a(6), a(7), a(4)), [55 * 10**16, 8 * e17, 55 * 10**16, e18], a(7), d, attached=True) == []

  # vol: missing or stale, or under the threshold, fails
  assert vol_problem(None, 8 * e17) and vol_problem(5 * e17, 8 * e17) and vol_problem(e18, 8 * e17) is None
  # SecurityModule: 30M cNGN both sides at 0.00072 is a $10,800 side, a 15% step $1,620
  assert abs(sm_required_usd_linear(option_side_usd(30_000_000, 0.00072)) - 1_620) < 1e-6 and SM_MOVE == 0.15
  assert v2p.sm_gate(3_250, option_side_usd(30_000_000, 0.00072), 1_604.84, "cNGN").ok
  assert not v2p.sm_gate(3_250, option_side_usd(32_000_000, 0.00072), 1_604.84, "cNGN").ok
  # pager, keeper and listing must name the option's own contracts
  assert pager_reads_vol({"volFeeds": [a(4).upper()]}, a(4)) and not pager_reads_vol({}, a(4))
  assert keeper_sweeps({"options": [a(3)]}, a(3)) and not keeper_sweeps({"futures": [a(3)]}, a(3))
  assert listing_for([{"asset_address": a(3).upper(), "market": "cNGN-30NOV26-P"}], a(3)) is not None
  assert listing_for([{"asset_address": a(8)}], a(3)) is None

  import inspect
  for fn in (main, run_batch):
    assert "propose(token" not in inspect.getsource(fn), f"{fn.__name__} calls propose() directly"
  print("self-test ok: selectors compiled and pinned; a wrong target, calldata, value, digest or count is refused; a "
        "moved spot feed or contingency param is refused; vol, SecurityModule, pager, keeper and listing gates read the "
        "option's own contracts")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def run_batch(args, d: dict, engine: dict, stack: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  actions = json.loads((args.dir / FILES[args.batch]).read_text())
  verify_actions(args.batch, d, actions)

  def gates() -> list[Gate]:
    if args.batch == "cngn-options-setup":
      return gate_setup(chain, d, vault)
    return gate_enable(chain, d, engine, stack, vault, args.dir)

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
    # Re-read before each: market 1 above all. Mid-setup, the attached-only checks are not yet expected to hold.
    if i > first:
      again = gates_after_mining(gates)
      if not report(again):
        raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    v2p.await_approval(token, vault_uuid, vault, a, rpc_url, holds[i])
  print(f"\n{args.batch}: done.")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose cNGN options' vault batches on MarginEngine v2")
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
    ap.error("name a batch: cngn-options-setup or cngn-options-enable")

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
    raise SystemExit(f"{artifact} does not exist: cNGN options are not deployed (deploy-cngn-options-v2.s.sol writes it)")
  d = json.loads(artifact.read_text())
  engine = json.loads((args.dir / f"{ENGINE_NAME}.json").read_text())
  check_artifact(d, engine)
  return run_batch(args, d, engine, json.loads(args.stack.read_text()), Chain(rpc_url), rpc_url, vault)


if __name__ == "__main__":
  raise SystemExit(main())
