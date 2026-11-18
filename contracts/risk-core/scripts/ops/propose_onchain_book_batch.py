#!/usr/bin/env python3
"""Propose the OnchainBook's vault batches (docs/eurc-usdc-futures-spec.md, B12, B15, C6).

  --version 2 (default): ONCHAIN_BOOK_V2*.json, the v2 book (quote, self-priced splines) and its router, on the
                         series EXPIRY chose at deploy. Its parity also covers the self-priced cap the deployer set
                         (maxSelfPricedTtl, 60 s) and the router (on this book and cash).
  --version 1:           ONCHAIN_BOOK*.json, EURC-30NOV26's v1 book (both batches landed 2026-11-16).

  book-setup   <NAME>_VAULT_ACTIONS.json, from deploy-onchain-book.s.sol: accept the book, allow the maker
               (MAKER_OWNER, the owner of its account outside Matching). Opens nothing: the market stays disabled.
  book-enable  <NAME>_ENABLE_VAULT_ACTIONS.json: setMarketParams with the deployed parameters and enabled.

  --market N --expiry E (v2, N > 1): a further series on the same book, with no deploy. Its actions are built here
  from <NAME>.json's parameters (tick, lot, fee, ages, makers cap, self-priced cap) and E, not read from a file:
  book-add-market  createMarket(future, E, engine, adapter, tick, lot), setMarketParams(N, ..., disabled),
                   setSelfPricedTtlCap(N, cap). Opens nothing.
  book-enable      setMarketParams(N, ..., enabled), under the enable gates on market N.
  The maker needs no new allowance (allowances are per book) and registers itself (registerMaker(N, account)).

Every action is rebuilt here from <NAME>.json and must match the file exactly (to, calldata, value), digest
recomputed (keccak(to || keccak(data))). Every action is on the book: the engine and the future are not touched. An
action whose postcondition already holds is skipped. Gates are re-read before every action.

Setup gates (all read live, all required):
  nominated  the book is nominated to (or owned by) the vault
  series     the engine's EUR future is the artifact's; the series is listed, unsettled, with over 2 h to last trade
  parity     every setting the deploy made: the book's SubAccounts, cash, fee account (and that it is the
             TradeModule's), gas floor, tax 0, one market on the artifact's series, adapter, tick, lot, fee, ages and
             cap, disabled; the engine neither trusts nor fee-bypasses the book (B4); the deployer has sent nothing
             unaudited since

Add-market gates (all read live, all required):
  custody    the vault owns the book
  next       createMarket will number the market N: nextMarketId is N (or market N is already on E: resuming)
  series     E is listed on the artifact's future, unsettled, over 2 h to last trade, the engine's cap above 0
  unique     no other market on the book trades E
  index      as at enable
  fee        the instruments registry lists E with the artifact's taker fee
  parity     the book-wide settings as deployed (no market's): SubAccounts, cash, fee account, gas floor, tax 0, the
             router, B4, the deployer silent

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
  python3 scripts/ops/propose_onchain_book_batch.py book-add-market --market 2 --expiry 1798729200
  python3 scripts/ops/propose_onchain_book_batch.py book-enable --market 2 --expiry 1798729200
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
NAMES = {1: "ONCHAIN_BOOK", 2: "ONCHAIN_BOOK_V2"}
NAME = NAMES[1]
SETUP, ENABLE, ADD_MARKET = "book-setup", "book-enable", "book-add-market"
BATCHES = (SETUP, ENABLE, ADD_MARKET)
MAX_SELF_PRICED_TTL_CAP = 60  # C6


def files(name: str) -> dict[str, str]:
  return {SETUP: f"{name}_VAULT_ACTIONS.json", ENABLE: f"{name}_ENABLE_VAULT_ACTIONS.json"}


FILES = files(NAME)
EUR_MARKET = 2
# --book: which book's artifacts. eurc: the EURC books (--version picks v1 or v2). cngn: the adapter-less cNGN book
# (deploy-onchain-book-cngn.s.sol, 2026-11-18), on the cNGN future, which is the engine's market 1.
BOOKS = {
  "eurc": {"series": "EURC_FUTURE_V3.json", "engine_market": EUR_MARKET, "label": "EUR", "index": "EURC/USDC"},
  "cngn": {"series": "MARGIN_ENGINE_V2.json", "engine_market": 1, "label": "cNGN", "index": "cNGN spot"},
}
CNGN_NAME = "ONCHAIN_BOOK_CNGN"
BOOK = BOOKS["eurc"]
FUTURE = 4  # IMarginEngine.AssetType.Future
DEPLOYED_MARKET = 1  # the market deploy-onchain-book.s.sol creates, and the artifact records
BOOK_MARKET = DEPLOYED_MARKET  # the market these batches act on: the deployed one, unless --market says otherwise
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
  "maxSelfPricedTtl": "maxSelfPricedTtl(uint256)",
  "book": "book()",
  "createMarket": "createMarket(address,uint96,address,address,uint256,uint256)",
  "setSelfPricedTtlCap": "setSelfPricedTtlCap(uint256,uint32)",
  "indexFeedOf": "indexFeedOf(uint256)",
  "indexFeed": "indexFeed()",
}
PINNED = {
  "acceptOwnership": "0x79ba5097", "setMakerAllowed": "0x4db8b77b", "setMarketParams": "0x9910da7d",
  "owner": "0x8da5cb5b", "pendingOwner": "0xe30c3978", "makerAllowed": "0x4b3df9c5", "markets": "0xb1283e77",
  "feeRecipient": "0x46904840", "gasFloor": "0xfed976f7", "priorityTaxRate": "0x04ca4326",
  "nextMarketId": "0x406ef2ef", "subAccounts": "0x779e5012", "cash": "0x961be391",
  "trustedRiskAssessor": "0x5b75ad78", "feeBypassedCaller": "0x3f210eea", "getSpot": "0x2b37269c",
  "totalPositionCap": "0x745ab570", "assetMap": "0xed75d3f3", "futureContracts": "0xc3c74b34",
  "makers": "0x33f02fa2", "splines": "0xe5dd8989", "maxSelfPricedTtl": "0x3a1359b6", "book": "0x05a8da72",
  "createMarket": "0x021d75bd", "setSelfPricedTtlCap": "0xd4449950", "indexFeedOf": "0x4572d043",
  "indexFeed": "0x198cae76",
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


def add_market_actions(d: dict) -> list[tuple[str, str]]:
  """Market BOOK_MARKET on the series d["subId"], with the deployed market's parameters, disabled, and its cap."""
  book = d["book"]
  return [(book, selector("createMarket") + word_address(d["future"]) + word_uint(int(d["subId"]))
           + word_address(d["manager"]) + word_address(d["adapter"]) + word_uint(int(d["tickSize"]))
           + word_uint(int(d["lotSize"]))),
          (book, enable_calldata(d)[:-64] + word_uint(0)),
          (book, selector("setSelfPricedTtlCap") + word_uint(BOOK_MARKET) + word_uint(int(d["selfPricedTtlCap"])))]


def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as deploy-onchain-book.s.sol writes them (book-add-market: as built
  here, with no file)."""
  book = d["book"]
  if batch == ADD_MARKET:
    return add_market_actions(d)
  if batch == SETUP:
    return [(book, selector("acceptOwnership")),
            (book, selector("setMakerAllowed") + word_address(d["makerOwner"]) + word_uint(1))]
  return [(book, enable_calldata(d))]


def market_word(chain: Chain, d: dict, field: str) -> int:
  return chain.word(d["book"], selector("markets") + word_uint(BOOK_MARKET), MARKET_WORDS[field])


def postconditions(chain: Chain, batch: str, d: dict, vault: str) -> list:
  book = d["book"]
  if batch == ADD_MARKET:
    return [lambda: chain.word(book, selector("nextMarketId")) > BOOK_MARKET and market_word(chain, d, "subId") == int(d["subId"]),
            lambda: market_word(chain, d, "takeMaxAge") == int(d["takeMaxAge"]) and market_word(chain, d, "maxTtl") == int(d["maxTtl"]),
            lambda: chain.word(book, selector("maxSelfPricedTtl") + word_uint(BOOK_MARKET)) == int(d["selfPricedTtlCap"])]
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


def version_of(d: dict) -> int:
  return int(d.get("version", 1))


def check_artifact(d: dict, series: dict) -> None:
  """The book's market is on the recorded EURC v3 future, engine and adapter. v1: the recorded series itself. v2: the
  series EXPIRY chose (the series gate reads it on the future); the self-priced cap within C6's 60 s, and a router."""
  keys = (("future", "future"), ("manager", "manager"), ("indexFeed", "indexFeed"), ("cash", "cash"),
          ("tradeModule", "tradeModule")) + ((("adapter", "adapter"),) if BOOK is BOOKS["eurc"] else ())
  if BOOK is BOOKS["cngn"] and int(d["adapter"], 16) != 0:
    raise SystemExit(f"{NAME}.json records adapter {d['adapter']}: the cNGN book's market has none")
  for key, other in keys:
    if d[key].lower() != series[other].lower():
      raise SystemExit(f"{NAME}.json {key} {d[key]} is not {BOOK['series']}'s {series[other]}")
  version = version_of(d)
  if version not in NAMES:
    raise SystemExit(f"{NAME}.json: version {version} is unknown")
  if version == 1:
    if int(d["subId"]) != int(series["subId"]) or int(d["lastTradeTime"]) != int(series["lastTradeTime"]):
      raise SystemExit(f"{NAME}.json is not on the series {series['subId']}")
  else:
    if int(d["subId"]) != int(d["expiry"]):
      raise SystemExit(f"{NAMES[2]}.json: subId {d['subId']} is not its expiry {d['expiry']}")
    if not 0 < int(d["selfPricedTtlCap"]) <= min(MAX_SELF_PRICED_TTL_CAP, int(d["maxTtl"])):
      raise SystemExit(f"{NAMES[2]}.json: self-priced ttl cap {d['selfPricedTtlCap']} outside 1..60 s (C6)")
    if int(d["router"], 16) == 0:
      raise SystemExit(f"{NAMES[2]}.json records no router")
  if int(d["bookMarketId"]) != DEPLOYED_MARKET:
    raise SystemExit(f"{NAME}.json: the book's market is {d['bookMarketId']}, not {DEPLOYED_MARKET}")
  if int(d["priorityTaxRate"]) != 0:
    raise SystemExit(f"{NAME}.json: the priority tax is on (B12: off at rollout)")
  if int(d["takerFeeRate"]) > 10**16:
    raise SystemExit(f"{NAME}.json: taker fee {d['takerFeeRate']} over 1%")


# ---------------------------------------------------------------------------------------------
# gates
# ---------------------------------------------------------------------------------------------

def series_verdict(listed_future: str, future: str, listed: int, settled: int, last_trade: int, now: int,
                   cap: int | None) -> Gate:
  problems = ([f"{BOOK['label']}'s future is {listed_future}, not {future}"] if listed_future.lower() != future.lower() else []) + \
             (["the series is not listed"] if not listed else []) + (["the series has settled"] if settled else []) + \
             ([f"{(last_trade - now) / 3600:.1f} h to last trade (under 2 h)"]
              if listed and last_trade - now < MIN_LEAD_SEC else []) + \
             (["the series is closed on the engine (cap 0)"] if cap == 0 else [])
  return Gate("series", not problems, "; ".join(problems) or
              f"{BOOK['label']}'s future, listed, {(last_trade - now) / 3600:.1f} h to last trade" + ("" if cap is None else ", open"))


def gate_series(chain: Chain, d: dict, need_open: bool) -> Gate:
  try:
    s = word_uint(int(d["subId"]))
    listed_future = "0x" + chain.call(d["manager"], selector("assetMap") + word_uint(BOOK["engine_market"]) + word_uint(FUTURE))[24:64]
    cap = chain.word(d["future"], selector("totalPositionCap") + word_address(d["manager"])) if need_open else None
    return series_verdict(listed_future, d["future"], chain.word(d["future"], selector("futureContracts") + s, 0),
                          chain.word(d["future"], selector("futureContracts") + s, 1),
                          chain.word(d["future"], selector("futureContracts") + s, 3), chain.head(), cap)
  except Exception as exc:  # noqa: BLE001 -- unreadable holds
    return Gate("series", False, f"the series unreadable: {str(exc)[:120]}")


def gate_parity(chain: Chain, d: dict, vault: str, attached: bool, market: bool = True) -> Gate:
  """Every setting the deploy made. market=False (book-add-market, before market N exists): the book-wide ones only."""
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
    # B4: the engine grants the book nothing
    ("engine trusts the book", w(d["manager"], "trustedRiskAssessor", word_address(book)), 0),
    ("engine fee-bypasses the book", w(d["manager"], "feeBypassedCaller", word_address(book)), 0),
    *([("router's book", a(d["router"], "book"), book),
       ("router's cash", a(d["router"], "cash"), d["cash"]),
       ("router's SubAccounts", a(d["router"], "subAccounts"), d["subAccounts"])] if version_of(d) == 2 else []),
    ("deployer transactions since the deploy, unaudited",
     v2p.unaudited_deployer_txs(chain.url, d["deployer"], int(d["deployerNonce"])), 0),
  ]
  if market:
    pairs += market_pairs(chain, d, w, mk, addr)
  holder = a(book, "owner").lower() if attached else (a(book, "owner").lower(), a(book, "pendingOwner").lower())
  pairs.append(("the book is the vault's" if attached else "the book is nominated to the vault",
                holder == vault.lower() if attached else vault.lower() in holder, True))
  bad = v1p.parity_mismatches(pairs)
  if bad:
    return Gate("parity", False, f"{len(bad)} setting(s) differ from the deploy: " + "; ".join(bad[:4]))
  return Gate("parity", True, f"all {len(pairs)} settings as deployed; deployer {d['deployer']} has sent nothing unaudited since")


def market_pairs(chain: Chain, d: dict, w, mk, addr) -> list[tuple[str, object, object]]:
  """Market BOOK_MARKET's settings. The book has exactly the markets up to it: one after the deploy, N after
  book-add-market N."""
  book = d["book"]
  a = lambda to, name, *args: "0x" + chain.call(to, selector(name) + "".join(args))[24:64]  # noqa: E731
  return [
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
    *([("book self-priced ttl cap", w(book, "maxSelfPricedTtl", word_uint(BOOK_MARKET)), int(d["selfPricedTtlCap"]))]
      if version_of(d) == 2 else []),
    # adapter-less: the index the market is tied to (OnchainBook.indexFeedOf), the future's
    *([("market index feed", a(book, "indexFeedOf", word_uint(BOOK_MARKET)), d["indexFeed"]),
       ("the future's index", a(d["future"], "indexFeed"), d["indexFeed"])] if BOOK is BOOKS["cngn"] else []),
  ]


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


def gate_fee(chain: Chain, d: dict, markets_url: str, book_rate: int | None = None) -> Gate:
  """The registry's fee for the series against the book's: the market's own, or (book-add-market, before the market
  exists) the rate the market will be given."""
  try:
    listing = v2p.find_listing(v2p.markets(markets_url), d["future"], d["subId"])
  except Exception as exc:  # noqa: BLE001
    return Gate("fee", False, f"markets-service /markets unreadable: {str(exc)[:80]}")
  try:
    return fee_verdict(listing, market_word(chain, d, "takerFeeRate") if book_rate is None else book_rate)
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
    return Gate("index", True, f"{BOOK['index']} index {chain.word(d['indexFeed'], selector('getSpot')) / 1e18:.6f}")
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


def next_verdict(next_id: int, market: int, market_sub_id: int, sub_id: int) -> Gate:
  """createMarket numbers markets from nextMarketId: the batch's market N must be the next one, or already on the series
  (a resumed batch). Anything else would open a market under another number than the one every later action names."""
  if next_id == market:
    return Gate("next", True, f"createMarket will number it {market}")
  if next_id > market and market_sub_id == sub_id:
    return Gate("next", True, f"market {market} is already on {sub_id}: resuming")
  return Gate("next", False, f"nextMarketId is {next_id}: createMarket would not number it {market}"
                             + (f" (market {market} trades {market_sub_id})" if next_id > market else ""))


def unique_verdict(sub_ids: dict[int, int], market: int, sub_id: int) -> Gate:
  """No other market on the book trades the series: two would split its makers and its tape."""
  others = [m for m, s in sub_ids.items() if s == sub_id and m != market]
  return Gate("unique", not others, f"market(s) {others} already trade {sub_id}" if others
              else f"no other market on the book trades {sub_id}")


def gate_add_market(chain: Chain, d: dict, vault: str, markets_url: str) -> list[Gate]:
  book = d["book"]
  owned = chain.address(book, "owner").lower() == vault.lower()
  gates = [Gate("custody", owned, "the vault owns the book" if owned else "the vault does not own the book")]
  try:
    next_id = chain.word(book, selector("nextMarketId"))
    sub_ids = {m: chain.word(book, selector("markets") + word_uint(m), MARKET_WORDS["subId"]) for m in range(1, next_id)}
    gates += [next_verdict(next_id, BOOK_MARKET, sub_ids.get(BOOK_MARKET, 0), int(d["subId"])),
              unique_verdict(sub_ids, BOOK_MARKET, int(d["subId"]))]
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("next", False, f"the book's markets unreadable: {str(exc)[:80]}"))
  return gates + [gate_series(chain, d, need_open=True), gate_index(chain, d),
                  gate_fee(chain, d, markets_url, book_rate=int(d["takerFeeRate"])),
                  gate_parity(chain, d, vault, attached=True, market=False)]


def series_symbol(base: str, expiry: int) -> str:
  import time
  return f"{base}-" + time.strftime("%d%b%y", time.gmtime(expiry)).upper()


def market_view(d: dict, market: int, expiry: int, last_trade: int) -> dict:
  """The artifact as market N on the series `expiry` would record it: the deployed market's parameters, its own series.
  The last trade is the future's, read live."""
  return {**d, "bookMarketId": market, "subId": expiry, "expiry": expiry, "lastTradeTime": last_trade,
          "symbol": series_symbol("EURC", expiry)}


def from_file(batch: str) -> bool:
  """Market 1's batches are the deploy's files; book-add-market and any batch on a further market are built here."""
  return BOOK_MARKET == 1 and batch != ADD_MARKET


def built_actions(batch: str, d: dict) -> list[dict]:
  """A batch on market N > 1 has no deploy file: its actions, built here, in the files' shape."""
  names = {ADD_MARKET: [f"book.createMarket(future, {d['subId']}, engine, adapter, tick, lot) [market {BOOK_MARKET}]",
                        f"book.setMarketParams({BOOK_MARKET}, ..., enabled = false)",
                        f"book.setSelfPricedTtlCap({BOOK_MARKET}, {d['selfPricedTtlCap']})"],
           ENABLE: [f"book.setMarketParams({BOOK_MARKET}, ..., enabled = true) [opens {d['symbol']}]"]}[batch]
  return [{"description": n, "to": to, "value": "0", "data": data, "digest": digest(to, data)}
          for n, (to, data) in zip(names, expected_actions(batch, d))]


# ---------------------------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------------------------

def self_test() -> int:
  # --book cngn: the artifact is checked against MARGIN_ENGINE_V2.json and must record no adapter
  global BOOK, NAME
  saved_book, saved_name = BOOK, NAME
  try:
    BOOK, NAME = BOOKS["cngn"], CNGN_NAME
    eng = {"future": "0x" + "c1" * 20, "manager": "0x" + "e1" * 20, "indexFeed": "0x" + "f1" * 20,
           "cash": "0x" + "ca" * 20, "tradeModule": "0x" + "7d" * 20}
    art = {**eng, "adapter": "0x" + "00" * 20, "version": 2, "subId": 1796047200, "expiry": 1796047200,
           "selfPricedTtlCap": 60, "maxTtl": 3600, "router": "0x" + "40" * 20, "bookMarketId": 1,
           "priorityTaxRate": 0, "takerFeeRate": 15 * 10**14}
    check_artifact(art, eng)
    for bad, why in (({"adapter": "0x" + "9e" * 20}, "records adapter"), ({"future": "0x" + "c2" * 20}, "MARGIN_ENGINE_V2")):
      try:
        check_artifact({**art, **bad}, eng)
        raise AssertionError(f"cngn artifact {bad} accepted")
      except SystemExit as exc:
        assert why in str(exc), exc
  finally:
    BOOK, NAME = saved_book, saved_name
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
  # v2: on any series of the future (the series gate reads it live), with the cap and a router recorded
  v2 = {**full, "version": 2, "subId": 1798729200, "expiry": 1798729200, "lastTradeTime": 1798727400,
        "selfPricedTtlCap": 60, "router": a(10)}
  check_artifact(v2, series)
  for bad in ({"subId": 1}, {"selfPricedTtlCap": 0}, {"selfPricedTtlCap": 61}, {"maxTtl": 30}, {"router": a(0)},
              {"version": 3}, {"future": a(9)}):
    try:
      check_artifact({**v2, **bad}, series)
    except SystemExit:
      continue
    raise AssertionError(f"v2 artifact {bad} accepted")
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

  # a further market (book-add-market, book-enable --market N): the calldata as `cast calldata` encodes it (2026-11-17)
  global BOOK_MARKET
  BOOK_MARKET = 2
  try:
    m2 = {**d, "future": a(1), "manager": a(2), "adapter": a(3), "subId": 1798729200, "tickSize": 10**12,
          "lotSize": 10**15, "selfPricedTtlCap": 60, "symbol": "EURC-31DEC26"}
    assert expected_actions(ADD_MARKET, m2) == [
      (a(5), "0x021d75bd" + word_address(a(1)) + word_uint(1798729200)
       + word_address(a(2)) + word_address(a(3)) + "000000000000000000000000000000000000000000000000000000e8d4a51000"
       + "00000000000000000000000000000000000000000000000000038d7ea4c68000"),
      (a(5), "0x9910da7d" + word_uint(2) + "0000000000000000000000000000000000000000000000000001c6bf52634000"
       + word_uint(1) + word_uint(3600) + word_uint(10) + word_uint(0)),
      (a(5), "0xd4449950" + word_uint(2) + word_uint(60))]
    assert expected_actions(ENABLE, m2)[0][1].endswith(word_uint(10) + word_uint(1))
    assert expected_actions(ENABLE, m2)[0][1][10:74] == word_uint(2), "enable names market 2"
    built = built_actions(ADD_MARKET, m2)
    verify_actions(ADD_MARKET, m2, built)
    for what, mutate in {"target": lambda acts: acts[0].update(to=a(99)),
                         "calldata": lambda acts: acts[1].update(data=acts[1]["data"][:-1] + "1"),
                         "dropped": lambda acts: acts.pop(), "reordered": lambda acts: acts.reverse()}.items():
      acts = json.loads(json.dumps(built))
      mutate(acts)
      try:
        verify_actions(ADD_MARKET, m2, acts)
      except SystemExit:
        continue
      raise AssertionError(f"add-market: a wrong {what} was accepted")
    assert "opens EURC-31DEC26" in built_actions(ENABLE, m2)[0]["description"]
    assert not from_file(ENABLE) and not from_file(ADD_MARKET), "market 2 has no deploy file"
    check_artifact(v2, series)  # the artifact still records the deployed market while a batch acts on market 2

    # each add-market postcondition reads what its own action writes
    mk2 = selector("markets")
    steps = [{(a(5), selector("nextMarketId")): 3, (a(5), mk2, MARKET_WORDS["subId"]): 1798729200},
             {(a(5), mk2, MARKET_WORDS["takeMaxAge"]): 1, (a(5), mk2, MARKET_WORDS["maxTtl"]): 3600},
             {(a(5), selector("maxSelfPricedTtl")): 60}]
    for landed in range(4):
      state = {k: v for st in steps[:landed] for k, v in st.items()}
      if landed == 0:
        state[(a(5), selector("nextMarketId"))] = 2
      got = [h() for h in postconditions(Reads(state), ADD_MARKET, m2, vault)]
      assert got == [i < landed for i in range(3)], (landed, got)
    # another series already on market 2 is not "created"
    assert not postconditions(Reads({(a(5), selector("nextMarketId")): 3, (a(5), mk2, MARKET_WORDS["subId"]): 1}),
                              ADD_MARKET, m2, vault)[0]()
  finally:
    BOOK_MARKET = 1
  assert from_file(SETUP) and from_file(ENABLE) and not from_file(ADD_MARKET)

  # next: market N must be the next number, or already on the series (resuming)
  assert next_verdict(2, 2, 0, 1798729200).ok
  assert next_verdict(3, 2, 1798729200, 1798729200).ok and "resuming" in next_verdict(3, 2, 1798729200, 1798729200).detail
  assert not next_verdict(3, 2, 1796050800, 1798729200).ok, "market 2 is another series"
  assert not next_verdict(4, 3, 1, 1798729200).ok and not next_verdict(2, 3, 0, 1798729200).ok
  # unique: no other market on the series; the batch's own (resumed) market is not another
  assert unique_verdict({1: 1796050800}, 2, 1798729200).ok
  assert unique_verdict({1: 1796050800, 2: 1798729200}, 2, 1798729200).ok
  assert not unique_verdict({1: 1798729200}, 2, 1798729200).ok
  # the arguments
  for bad in ((ADD_MARKET, 2, 1, None), (ENABLE, 2, 1, 1798729200), (ENABLE, 2, 2, None), (SETUP, 2, 2, 1798729200),
              (ENABLE, 1, 2, 1798729200), (ENABLE, 2, 0, None)):
    try:
      check_market_args(*bad)
    except SystemExit:
      continue
    raise AssertionError(f"arguments {bad} accepted")
  check_market_args(ENABLE, 2, 1, None)
  check_market_args(ADD_MARKET, 2, 2, 1798729200)
  check_market_args(ENABLE, 2, 2, 1798729200)
  v = market_view({**full, "symbol": "EURC-30NOV26"}, 2, 1798729200, 1798727400)
  assert (v["bookMarketId"], v["subId"], v["expiry"], v["lastTradeTime"], v["symbol"]) == \
    (2, 1798729200, 1798729200, 1798727400, "EURC-31DEC26"), v
  assert full["subId"] == 1796050800, "the view leaves the artifact as recorded"

  import inspect
  for fn in (main, run_batch):
    assert "propose(token" not in inspect.getsource(fn), f"{fn.__name__} calls propose() directly"
  print("self-test ok: selectors compiled and pinned; a wrong target, calldata, value, digest, count or order is refused; "
        "the artifact must be on the recorded series with the tax off (v2: any series, cap 1-60 s, a router); the series must be the engine's, listed, open "
        "and over 2 h from last trade; the book's fee must equal the registry's; a further market is created as `cast calldata` encodes it, under its "
        "own number, on a series no other market trades")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def run_batch(args, d: dict, chain: Chain, rpc_url: str, vault: str, markets_url: str) -> int:
  if from_file(args.batch):
    actions = json.loads((args.dir / FILES[args.batch]).read_text())
  else:
    actions = built_actions(args.batch, d)
  verify_actions(args.batch, d, actions)

  def gates() -> list[Gate]:
    if args.batch == SETUP:
      return gate_setup(chain, d, vault)
    if args.batch == ADD_MARKET:
      return gate_add_market(chain, d, vault, markets_url)
    return gate_enable(chain, d, vault, markets_url)

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
  ap.add_argument("batch", nargs="?", choices=BATCHES)
  ap.add_argument("--version", type=int, choices=tuple(NAMES), default=2, help="the book version's artifacts (default 2)")
  ap.add_argument("--book", choices=tuple(BOOKS), default="eurc", help="eurc (default) or cngn, the adapter-less cNGN book")
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--dir", type=Path, default=ROOT / "deployments" / "8453", help="where the deploys wrote their artifacts")
  ap.add_argument("--json", action="store_true", help="print the gates as JSON on the last line")
  ap.add_argument("--market", type=int, default=1, help="the book's market (default 1, the deployed one)")
  ap.add_argument("--expiry", type=int, help="with --market N > 1: the series (unix expiry, its subId)")
  args = ap.parse_args()

  if args.self_test:
    return self_test()
  if not args.batch:
    ap.error("name a batch: " + ", ".join(BATCHES))
  global NAME, FILES, BOOK_MARKET, BOOK
  BOOK = BOOKS[args.book]
  if args.book == "cngn" and args.version != 2:
    raise SystemExit("the cNGN book is v2 code: --version 2")
  NAME = CNGN_NAME if args.book == "cngn" else NAMES[args.version]
  FILES = files(NAME)
  check_market_args(args.batch, args.version, args.market, args.expiry)
  BOOK_MARKET = args.market

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
  if version_of(d) != args.version:
    raise SystemExit(f"{artifact} records version {version_of(d)}, not {args.version}")
  check_artifact(d, json.loads((args.dir / BOOK["series"]).read_text()))
  chain = Chain(rpc_url)
  if BOOK_MARKET > 1:
    last_trade = chain.word(d["future"], selector("futureContracts") + word_uint(args.expiry), 3)
    d = market_view(d, BOOK_MARKET, args.expiry, last_trade)
  return run_batch(args, d, chain, rpc_url, vault, os.environ.get("MARKETS_URL", "https://api.numofx.com"))


def check_market_args(batch: str, version: int, market: int, expiry: int | None) -> None:
  """Market 1 is the deployed one, from the deploy's files; a further market is v2 only, named with its series, and
  has no setup of its own (setup is the book's, once)."""
  if market < 1:
    raise SystemExit("--market starts at 1")
  if market == 1:
    if batch == ADD_MARKET:
      raise SystemExit("market 1 is the deployed one: book-add-market adds market 2 and later")
    if expiry is not None:
      raise SystemExit("--expiry is for --market N > 1: market 1's series is the deploy's")
    return
  if version != 2:
    raise SystemExit("a further market is for the v2 book (--version 2)")
  if batch == SETUP:
    raise SystemExit("book-setup is the book's, once: a further market starts with book-add-market")
  if expiry is None:
    raise SystemExit(f"--market {market} needs --expiry: the series it trades")


if __name__ == "__main__":
  raise SystemExit(main())
