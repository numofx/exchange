#!/usr/bin/env python3
"""Propose the OnchainBook's vault batches for EURC-30NOV26 (docs/eurc-usdc-futures-spec.md, B12, B15).

  book-setup   ONCHAIN_BOOK_VAULT_ACTIONS.json, from deploy-onchain-book.s.sol: accept the book, allow the maker
               (MAKER_OWNER, the owner of its account outside Matching). Opens nothing: the market stays disabled.
  book-enable  ONCHAIN_BOOK_ENABLE_VAULT_ACTIONS.json: setMarketParams with the deployed parameters and enabled.

Every action is rebuilt here from ONCHAIN_BOOK.json and must match the file exactly (to, calldata, value), digest
recomputed (keccak(to || keccak(data))). Every action is on the book: the engine and the future are not touched. An
action whose postcondition already holds is skipped. Gates are re-read before every action.

Setup gates (all read live, all required):
  nominated  the book is nominated to (or owned by) the vault
  series     the engine's EUR future is the artifact's; the series is listed, unsettled, with over 2 h to last trade
  parity     every setting the deploy made: the book's SubAccounts, cash, fee account (and that it is the
             TradeModule's), gas floor, tax 0, one market on the artifact's series, adapter, tick, lot, fee, ages and
             cap, disabled; the engine neither trusts nor fee-bypasses the book (B4); the deployer has sent nothing
             unaudited since

Enable gates (all read live, all required unless marked):
  custody    the vault owns the book; the maker is allowed; the market is still disabled
  series     as at setup, and the series' cap on the engine is above 0 (the book cannot fill a closed series)
  index      EurcIndexFeed answers: the v3 keeper is posting reports
  fee        the book's taker fee is the instruments registry's taker_fee_bps for the series, read from markets-service
             /markets: the fee schedule has one source (the book's copy is checked, never chosen here)
  makers     informational: makers registered and splines live
  parity     as at setup, owned by the vault

It NEVER signs, executes or broadcasts. Without --propose it prints the gates and the sheet. With --propose each action
goes to the MPCVault app for a human to approve, one at a time, from the vault.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL, MARKETS_URL.

  python3 scripts/ops/propose_onchain_book_batch.py book-setup             # check + sheet, proposes nothing
  python3 scripts/ops/propose_onchain_book_batch.py book-setup --propose
  python3 scripts/ops/propose_onchain_book_batch.py book-enable
  python3 scripts/ops/propose_onchain_book_batch.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import propose_margin_engine_v2_batch as v2p  # noqa: E402
from propose_cngn_spot_batch import EXPECTED_VAULT, gates_after_mining, load_env_file, rpc  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

v1p = v2p.v1p
Gate, Chain, report = v1p.Gate, v1p.Chain, v1p.report
word_address, word_uint, digest = v1p.word_address, v1p.word_uint, v1p.digest

ROOT = v1p.ROOT
NAME = "ONCHAIN_BOOK"
SETUP, ENABLE = "book-setup", "book-enable"
FILES = {SETUP: f"{NAME}_VAULT_ACTIONS.json", ENABLE: f"{NAME}_ENABLE_VAULT_ACTIONS.json"}
EUR_MARKET = 2
FUTURE = 4  # IMarginEngine.AssetType.Future
BOOK_MARKET = 1
MIN_LEAD_SEC = 2 * 3600

SIGNATURES = {
  "acceptOwnership": "acceptOwnership()",
  "setMakerAllowed": "setMakerAllowed(address,bool)",
  "setMarketParams": "setMarketParams(uint256,uint256,uint32,uint32,uint16,bool)",
  "owner": "owner()",
  "pendingOwner": "pendingOwner()",
  "makerAllowed": "makerAllowed(address)",
  "markets": "markets(uint256)",
  "feeRecipient": "feeRecipient()",
  "gasFloor": "gasFloor()",
  "priorityTaxRate": "priorityTaxRate()",
  "nextMarketId": "nextMarketId()",
  "subAccounts": "subAccounts()",
  "cash": "cash()",
  "trustedRiskAssessor": "trustedRiskAssessor(address)",
  "feeBypassedCaller": "feeBypassedCaller(address)",
  "getSpot": "getSpot()",
  "totalPositionCap": "totalPositionCap(address)",
  "assetMap": "assetMap(uint256,uint8)",
  "futureContracts": "futureContracts(uint256)",
  "makers": "makers(uint256)",
  "splines": "splines(uint256,uint256)",
}
PINNED = {
  "acceptOwnership": "0x79ba5097", "setMakerAllowed": "0x4db8b77b", "setMarketParams": "0x9910da7d",
  "owner": "0x8da5cb5b", "pendingOwner": "0xe30c3978", "makerAllowed": "0x4b3df9c5", "markets": "0xb1283e77",
  "feeRecipient": "0x46904840", "gasFloor": "0xfed976f7", "priorityTaxRate": "0x04ca4326",
  "nextMarketId": "0x406ef2ef", "subAccounts": "0x779e5012", "cash": "0x961be391",
  "trustedRiskAssessor": "0x5b75ad78", "feeBypassedCaller": "0x3f210eea", "getSpot": "0x2b37269c",
  "totalPositionCap": "0x745ab570", "assetMap": "0xed75d3f3", "futureContracts": "0xc3c74b34",
  "makers": "0x33f02fa2", "splines": "0xe5dd8989",
}
# OnchainBook.Market, as markets(uint256) returns it: field -> word index
MARKET_WORDS = {"future": 0, "engine": 1, "subId": 2, "expiry": 3, "lastTradeTime": 4, "adapter": 5, "tickSize": 6,
                "lotSize": 7, "takerFeeRate": 8, "takeMaxAge": 9, "maxTtl": 10, "maxMakers": 11, "enabled": 12}


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


# ---------------------------------------------------------------------------------------------
# the artifact batches
# ---------------------------------------------------------------------------------------------

def enable_calldata(d: dict) -> str:
  return (selector("setMarketParams") + word_uint(BOOK_MARKET) + word_uint(int(d["takerFeeRate"]))
          + word_uint(int(d["takeMaxAge"])) + word_uint(int(d["maxTtl"])) + word_uint(int(d["maxMakers"])) + word_uint(1))


def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as deploy-onchain-book.s.sol writes them."""
  book = d["book"]
  if batch == SETUP:
    return [(book, selector("acceptOwnership")),
            (book, selector("setMakerAllowed") + word_address(d["makerOwner"]) + word_uint(1))]
  return [(book, enable_calldata(d))]


def market_word(chain: Chain, d: dict, field: str) -> int:
  return chain.word(d["book"], selector("markets") + word_uint(BOOK_MARKET), MARKET_WORDS[field])


def postconditions(chain: Chain, batch: str, d: dict, vault: str) -> list:
  book = d["book"]
  if batch == SETUP:
    return [lambda: chain.address(book, "owner").lower() == vault.lower(),
            lambda: chain.word(book, selector("makerAllowed") + word_address(d["makerOwner"])) == 1]
  return [lambda: market_word(chain, d, "enabled") == 1]


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


def check_artifact(d: dict, series: dict) -> None:
  """The book's market is the recorded EURC v3 series, on its engine and adapter."""
  for key, other in (("future", "future"), ("manager", "manager"), ("adapter", "adapter"), ("indexFeed", "indexFeed"),
                     ("cash", "cash"), ("tradeModule", "tradeModule")):
    if d[key].lower() != series[other].lower():
      raise SystemExit(f"{NAME}.json {key} {d[key]} is not EURC_FUTURE_V3.json's {series[other]}")
  if int(d["subId"]) != int(series["subId"]) or int(d["lastTradeTime"]) != int(series["lastTradeTime"]):
    raise SystemExit(f"{NAME}.json is not on the series {series['subId']}")
  if int(d["bookMarketId"]) != BOOK_MARKET:
    raise SystemExit(f"{NAME}.json: the book's market is {d['bookMarketId']}, not {BOOK_MARKET}")
  if int(d["priorityTaxRate"]) != 0:
    raise SystemExit(f"{NAME}.json: the priority tax is on (B12: off at rollout)")
  if int(d["takerFeeRate"]) > 10**16:
    raise SystemExit(f"{NAME}.json: taker fee {d['takerFeeRate']} over 1%")


# ---------------------------------------------------------------------------------------------
# gates
# ---------------------------------------------------------------------------------------------

def series_verdict(listed_future: str, future: str, listed: int, settled: int, last_trade: int, now: int,
                   cap: int | None) -> Gate:
  problems = ([f"EUR's future is {listed_future}, not {future}"] if listed_future.lower() != future.lower() else []) + \
             (["the series is not listed"] if not listed else []) + (["the series has settled"] if settled else []) + \
             ([f"{(last_trade - now) / 3600:.1f} h to last trade (under 2 h)"] if last_trade - now < MIN_LEAD_SEC else []) + \
             (["the series is closed on the engine (cap 0)"] if cap == 0 else [])
  return Gate("series", not problems, "; ".join(problems) or
              f"EUR's future, listed, {(last_trade - now) / 3600:.1f} h to last trade" + ("" if cap is None else ", open"))


def gate_series(chain: Chain, d: dict, need_open: bool) -> Gate:
  try:
    s = word_uint(int(d["subId"]))
    listed_future = "0x" + chain.call(d["manager"], selector("assetMap") + word_uint(EUR_MARKET) + word_uint(FUTURE))[24:64]
    cap = chain.word(d["future"], selector("totalPositionCap") + word_address(d["manager"])) if need_open else None
    return series_verdict(listed_future, d["future"], chain.word(d["future"], selector("futureContracts") + s, 0),
                          chain.word(d["future"], selector("futureContracts") + s, 1),
                          chain.word(d["future"], selector("futureContracts") + s, 3), chain.head(), cap)
  except Exception as exc:  # noqa: BLE001 -- unreadable holds
    return Gate("series", False, f"the series unreadable: {str(exc)[:120]}")


def gate_parity(chain: Chain, d: dict, vault: str, attached: bool) -> Gate:
  book = d["book"]
  w = lambda to, name, *args: chain.word(to, selector(name) + "".join(args))  # noqa: E731
  a = lambda to, name, *args: "0x" + chain.call(to, selector(name) + "".join(args))[24:64]  # noqa: E731
  mk = lambda field: market_word(chain, d, field)  # noqa: E731
  addr = lambda field: "0x" + format(mk(field), "040x")  # noqa: E731
  pairs: list[tuple[str, object, object]] = [
    ("book subAccounts", a(book, "subAccounts"), d["subAccounts"]),
    ("book cash", a(book, "cash"), d["cash"]),
    ("book fee account", w(book, "feeRecipient"), int(d["feeRecipient"])),
    ("the TradeModule's fee account", w(d["tradeModule"], "feeRecipient"), int(d["feeRecipient"])),
    ("book gas floor", w(book, "gasFloor"), int(d["gasFloor"])),
    ("book priority tax", w(book, "priorityTaxRate"), 0),
    ("book markets", w(book, "nextMarketId"), BOOK_MARKET + 1),
    ("market future", addr("future"), d["future"]),
    ("market engine", addr("engine"), d["manager"]),
    ("market subId", mk("subId"), int(d["subId"])),
    ("market last trade", mk("lastTradeTime"), int(d["lastTradeTime"])),
    ("market adapter", addr("adapter"), d["adapter"]),
    ("market tick", mk("tickSize"), int(d["tickSize"])),
    ("market lot", mk("lotSize"), int(d["lotSize"])),
    ("market fee", mk("takerFeeRate"), int(d["takerFeeRate"])),
    ("market take max age", mk("takeMaxAge"), int(d["takeMaxAge"])),
    ("market ttl cap", mk("maxTtl"), int(d["maxTtl"])),
    ("market makers cap", mk("maxMakers"), int(d["maxMakers"])),
    # B4: the engine grants the book nothing
    ("engine trusts the book", w(d["manager"], "trustedRiskAssessor", word_address(book)), 0),
    ("engine fee-bypasses the book", w(d["manager"], "feeBypassedCaller", word_address(book)), 0),
    ("deployer transactions since the deploy, unaudited",
     v2p.unaudited_deployer_txs(chain.url, d["deployer"], int(d["deployerNonce"])), 0),
  ]
  holder = a(book, "owner").lower() if attached else (a(book, "owner").lower(), a(book, "pendingOwner").lower())
  pairs.append(("the book is the vault's" if attached else "the book is nominated to the vault",
                holder == vault.lower() if attached else vault.lower() in holder, True))
  bad = v1p.parity_mismatches(pairs)
  if bad:
    return Gate("parity", False, f"{len(bad)} setting(s) differ from the deploy: " + "; ".join(bad[:4]))
  return Gate("parity", True, f"all {len(pairs)} settings as deployed; deployer {d['deployer']} has sent nothing unaudited since")


def gate_setup(chain: Chain, d: dict, vault: str) -> list[Gate]:
  holders = (chain.address(d["book"], "owner").lower(), chain.address(d["book"], "pendingOwner").lower())
  return [Gate("nominated", vault.lower() in holders, "the book nominated to or owned by the vault"
               if vault.lower() in holders else f"the book is not nominated to the vault (owner, pending: {holders})"),
          gate_series(chain, d, need_open=False), gate_parity(chain, d, vault, attached=False)]


def fee_verdict(listing: dict | None, book_rate: int) -> Gate:
  if listing is None:
    return Gate("fee", False, "the series is not on markets-service /markets: no registry fee to check the book against")
  if listing.get("taker_fee_bps") is None:
    return Gate("fee", False, "markets-service lists no taker_fee_bps for the series: unknown, not zero")
  registry = int(listing["taker_fee_bps"]) * 10**14
  if registry != book_rate:
    return Gate("fee", False, f"the book charges {book_rate / 1e14:g} bps, the registry {listing['taker_fee_bps']} bps: "
                              "redeploy, or change the registry first")
  return Gate("fee", True, f"{listing['taker_fee_bps']} bps, as the instruments registry")


def gate_fee(chain: Chain, d: dict, markets_url: str) -> Gate:
  try:
    listing = v2p.find_listing(v2p.markets(markets_url), d["future"], d["subId"])
  except Exception as exc:  # noqa: BLE001
    return Gate("fee", False, f"markets-service /markets unreadable: {str(exc)[:80]}")
  try:
    return fee_verdict(listing, market_word(chain, d, "takerFeeRate"))
  except Exception as exc:  # noqa: BLE001
    return Gate("fee", False, f"the book's fee unreadable: {str(exc)[:80]}")


def makers_verdict(splines: list[tuple[int, int, int]], now: int) -> Gate:
  """Informational: opening with no maker fills nothing, harmlessly. (active, updatedAt, ttl) per registered maker."""
  live = sum(1 for active, updated, ttl in splines if active and now <= updated + ttl)
  return Gate("makers", True, f"{len(splines)} maker(s) registered, {live} spline(s) live"
              + ("" if live else ": takes will fill nothing until a maker quotes"))


def gate_makers(chain: Chain, d: dict) -> Gate:
  try:
    raw = chain.call(d["book"], selector("makers") + word_uint(BOOK_MARKET))
    n = int(raw[64:128], 16)
    accounts = [int(raw[128 + 64 * i:192 + 64 * i], 16) for i in range(n)]
    sp = [(chain.word(d["book"], selector("splines") + word_uint(BOOK_MARKET) + word_uint(acc), 10),
           chain.word(d["book"], selector("splines") + word_uint(BOOK_MARKET) + word_uint(acc), 7),
           chain.word(d["book"], selector("splines") + word_uint(BOOK_MARKET) + word_uint(acc), 8)) for acc in accounts]
    return makers_verdict(sp, chain.head())
  except Exception as exc:  # noqa: BLE001
    return Gate("makers", True, f"makers unreadable ({str(exc)[:80]})")


def gate_index(chain: Chain, d: dict) -> Gate:
  try:
    return Gate("index", True, f"EURC/USDC index {chain.word(d['indexFeed'], selector('getSpot')) / 1e18:.6f}")
  except Exception as exc:  # noqa: BLE001
    return Gate("index", False, f"EurcIndexFeed reverts ({str(exc)[:80]}): is the v3 keeper posting reports?")


def gate_enable(chain: Chain, d: dict, vault: str, markets_url: str) -> list[Gate]:
  problems = []
  if chain.address(d["book"], "owner").lower() != vault.lower():
    problems.append("the vault does not own the book")
  if chain.word(d["book"], selector("makerAllowed") + word_address(d["makerOwner"])) != 1:
    problems.append(f"the maker {d['makerOwner']} is not allowed: {SETUP} has not landed")
  if market_word(chain, d, "enabled"):
    problems.append("the market is already enabled")
  return [Gate("custody", not problems, "; ".join(problems) or "the vault owns the book; the maker allowed; disabled"),
          gate_series(chain, d, need_open=True), gate_index(chain, d), gate_fee(chain, d, markets_url),
          gate_makers(chain, d), gate_parity(chain, d, vault, attached=True)]


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
  d = {"book": a(5), "makerOwner": a(6), "takerFeeRate": str(5 * 10**14), "takeMaxAge": 1, "maxTtl": 3600,
       "maxMakers": 10}
  for batch in FILES:
    good = [{"description": str(i), "to": to, "value": "0", "data": data, "digest": digest(to, data)}
            for i, (to, data) in enumerate(expected_actions(batch, d))]
    verify_actions(batch, d, good)
    broken = {
      "target": lambda acts: acts[0].update(to=a(99)),
      "calldata": lambda acts: acts[-1].update(data=acts[-1]["data"][:-1] + "0"),
      "value": lambda acts: acts[0].update(value="1"),
      "digest": lambda acts: acts[0].update(digest="0x" + "00" * 32),
      "dropped": lambda acts: acts.pop(),
      "added": lambda acts: acts.append(dict(acts[0])),
    }
    if len(good) > 1:
      broken["reordered"] = lambda acts: acts.reverse()
    for what, mutate in broken.items():
      acts = json.loads(json.dumps(good))
      mutate(acts)
      try:
        verify_actions(batch, d, acts)
      except SystemExit:
        continue
      raise AssertionError(f"{batch}: a wrong {what} was accepted")

  # the calldata, word by word, as deploy-onchain-book.s.sol encodes it (cast calldata, 2026-11-16)
  assert expected_actions(SETUP, d) == [(a(5), "0x79ba5097"), (a(5), "0x4db8b77b" + word_address(a(6)) + word_uint(1))]
  assert expected_actions(ENABLE, d) == [(a(5), "0x9910da7d" + word_uint(1) + word_uint(5 * 10**14) + word_uint(1)
                                          + word_uint(3600) + word_uint(10) + word_uint(1))]

  # each postcondition reads what its own action writes
  vault = a(77)

  class Reads:
    def __init__(self, state): self.state = state
    def word(self, to, data, index=0):
      key = (to.lower(), data[:10])
      return self.state.get(key, 0) if index == 0 else self.state.get(key + (index,), 0)
    def address(self, to, name): return vault if self.state.get((to.lower(), "owner")) else a(0)
  for landed in range(3):
    state = {}
    if landed >= 1:
      state[(a(5), "owner")] = 1
    if landed >= 2:
      state[(a(5), selector("makerAllowed"))] = 1
    got = [h() for h in postconditions(Reads(state), SETUP, d, vault)]
    assert got == [i < landed for i in range(2)], (landed, got)
  assert [h() for h in postconditions(Reads({}), ENABLE, d, vault)] == [False]
  assert [h() for h in postconditions(Reads({(a(5), selector("markets"), 12): 1}), ENABLE, d, vault)] == [True]

  # the artifact must be on the recorded series
  series = {"future": a(1), "manager": a(2), "adapter": a(3), "indexFeed": a(4), "cash": a(7), "tradeModule": a(8),
            "subId": 1796050800, "lastTradeTime": 1796049000}
  full = {**d, **series, "bookMarketId": 1, "priorityTaxRate": 0}
  check_artifact(full, series)
  for bad in ({"future": a(9)}, {"manager": a(9)}, {"adapter": a(9)}, {"subId": 1}, {"bookMarketId": 2},
              {"priorityTaxRate": 1}, {"takerFeeRate": str(10**16 + 1)}):
    try:
      check_artifact({**full, **bad}, series)
    except SystemExit:
      continue
    raise AssertionError(f"artifact {bad} accepted")

  # the series: the engine's, listed, unsettled, time left, open at enable
  now, last = 1_794_787_554, 1_796_049_000
  assert series_verdict(a(1), a(1), 1, 0, last, now, None).ok
  assert series_verdict(a(1), a(1), 1, 0, last, now, 5).ok
  for args in ((a(2), a(1), 1, 0, last, now, None), (a(1), a(1), 0, 0, last, now, None), (a(1), a(1), 1, 1, last, now, None),
               (a(1), a(1), 1, 0, now + MIN_LEAD_SEC - 1, now, None), (a(1), a(1), 1, 0, last, now, 0)):
    assert not series_verdict(*args).ok, args

  # the fee is the registry's: equal passes; a different, missing or absent one holds
  assert fee_verdict({"taker_fee_bps": 5}, 5 * 10**14).ok
  assert fee_verdict({"taker_fee_bps": 0}, 0).ok, "a zero fee in the registry is a fact"
  assert not fee_verdict({"taker_fee_bps": 5}, 4 * 10**14).ok
  assert not fee_verdict({}, 0).ok, "absent is unknown, not zero"
  assert not fee_verdict(None, 5 * 10**14).ok

  # makers are reported, never block
  assert makers_verdict([], now).ok and "fill nothing" in makers_verdict([], now).detail
  m = makers_verdict([(1, now - 10, 3600), (1, now - 7200, 3600), (0, now, 3600)], now)
  assert m.ok and "3 maker(s) registered, 1 spline(s) live" in m.detail, m.detail

  import inspect
  for fn in (main, run_batch):
    assert "propose(token" not in inspect.getsource(fn), f"{fn.__name__} calls propose() directly"
  print("self-test ok: selectors compiled and pinned; a wrong target, calldata, value, digest, count or order is refused; "
        "the artifact must be on the recorded series with the tax off; the series must be the engine's, listed, open "
        "and over 2 h from last trade; the book's fee must equal the registry's")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def run_batch(args, d: dict, chain: Chain, rpc_url: str, vault: str, markets_url: str) -> int:
  actions = json.loads((args.dir / FILES[args.batch]).read_text())
  verify_actions(args.batch, d, actions)

  def gates() -> list[Gate]:
    return gate_setup(chain, d, vault) if args.batch == SETUP else gate_enable(chain, d, vault, markets_url)

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
    if i > first:
      # After acceptOwnership the nomination is consumed: the setup gates read "owned" through the same check.
      again = gates_after_mining(gates)
      if not report(again):
        raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    v2p.await_approval(token, vault_uuid, vault, a, rpc_url, holds[i])
  print(f"\n{args.batch}: done." + (f" {d['symbol']} is open on the OnchainBook." if args.batch == ENABLE else ""))
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the OnchainBook's vault batches")
  ap.add_argument("batch", nargs="?", choices=tuple(FILES))
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--dir", type=Path, default=ROOT / "deployments" / "8453", help="where the deploys wrote their artifacts")
  ap.add_argument("--json", action="store_true", help="print the gates as JSON on the last line")
  args = ap.parse_args()

  if args.self_test:
    return self_test()
  if not args.batch:
    ap.error("name a batch: " + ", ".join(FILES))

  load_env_file(Path.home() / ".numo-mark-keeper.env")
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
    raise SystemExit(f"{artifact} does not exist: the book is not deployed (deploy-onchain-book.s.sol writes it)")
  d = json.loads(artifact.read_text())
  check_artifact(d, json.loads((args.dir / "EURC_FUTURE_V3.json").read_text()))
  return run_batch(args, d, Chain(rpc_url), rpc_url, vault, os.environ.get("MARKETS_URL", "https://api.numofx.com"))


if __name__ == "__main__":
  raise SystemExit(main())
