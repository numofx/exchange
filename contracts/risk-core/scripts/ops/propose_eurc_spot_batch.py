#!/usr/bin/env python3
"""Proposes the EURC-USDC listing on the MarginEngine to MPCVault, one action at a time.

Configure (deployments/8453/EURC_SPOT_VAULT_ACTIONS.json, written by scripts/deploy-eurc-spot.s.sol):
  0 eurcEscrow.acceptOwnership()                          custody of the escrow
  1 eurcSpotFeed.acceptOwnership()                        custody of the feed's staleness limit
  2 engine.createMarket("EUR")                            market 2
  3 engine.setOraclesForMarket(2, eurcSpotFeed, 0, 0)     Chainlink EURC/USD
  4 engine.setBaseAssetMarginFactor(2, 0.9, 0.8)          the haircut: 90% at maintenance, 72% at initial
  5 engine.whitelistAsset(eurcEscrow, 2, Base)            the engine side of the gate
  6 eurcEscrow.setTotalPositionCap(engine, 50k EURC)      the deposit cap
None of these lets EURC in.

Enable (EURC_SPOT_ENABLE_VAULT_ACTIONS.json, `--batch enable`):
  0 eurcEscrow.setWhitelistManager(engine, true)          EURC deposits, and the market, open
Gated on the services that handle EURC being live: markets-service listing EURC-USDC on this escrow, the engine
keeper reporting it, and an operator flag that the fork suite (test/fork/EurcSpotFork.t.sol) has run against it.

The market id is the hazard. whitelistAsset into an occupied slot de-whitelists what was there, and market 1's Base
slot is the cNGN escrow every live market margins through. So every engine action re-reads lastMarketId first: 1
before createMarket, exactly 2 after it, and the batch stops if anything else created a market in between.

Every action is checked against the artifact (selector allowlist, arguments re-read from calldata, digest recomputed)
and against the chain before it is proposed, and after it lands. It NEVER signs, executes or broadcasts: each request
goes to the MPCVault app for a human. Without --propose it prints the gate report and the sheet.

Env (via run-with-ssm-mark.sh): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.

  scripts/ops/run-with-ssm-mark.sh python3 scripts/ops/propose_eurc_spot_batch.py            # gates + sheet
  scripts/ops/run-with-ssm-mark.sh python3 scripts/ops/propose_eurc_spot_batch.py --propose  # configure
  ... --batch enable --rehearsed --propose                                                    # enable, later
  python3 scripts/ops/propose_eurc_spot_batch.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from propose_cngn_spot_batch import (  # noqa: E402  single implementation of the MPCVault transport
  CONFIRM_POLL_SEC,
  CONFIRM_TIMEOUT_SEC,
  EXPECTED_VAULT,
  await_postcondition,
  confirm_on_chain,
  gates_after_mining,
  load_env_file,
  propose,
  request_tx_hash,
  rpc,
)
from resolve_cngn_action6 import keccak  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
DEPLOYMENTS = ROOT / "deployments" / "8453"
ARTIFACT = DEPLOYMENTS / "EURC_SPOT.json"
CONFIGURE_ACTIONS = DEPLOYMENTS / "EURC_SPOT_VAULT_ACTIONS.json"
ENABLE_ACTIONS = DEPLOYMENTS / "EURC_SPOT_ENABLE_VAULT_ACTIONS.json"
CHAIN_ID = 8453
EURC = "0x60a3e35cc302bfa44cb288bc5a4f316fdb1adb42"
EURC_USD_AGGREGATOR = "0xdae398520e2b67cd3f27aef9cf14d93d927f8250"
MARKET_ID = 2
MARKET_NAME = "EUR"
BASE = 3  # IMarginEngine.AssetType.Base
SYMBOL = "EURC-USDC"

# The only functions these batches may call. Pinned by --self-test against the compiled ABIs.
SELECTORS = {
  "acceptOwnership()": "0x79ba5097",
  "createMarket(string)": "0x54888f55",
  "setOraclesForMarket(uint256,address,address,address)": "0x675b0ebb",
  "setBaseAssetMarginFactor(uint256,uint256,uint256)": "0xc27009e2",
  "whitelistAsset(address,uint256,uint8)": "0xbd798569",
  "setTotalPositionCap(address,uint256)": "0x40a557bd",
  "setWhitelistManager(address,bool)": "0xe64cc9da",
}
CONFIGURE_ORDER = [
  "acceptOwnership()", "acceptOwnership()", "createMarket(string)",
  "setOraclesForMarket(uint256,address,address,address)", "setBaseAssetMarginFactor(uint256,uint256,uint256)",
  "whitelistAsset(address,uint256,uint8)", "setTotalPositionCap(address,uint256)",
]
ENABLE_ORDER = ["setWhitelistManager(address,bool)"]
# The deploy script's sized constants; anything more generous is refused here too.
SIZED_MARGIN_FACTOR = 9 * 10**17
SIZED_IM_SCALE = 8 * 10**17
MAX_CAP = 50_000 * 10**18  # 50% of the 2% sell depth at the 2026-10-24 12:00 UTC reading


def sel(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def word_uint(value: int) -> str:
  return f"{value:064x}"


def encode_string(value: str) -> str:
  raw = value.encode()
  return word_uint(32) + word_uint(len(raw)) + raw.hex().ljust(64 * ((len(raw) + 31) // 32), "0")


def call(rpc_url: str, to: str, data: str) -> str:
  return rpc(rpc_url, "eth_call", [{"to": to, "data": data}, "latest"])


def uint_at(raw: str, index: int = 0) -> int:
  return int(raw[2 + 64 * index: 2 + 64 * (index + 1)], 16)


def address_at(raw: str, index: int = 0) -> str:
  return "0x" + raw[2 + 64 * index + 24: 2 + 64 * (index + 1)].lower()


def read_fn(rpc_url: str, to: str, sig: str, *args: str) -> str:
  return call(rpc_url, to, sel(sig) + "".join(args))


def digest(to: str, data: str) -> str:
  """keccak(to || keccak(data)), as EURCSpotBatch.actionHash."""
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


class Gate:
  def __init__(self, name: str, ok: bool, detail: str):
    self.name, self.ok, self.detail = name, ok, detail


def report(gates: list[Gate]) -> bool:
  for g in gates:
    print(f"  [{'PASS' if g.ok else 'FAIL'}] {g.name}: {g.detail}")
  return all(g.ok for g in gates)


# --- the artifact ------------------------------------------------------------------------------

def check_artifact(art: dict) -> None:
  if art["eurcToken"].lower() != EURC or art["aggregator"].lower() != EURC_USD_AGGREGATOR:
    raise SystemExit("REFUSED: the artifact is not EURC over Chainlink EURC/USD")
  if int(art["marketId"]) != MARKET_ID:
    raise SystemExit(f"REFUSED: the artifact's market is {art['marketId']}, not {MARKET_ID}")
  if not 0 < int(art["marginFactor"]) <= SIZED_MARGIN_FACTOR or not 0 < int(art["imScale"]) <= SIZED_IM_SCALE:
    raise SystemExit("REFUSED: the artifact's haircut is more generous than the sized 0.9 / 0.8")
  if not 0 < int(art["cap"]) <= MAX_CAP:
    raise SystemExit("REFUSED: the artifact's cap is outside (0, 50,000 EURC]")


def load_actions(path: Path, art: dict, order: list[str]) -> list[dict]:
  check_artifact(art)
  actions = json.loads(path.read_text()) if isinstance(path, Path) else path
  escrow, feed, engine = art["escrow"].lower(), art["spotFeed"].lower(), art["engine"].lower()
  if len(actions) != len(order):
    raise SystemExit(f"REFUSED: {len(actions)} actions, expected {len(order)}")
  for i, a in enumerate(actions):
    data, to = a["data"].lower(), a["to"].lower()
    sig = next((s for s, x in SELECTORS.items() if data.startswith(x)), None)
    if sig is None:
      raise SystemExit(f"REFUSED: action {i} selector {data[:10]} is not one these batches may contain")
    if sig != order[i]:
      raise SystemExit(f"REFUSED: action {i} is {sig}, expected {order[i]} at that position")
    if digest(a["to"], a["data"]) != a["digest"].lower():
      raise SystemExit(f"REFUSED: action {i} digest {a['digest']} is not keccak(to, keccak(data))")
    if str(a.get("value", "0")) != "0":
      raise SystemExit(f"REFUSED: action {i} sends value")
    args = data[10:]
    word = lambda k: args[64 * k: 64 * (k + 1)]  # noqa: E731
    # The arguments the batch must carry, re-read from the calldata rather than trusted.
    if sig == "acceptOwnership()":
      want = escrow if i == 0 else feed
      if to != want or args:
        raise SystemExit(f"REFUSED: action {i} must accept ownership of {want}")
    elif sig == "createMarket(string)":
      if to != engine or args != encode_string(MARKET_NAME):
        raise SystemExit(f"REFUSED: action {i} must be engine.createMarket({MARKET_NAME!r})")
    elif sig == "setOraclesForMarket(uint256,address,address,address)":
      if to != engine or word(0) != word_uint(MARKET_ID) or word(1) != word_address(feed) or word(2) != word_uint(0) \
          or word(3) != word_uint(0) or len(args) != 4 * 64:
        raise SystemExit(f"REFUSED: action {i} must set market {MARKET_ID}'s spot feed to the artifact's, and nothing else")
    elif sig == "setBaseAssetMarginFactor(uint256,uint256,uint256)":
      if to != engine or word(0) != word_uint(MARKET_ID) or int(word(1), 16) != int(art["marginFactor"]) \
          or int(word(2), 16) != int(art["imScale"]) or len(args) != 3 * 64:
        raise SystemExit(f"REFUSED: action {i} haircut does not match the artifact's on market {MARKET_ID}")
    elif sig == "whitelistAsset(address,uint256,uint8)":
      if to != engine or word(0) != word_address(escrow) or word(1) != word_uint(MARKET_ID) or word(2) != word_uint(BASE) \
          or len(args) != 3 * 64:
        raise SystemExit(f"REFUSED: action {i} must whitelist the escrow as Base ({BASE}) on market {MARKET_ID}")
    elif sig == "setTotalPositionCap(address,uint256)":
      if to != escrow or word(0) != word_address(engine) or int(word(1), 16) != int(art["cap"]) or len(args) != 2 * 64:
        raise SystemExit(f"REFUSED: action {i} cap/manager do not match the artifact")
    elif sig == "setWhitelistManager(address,bool)":
      if to != escrow or word(0) != word_address(engine) or word(1) != word_uint(1) or len(args) != 2 * 64:
        raise SystemExit(f"REFUSED: action {i} must open the escrow to the engine")
    a["sig"] = sig
  return actions


# --- gates, read live ---------------------------------------------------------------------------

def last_market_id(rpc_url: str, art: dict) -> int:
  return uint_at(read_fn(rpc_url, art["engine"], "lastMarketId()"))


def gate_chain(rpc_url: str) -> Gate:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  return Gate("chain", chain == CHAIN_ID, f"chain id {chain} (want {CHAIN_ID})")


def gate_custody(rpc_url: str, art: dict, vault: str) -> Gate:
  owner = address_at(read_fn(rpc_url, art["engine"], "owner()"))
  return Gate("custody", owner == vault.lower(), f"engine owner {owner} (vault {vault.lower()})")


def gate_market(rpc_url: str, art: dict, created: bool) -> Gate:
  """Before createMarket the engine has one market; after it, exactly two. Anything else and market 2 is not ours."""
  last = last_market_id(rpc_url, art)
  slot = address_at(read_fn(rpc_url, art["engine"], "assetMap(uint256,uint8)", word_uint(MARKET_ID), word_uint(BASE)))
  want = MARKET_ID if created else MARKET_ID - 1
  ok = last == want and slot in ("0x" + "0" * 40, art["escrow"].lower())
  return Gate("market id", ok, f"lastMarketId {last} (want {want}), market {MARKET_ID} Base slot {slot}")


def gate_escrow(rpc_url: str, art: dict, vault: str) -> Gate:
  escrow = art["escrow"]
  token = address_at(read_fn(rpc_url, escrow, "wrappedAsset()"))
  owner = address_at(read_fn(rpc_url, escrow, "owner()"))
  pending = address_at(read_fn(rpc_url, escrow, "pendingOwner()"))
  ok = token == EURC and vault.lower() in (owner, pending)
  return Gate("escrow", ok, f"wraps {token}, owner {owner}, pending {pending}")


def gate_feed(rpc_url: str, art: dict, vault: str) -> Gate:
  feed = art["spotFeed"]
  aggregator = address_at(read_fn(rpc_url, feed, "aggregator()"))
  owner = address_at(read_fn(rpc_url, feed, "owner()"))
  pending = address_at(read_fn(rpc_url, feed, "pendingOwner()"))
  try:
    raw = read_fn(rpc_url, feed, "getSpot()")
    spot, confidence = uint_at(raw, 0), uint_at(raw, 1)
  except RuntimeError as error:  # CLF_DataTooOld or CLF_InvalidPrice
    return Gate("feed", False, f"getSpot reverts: {error}")
  ok = aggregator == EURC_USD_AGGREGATOR and vault.lower() in (owner, pending) and 0.8e18 <= spot <= 1.6e18 \
    and confidence == 10**18
  return Gate("feed", ok, f"Chainlink {aggregator}, {spot / 1e18:.5f} USD per EURC, owner {owner}, pending {pending}")


def http_json(url: str) -> dict | list:
  req = urllib.request.Request(url, headers={"accept": "application/json", "User-Agent": "numo-ops/1.0"})
  with urllib.request.urlopen(req, timeout=15) as resp:
    return json.loads(resp.read())


def keeper_gate(art: dict, health: dict, cap18: int) -> Gate:
  """The ENGINE keeper (services/perp-keeper/src/main.ts /health), live, not dry, bidding for this escrow. The perp
  SRM's keeper serves the same shape on another port, so the manager is checked, not assumed from the URL.

  Its MAX_EURC_INVENTORY (served as maxEurcInventory, 18dp) must be set and at most the escrow's on-chain deposit cap
  (18dp): the most EURC the keeper will take from liquidations may not exceed the most the venue can hold, and the cap
  is sized to on-chain sell depth (eurc_depth/depth.py). Unset means no limit, which is refused for the same reason."""
  escrow = str(health.get("eurcEscrow") or "").lower()
  manager = str(health.get("manager") or "").lower()
  raw = health.get("maxEurcInventory")
  inventory = int(raw) if raw not in (None, "") else None
  within_cap = inventory is not None and 0 < inventory <= cap18
  ok = bool(health.get("lastPassOk")) and health.get("dryRun") is False and escrow == art["escrow"].lower() \
    and manager == art["engine"].lower() and within_cap
  limit = "unset (no limit)" if inventory is None else f"{inventory / 1e18:,.0f} EURC"
  return Gate("engine keeper", ok, f"manager {manager or '(unset)'}, lastPassOk {health.get('lastPassOk')}, "
                                   f"dryRun {health.get('dryRun')}, EURC escrow {escrow or '(unset)'}, "
                                   f"MAX_EURC_INVENTORY {limit} vs on-chain cap {cap18 / 1e18:,.0f} EURC")


def gate_services(rpc_url: str, art: dict, markets_url: str, keeper_health_url: str) -> list[Gate]:
  """Enable only: the services that handle EURC must be live with this escrow."""
  gates = []
  try:
    markets = http_json(markets_url.rstrip("/") + "/v1/markets")
    listing = next((m for m in markets if m.get("market") == SYMBOL), {})
    ok = str(listing.get("asset_address", "")).lower() == art["escrow"].lower() \
      and str(listing.get("margin_manager_address", "")).lower() == art["engine"].lower()
    gates.append(Gate("markets-service", ok,
                      f"{SYMBOL} asset {listing.get('asset_address') or '(not listed)'}, manager {listing.get('margin_manager_address')}"))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("markets-service", False, f"unreadable: {exc}"))
  try:
    health = http_json(keeper_health_url)
    cap18 = uint_at(read_fn(rpc_url, art["escrow"], "totalPositionCap(address)", word_address(art["engine"])))
    gates.append(keeper_gate(art, health, cap18))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("engine keeper", False, f"unreadable: {exc}"))
  return gates


# --- post-state each action promises -----------------------------------------------------------

def landed(rpc_url: str, art: dict, i: int, action: dict, vault: str) -> bool:
  sig = action["sig"]
  if sig == "acceptOwnership()":
    return address_at(read_fn(rpc_url, action["to"], "owner()")) == vault.lower()
  if sig == "createMarket(string)":
    return last_market_id(rpc_url, art) >= MARKET_ID
  if sig == "setOraclesForMarket(uint256,address,address,address)":
    if last_market_id(rpc_url, art) < MARKET_ID:
      return False
    raw = read_fn(rpc_url, art["engine"], "getMarketFeeds(uint256)", word_uint(MARKET_ID))
    return address_at(raw, 0) == art["spotFeed"].lower()
  if sig == "setBaseAssetMarginFactor(uint256,uint256,uint256)":
    raw = read_fn(rpc_url, art["engine"], "baseMarginParams(uint256)", word_uint(MARKET_ID))
    return uint_at(raw, 0) == int(art["marginFactor"]) and uint_at(raw, 1) == int(art["imScale"])
  if sig == "whitelistAsset(address,uint256,uint8)":
    raw = read_fn(rpc_url, art["engine"], "assetDetails(address)", word_address(art["escrow"]))
    return uint_at(raw, 0) == 1 and uint_at(raw, 1) == BASE and uint_at(raw, 2) == MARKET_ID
  if sig == "setTotalPositionCap(address,uint256)":
    return uint_at(read_fn(rpc_url, art["escrow"], "totalPositionCap(address)", word_address(art["engine"]))) == int(art["cap"])
  if sig == "setWhitelistManager(address,bool)":
    return uint_at(read_fn(rpc_url, art["escrow"], "whitelistedManager(address)", word_address(art["engine"]))) == 1
  raise AssertionError(sig)


def print_sheet(actions: list[dict]) -> None:
  print()
  for i, a in enumerate(actions):
    print(f"  [{i}] to {a['to']}\n      data {a['data']}\n      digest {a['digest']}\n      {a['description']}")
  print()


# --- self-test: a synthetic artifact, since the real one exists only after the deploy -----------

def _synthetic() -> tuple[dict, list[dict], list[dict]]:
  art = {
    "escrow": "0x" + "e1" * 20, "spotFeed": "0x" + "f1" * 20, "engine": "0xa19e296021c9df25b90d96c2a0793cc3d0800758",
    "eurcToken": EURC, "aggregator": EURC_USD_AGGREGATOR, "marketId": MARKET_ID,
    "marginFactor": SIZED_MARGIN_FACTOR, "imScale": SIZED_IM_SCALE, "cap": MAX_CAP,
  }
  e, f, g = art["escrow"], art["spotFeed"], art["engine"]
  raw = [
    (e, sel("acceptOwnership()")),
    (f, sel("acceptOwnership()")),
    (g, sel("createMarket(string)") + encode_string(MARKET_NAME)),
    (g, sel("setOraclesForMarket(uint256,address,address,address)") + word_uint(MARKET_ID) + word_address(f) + word_uint(0) * 2),
    (g, sel("setBaseAssetMarginFactor(uint256,uint256,uint256)") + word_uint(MARKET_ID) + word_uint(SIZED_MARGIN_FACTOR) + word_uint(SIZED_IM_SCALE)),
    (g, sel("whitelistAsset(address,uint256,uint8)") + word_address(e) + word_uint(MARKET_ID) + word_uint(BASE)),
    (e, sel("setTotalPositionCap(address,uint256)") + word_address(g) + word_uint(MAX_CAP)),
  ]
  configure = [{"description": f"action {i}", "to": to, "value": "0", "data": data, "digest": digest(to, data)} for i, (to, data) in enumerate(raw)]
  enable_data = sel("setWhitelistManager(address,bool)") + word_address(g) + word_uint(1)
  enable = [{"description": "enable", "to": e, "value": "0", "data": enable_data, "digest": digest(e, enable_data)}]
  return art, configure, enable


def _refuses(art: dict, actions: list[dict], order: list[str], why: str) -> None:
  try:
    load_actions(json.loads(json.dumps(actions)), art, order)
  except SystemExit as refused:
    assert why in str(refused), (why, str(refused))
  else:
    raise AssertionError(f"accepted a batch that should be refused: {why}")


def _with(actions: list[dict], i: int, data: str, to: str | None = None) -> list[dict]:
  out = json.loads(json.dumps(actions))
  out[i]["data"] = data
  if to:
    out[i]["to"] = to
  out[i]["digest"] = digest(out[i]["to"], data)
  return out


def self_test() -> int:
  # every selector and signature this script pins must name a compiled function, not just match `cast sig`
  from abi_selectors import assert_script
  assert_script(__file__)
  for sig, expected in SELECTORS.items():
    assert sel(sig) == expected, (sig, sel(sig))
  assert encode_string("EUR") == word_uint(32) + word_uint(3) + "455552".ljust(64, "0")
  art, configure, enable = _synthetic()
  assert [a["sig"] for a in load_actions(json.loads(json.dumps(configure)), art, CONFIGURE_ORDER)] == CONFIGURE_ORDER
  assert [a["sig"] for a in load_actions(json.loads(json.dumps(enable)), art, ENABLE_ORDER)] == ENABLE_ORDER
  e, f, g = art["escrow"], art["spotFeed"], art["engine"]
  cngn = "0x37c976bb5d4887a714ef19af6b83e34fe2f37c98"
  # The enabling switch must never be inside the configuring batch, nor out of its position.
  _refuses(art, configure[:6] + enable, CONFIGURE_ORDER, "expected setTotalPositionCap")
  _refuses(art, configure + enable, CONFIGURE_ORDER, "actions, expected")
  # Market 1 anywhere: the cNGN slot.
  _refuses(art, _with(configure, 5, sel("whitelistAsset(address,uint256,uint8)") + word_address(e) + word_uint(1) + word_uint(BASE)),
           CONFIGURE_ORDER, "must whitelist the escrow")
  _refuses(art, _with(configure, 5, sel("whitelistAsset(address,uint256,uint8)") + word_address(cngn) + word_uint(MARKET_ID) + word_uint(BASE)),
           CONFIGURE_ORDER, "must whitelist the escrow")
  _refuses(art, _with(configure, 4, sel("setBaseAssetMarginFactor(uint256,uint256,uint256)") + word_uint(1) + word_uint(SIZED_MARGIN_FACTOR) + word_uint(SIZED_IM_SCALE)),
           CONFIGURE_ORDER, "haircut does not match")
  _refuses(art, _with(configure, 3, sel("setOraclesForMarket(uint256,address,address,address)") + word_uint(1) + word_address(f) + word_uint(0) * 2),
           CONFIGURE_ORDER, "spot feed")
  _refuses(art, _with(configure, 2, sel("createMarket(string)") + encode_string("NGN")), CONFIGURE_ORDER, "createMarket")
  _refuses(art, _with(configure, 6, sel("setTotalPositionCap(address,uint256)") + word_address(g) + word_uint(MAX_CAP + 1)),
           CONFIGURE_ORDER, "cap/manager")
  _refuses(art, _with(configure, 0, sel("acceptOwnership()"), to=g), CONFIGURE_ORDER, "accept ownership")
  _refuses(art, _with(enable, 0, sel("setWhitelistManager(address,bool)") + word_address(g) + word_uint(0)), ENABLE_ORDER, "open the escrow")
  _refuses(art, [{**configure[0], "digest": "0x" + "00" * 32}] + configure[1:], CONFIGURE_ORDER, "digest")
  _refuses(art, [{**configure[0], "value": "1"}] + configure[1:], CONFIGURE_ORDER, "sends value")
  _refuses({**art, "marginFactor": SIZED_MARGIN_FACTOR + 1}, configure, CONFIGURE_ORDER, "more generous")
  _refuses({**art, "cap": MAX_CAP + 1}, configure, CONFIGURE_ORDER, "cap is outside")
  _refuses({**art, "marketId": 1}, configure, CONFIGURE_ORDER, "not 2")
  # The enable gate's keeper check: the engine's keeper, live, not dry, on this escrow.
  cap = 250_000 * 10**18
  live = {"manager": g, "lastPassOk": True, "dryRun": False, "eurcEscrow": e, "maxEurcInventory": str(cap)}
  assert keeper_gate(art, live, cap).ok, "inventory limit equal to the cap passes"
  assert keeper_gate(art, {**live, "maxEurcInventory": str(cap // 2)}, cap).ok
  for broken in [{**live, "manager": "0xde0423d0a1e15536265c9513d2e0c10dab5835d4"}, {**live, "lastPassOk": False},
                 {**live, "dryRun": True}, {k: v for k, v in live.items() if k != "dryRun"}, {**live, "eurcEscrow": None},
                 {**live, "maxEurcInventory": str(cap + 1)}, {**live, "maxEurcInventory": None},
                 {k: v for k, v in live.items() if k != "maxEurcInventory"}, {**live, "maxEurcInventory": "0"}]:
    assert not keeper_gate(art, broken, cap).ok, broken
  print("self-test ok: selectors name compiled functions; a reordered, retargeted, market-1, over-generous, "
        "over-cap, wrong-digest or value-carrying batch is refused")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Gated proposal of the EURC-USDC listing on the MarginEngine")
  ap.add_argument("--batch", choices=["configure", "enable"], default="configure")
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--rehearsed", action="store_true", help="enable: the EURC fork suite has run against this escrow")
  ap.add_argument("--markets-url", default="https://api.numofx.com")
  ap.add_argument("--keeper-health-url", default=os.environ.get("ENGINE_KEEPER_HEALTH_URL", "http://127.0.0.1:9465/health"))
  args = ap.parse_args()
  if args.self_test:
    return self_test()

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc_url = os.environ.get("RPC_URL", "")
  vault = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not rpc_url:
    raise SystemExit("RPC_URL is required (run via run-with-ssm-mark.sh)")
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault} is not the recorded vault {EXPECTED_VAULT}")
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: deploy with scripts/deploy-eurc-spot.s.sol first")

  art = json.loads(ARTIFACT.read_text())
  configure = load_actions(CONFIGURE_ACTIONS, art, CONFIGURE_ORDER)
  actions = configure if args.batch == "configure" else load_actions(ENABLE_ACTIONS, art, ENABLE_ORDER)

  def gates(created: bool) -> list[Gate]:
    g = [gate_chain(rpc_url), gate_custody(rpc_url, art, vault), gate_market(rpc_url, art, created),
         gate_escrow(rpc_url, art, vault), gate_feed(rpc_url, art, vault)]
    if args.batch == "enable":
      done = all(landed(rpc_url, art, i, a, vault) for i, a in enumerate(configure))
      g.append(Gate("configure landed", done, "every configuring action's post-state reads back" if done else "a configuring action has not landed"))
      g.extend(gate_services(rpc_url, art, args.markets_url, args.keeper_health_url))
      g.append(Gate("fork rehearsal", args.rehearsed, "--rehearsed given" if args.rehearsed else "pass --rehearsed once EurcSpotFork has run against this escrow"))
    return g

  def created() -> bool:
    return last_market_id(rpc_url, art) >= MARKET_ID

  print(f"batch {args.batch}: {len(actions)} action(s); gates:")
  if not report(gates(created())):
    print("\nGATES FAILED: nothing proposed.")
    print_sheet(actions)
    return 1
  print_sheet(actions)
  if not args.propose:
    print("dry run: nothing proposed. Re-run with --propose; compare each digest with MPCVault before approving.")
    return 0

  token, vault_uuid = os.environ.get("MPCVAULT_TOKEN", ""), os.environ.get("MPCVAULT_VAULT", "")
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  for i, a in enumerate(actions):
    if landed(rpc_url, art, i, a, vault):
      print(f"  [{i}] already landed on chain; skipping {a['description']}")
      continue
    # createMarket is action 2: before it the engine must have one market, after it exactly two.
    after_create = args.batch == "enable" or i > CONFIGURE_ORDER.index("createMarket(string)")
    if i > 0 and not report(gates_after_mining(lambda: gates(after_create))):
      raise SystemExit(f"a gate failed before action {i}. Stop and investigate.")
    uuid = propose(token, vault_uuid, vault, a)
    print(f"  [{i}] proposed uuid={uuid}\n       {a['description']}\n       digest {a['digest']}\n       -> approve in MPCVault now")
    deadline, tx_hash = time.time() + CONFIRM_TIMEOUT_SEC, None
    while time.time() < deadline and not tx_hash:
      time.sleep(CONFIRM_POLL_SEC)
      tx_hash = request_tx_hash(token, uuid)
    if not tx_hash:
      raise SystemExit(f"action {i} not approved within the timeout")
    confirm_on_chain(rpc_url, tx_hash)
    if not await_postcondition(lambda: landed(rpc_url, art, i, a, vault)):
      raise SystemExit(f"action {i} mined but its post-state does not read back after 60s. Stop and investigate.")
    if a["sig"] == "createMarket(string)" and last_market_id(rpc_url, art) != MARKET_ID:
      raise SystemExit(f"createMarket landed but lastMarketId is not {MARKET_ID}: market {MARKET_ID} is not ours. Stop.")
    print(f"       landed: {a['description']}")
  print(f"\nbatch {args.batch} complete.")
  return 0


if __name__ == "__main__":
  sys.exit(main())
