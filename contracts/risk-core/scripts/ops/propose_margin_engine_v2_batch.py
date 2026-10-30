#!/usr/bin/env python3
"""Propose MarginEngine v2's vault batches to MPCVault, and take v1 close-only (docs/margin-engine-v2.md).

  setup   MARGIN_ENGINE_V2_VAULT_ACTIONS.json, from deploy-margin-engine-v2.s.sol: accept the four contracts the deployer
          nominated (engine, viewer, future, forward feed), wire v2 into the USDC cash, every base escrow v1 lists (at
          v1's cap, except EURC's at 0: see eurc-cap) and the auction, and grant it v1's guardian. Opens nothing new.
  enable  MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS.json: the future's cap under v2, then the future on the TradeModule. The
          only actions that open v2's future. Proposed only while every gate below passes, re-read before each action.
  cap     future.setTotalPositionCap(v2, N): resize the open future, gated as enable at the NEW cap.
  v1-close-only  every cap v1 holds set to that asset's open interest under v1: each base escrow v1 lists and v1's
          future. Built here, not from an artifact, from v1's own reads in one block, and rebuilt before each action
          because open interest moves. Never above the cap it replaces (it is not a raise). A cap that lands under
          open interest (it rose between the read and the approval) is the same close-only, not a freeze: the deployed
          viewer checks only the assets a transfer touched (test/fork/MarginEngineV1CloseOnlyFork.t.sol proves both,
          and that under the SRM's check the same cap freezes holders). The perp's cap under v1 is already 0 and is not
          touched. A re-run proposes again wherever closing has left a cap above open interest. Close-only stops every
          v1 account buying base, so a v1 maker could only sell: refused while any v1 account rests a spot bid, and
          while the makers' accounts are under v1.
  eurc-cap  eurcEscrow.setTotalPositionCap(v2, N EURC): open EURC on v2. The cap is per manager, so the venue's EURC is
          v1's cap plus v2's, and v1's 40,000 was sized to depth for the whole venue: gated on that total, not on N.
          After v1-close-only, when v1's cap is its open interest.

Every artifact action is rebuilt here from MARGIN_ENGINE_V2.json and must match the file exactly (to, calldata,
value), its digest recomputed (keccak(to || keccak(data)), deploy-margin-engine-v2.s.sol's convention). An action whose
postcondition already holds is skipped, so a re-run proposes only what is left.

Enable gates (all read live, all required unless marked):
  custody   the vault owns v2's four; the setup batch has landed; v2's future is closed (cap 0, not on the TradeModule)
  feeds     the index answers and is <= 600s old
  marks     v2's future was marked within 2h: its forward keeper is publishing
  sm        the SecurityModule's cash covers an SM_MOVE (15%) step on the future's one side at the cap being opened, at
            today's mark (check_perp_pager.sm_required_usd_linear: the whole step, an upper bound until #245's coverage
            test runs against v2), on top of what the module covers for every other v2 series at its live cap
            (OTHER_SERIES: EURC_FUTURE_V2.json beside this artifact, once deployed)
  gaps      informational: the cap the SecurityModule covers against an overnight devaluation gap of 30/40/50%, every
            contract a long opened at IM (the doc's table, at today's mark and cash)
  pager     check_perp_pager.py ran OK within 3 minutes with a provider and a dead-man's switch, and its last run read
            the future under v2 (futureManager, or futureManagers once it reads both engines: #258)
  keeper    v2's liquidation keeper (ENGINE_V2_KEEPER_HEALTH_URL, no default until #258 runs one): /health OK, not
            DRY_RUN, manager v2; its funding account under v2 holds no future and the IM for one full side at the cap
            (cap / 2 x size x mark x imReq: ~2,786 USDC for 30 contracts at 0.000743)
  fills     markets-service lists v2's future (asset_address, sub_id) with fill_band_enforced and the chain's band,
            index -/+ markIndexBand(expiry), in USDC per cNGN as the chain reads it (no inversion)
  rfq       the RfqModule is not on the TradeModule's Matching
  parity    every setting the deploy made, re-read now the vault owns it: each market against the same market on v1, the
            rest against the artifact; the single-use deployer holds nothing and has sent nothing since

v1-close-only gates:
  custody   the vault owns every asset whose cap it sets
  perp      v1's perp cap is 0 (delisted, exchange #251)
  v2        v2 takes every escrow v1 lists (whitelisted, cap > 0) and the cash, and its future is open (cap > 0, on the
            TradeModule): holders have somewhere to go
  venue     markets-service lists v1's future close-only (future.close_only: true) and no listing still sends accounts
            to v1 (margin_manager_address): new spot deposits default to v2
  bids      no account under v1 (SubAccounts.manager) rests a buy on a spot book (/v1/book of each spot listing): its
            fill would raise the escrow's position under v1 over the new cap and revert. The makers' accounts
            (MM_SUBACCOUNT_IDS, default #34 and #36) are refused under v1 even while they rest nothing: a paused maker
            resumes. The makers move to v2 accounts first
  caps      each new cap is open interest, read now, and no higher than the cap it replaces
  (EURC's escrow need only be whitelisted for v2: its cap there is eurc-cap's, which comes after)

eurc-cap gates (each read live):
  custody   the vault owns the EURC escrow, it wraps EURC, and v2 is whitelisted on it (setup landed)
  cap       N is not v2's cap already, and not under v2's EURC open interest (that is close-only, not a cap)
  depth     propose_eurc_spot_batch's depth stress gate (a fresh eurc_depth reading: 50% of the 2% sell depth without
            the main pool's largest LP) at the venue's total, v1's cap (or its open interest, if higher) + N
  keeper    the engine keeper's MAX_EURC_INVENTORY (ENGINE_KEEPER_HEALTH_URL /health maxEurcInventory) is set and at
            least that total

It NEVER signs, executes or broadcasts. Without --propose it prints the gates and the sheet. With --propose each action
goes to the MPCVault app for a human to approve, one at a time, from the vault, through perp_cap_guard.

Env (or ~/.numo-mark-keeper.env): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.

  python3 scripts/ops/propose_margin_engine_v2_batch.py setup              # check + sheet, proposes nothing
  python3 scripts/ops/propose_margin_engine_v2_batch.py setup --propose
  python3 scripts/ops/propose_margin_engine_v2_batch.py enable
  python3 scripts/ops/propose_margin_engine_v2_batch.py cap --contracts 28
  python3 scripts/ops/propose_margin_engine_v2_batch.py v1-close-only     # gates + the caps at today's open interest
  python3 scripts/ops/propose_margin_engine_v2_batch.py v1-close-only --propose
  python3 scripts/ops/propose_margin_engine_v2_batch.py eurc-cap --eurc 30000   # gates + the action, proposes nothing
  python3 scripts/ops/propose_margin_engine_v2_batch.py --self-test
  python3 scripts/ops/propose_margin_engine_v2_batch.py enable --local --dir deployments/31337 --json   # a fork only
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import propose_margin_engine_batch as v1p  # noqa: E402  the v1 proposer: its chain reads, gates and checks
from check_feed_staleness import feed_age  # noqa: E402
from check_perp_pager import SM_MOVE, sm_required_usd_linear  # noqa: E402  one implementation of the coverage rule
from perp_cap_guard import opens_a_perp_cap  # noqa: E402
import perp_cap_guard  # noqa: E402
from propose_cngn_spot_batch import (  # noqa: E402  one implementation of the MPCVault transport
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
import propose_eurc_spot_batch as eurc  # noqa: E402  the EURC listing's depth stress gate, one implementation
from propose_perp_enable_batch import gate_pager, http_json, keeper_gate  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

Gate, Chain, report = v1p.Gate, v1p.Chain, v1p.report
word_address, word_uint, digest = v1p.word_address, v1p.word_uint, v1p.digest

ROOT = v1p.ROOT
NAME = "MARGIN_ENGINE_V2"
V1_NAME = "MARGIN_ENGINE"
FILES = {"setup": f"{NAME}_VAULT_ACTIONS.json", "enable": f"{NAME}_ENABLE_VAULT_ACTIONS.json"}
FEED_MAX_AGE_SEC = v1p.FEED_MAX_AGE_SEC
MARK_MAX_AGE_SEC = v1p.MARK_MAX_AGE_SEC
ENGINE_KEEPER_MIN_ETH = v1p.ENGINE_KEEPER_MIN_ETH
# AssetType in IMarginEngine: Base = 3, Perpetual = 2, Future = 4 (the order v1p's parity reads them in)
PERP, BASE, FUTURE = 2, 3, 4
# The overnight devaluation gaps docs/margin-engine-v2.md sizes the cap against
GAPS = (0.30, 0.40, 0.50)
# The markets v2 copies from v1, by id - 1, as deploy-margin-engine-v2.s.sol's V1_MARKETS: v2 deploys only once v1
# lists EURC-USDC (docs/margin-engine-v2.md, Migration step 1)
V1_MARKETS = ("NGN", "EUR")
# setup opens EURC's escrow on v2 at 0: its cap is per manager, and v1's was sized to depth for the whole venue
EURC_INDEX = eurc.MARKET_ID - 1

SIGNATURES = {**v1p.SIGNATURES, "lastMarketId": "lastMarketId()", "manager": "manager(uint256)"}
PINNED = {**v1p.PINNED, "lastMarketId": "0x565eb87c", "manager": "0x52981457"}
# The spot makers' accounts under v1: #34 quotes cNGN-USDC, #36 EURC-USDC (the MM wallet 0x3448ac0A…7B, via Matching).
# Set MM_SUBACCOUNT_IDS to their v2 accounts once they move.
DEFAULT_MM_SUBACCOUNT_IDS = "34,36"


def selector(name: str) -> str:
  return "0x" + keccak(SIGNATURES[name].encode()).hex()[:8]


def owned(d: dict) -> list[str]:
  return [d["manager"], d["viewer"], d["future"], d["forwardFeed"]]


# ---------------------------------------------------------------------------------------------
# the artifact batches
# ---------------------------------------------------------------------------------------------

def setup_caps(d: dict) -> list[int]:
  """v2's cap on each escrow after setup: the artifact's, but EURC's 0 whatever the artifact says (eurc-cap opens it)."""
  return [0 if i == EURC_INDEX else int(cap) for i, cap in enumerate(d["escrowCaps"])]


def expected_actions(batch: str, d: dict) -> list[tuple[str, str]]:
  """(to, calldata) for each action, in order, as deploy-margin-engine-v2.s.sol writes them."""
  m = word_address(d["manager"])
  whitelist = selector("setWhitelistManager") + m + word_uint(1)
  if batch == "setup":
    escrows = [a for e, cap in zip(d["escrows"], setup_caps(d))
               for a in ((e, whitelist), (e, selector("setTotalPositionCap") + m + word_uint(cap)))]
    return [*[(c, selector("acceptOwnership")) for c in owned(d)], (d["cash"], whitelist), *escrows,
            (d["auction"], whitelist), (d["manager"], selector("setGuardian") + word_address(d["guardian"]))]
  return [(d["future"], selector("setTotalPositionCap") + m + word_uint(int(d["futureOICap"]))),
          (d["tradeModule"], selector("setDatedFutureAsset") + word_address(d["future"]) + word_uint(1))]


def postconditions(chain: Chain, batch: str, d: dict, vault: str) -> list:
  """One read per action, aligned with expected_actions: whether it has landed."""
  m = word_address(d["manager"])
  w = lambda to, name, *args: chain.word(to, selector(name) + "".join(args))  # noqa: E731
  if batch == "setup":
    escrows = [p for e, cap in zip(d["escrows"], setup_caps(d))
               for p in ((lambda e=e: w(e, "whitelistedManager", m) == 1),
                         (lambda e=e, cap=cap: w(e, "totalPositionCap", m) == cap))]
    return [*[(lambda c=c: chain.address(c, "owner").lower() == vault.lower()) for c in owned(d)],
            lambda: w(d["cash"], "whitelistedManager", m) == 1, *escrows,
            lambda: w(d["auction"], "managerWhitelisted", m) == 1,
            lambda: chain.address(d["manager"], "guardian").lower() == d["guardian"].lower()]
  return [lambda: w(d["future"], "totalPositionCap", m) == int(d["futureOICap"]),
          lambda: w(d["tradeModule"], "isDatedFutureAsset", word_address(d["future"])) == 1]


def verify_actions(batch: str, d: dict, actions: list[dict]) -> None:
  """Refuses a file that is not exactly what the deployment implies: a wrong target, manager, cap, value or digest,
  or an action added, dropped or reordered."""
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
# gates: setup and enable
# ---------------------------------------------------------------------------------------------

def markets_gate(escrows: list, v1_markets: int) -> Gate:
  """v2 lists exactly NGN and EUR, and v1 still lists those two: a v2 deployed before EURC-USDC has no EUR market."""
  ok = len(escrows) == len(V1_MARKETS) and v1_markets == len(V1_MARKETS)
  return Gate("markets", ok, f"v2 lists {len(escrows)} market(s), v1 {v1_markets}; both must be {len(V1_MARKETS)} "
              f"({', '.join(V1_MARKETS)}): redeploy v2 once v1 lists EURC-USDC" if not ok
              else f"v2 and v1 both list {', '.join(V1_MARKETS)}")


def gate_setup(chain: Chain, d: dict, vault: str) -> list[Gate]:
  pending = [c for c in owned(d) if vault.lower() not in
             (chain.address(c, "owner").lower(), chain.address(c, "pendingOwner").lower())]
  reused = [c for c in (d["cash"], *d["escrows"], d["auction"]) if chain.address(c, "owner").lower() != vault.lower()]
  return [
    Gate("nominated", not pending, f"not nominated to the vault: {', '.join(pending)}" if pending
         else "all four nominated to or owned by the vault"),
    Gate("reused", not reused, f"vault does not own {', '.join(reused)}" if reused
         else f"vault owns the cash, {len(d['escrows'])} escrow(s) and the auction"),
    markets_gate(d["escrows"], chain.word(d["v1"], selector("lastMarketId"))),
  ]


def mark_usdc_per_cngn(chain: Chain, d: dict) -> float:
  return chain.word(d["future"], selector("futureContracts") + word_uint(int(d["subId"])), 5) / 1e18


def one_side_usd(cap_contracts: float, size_cngn: float, mark: float) -> float:
  """One side of the future at `cap_contracts` (the cap counts both sides), in USDC at the mark."""
  return cap_contracts / 2 * size_cngn * mark


def sm_gate(sm_cash: float, side_usd: float, reserved: float = 0.0, held_for: str = "") -> Gate:
  """`reserved` is what the module already covers for another series at its live cap (the SecurityModule is one, and
  every v2 future draws on it): this series gets what is left."""
  required = sm_required_usd_linear(side_usd)
  what = f"a {SM_MOVE * 100:.0f}% step on the future's one side ${side_usd:,.0f}"
  also = f" + ${reserved:,.0f} held for {held_for}" if reserved else ""
  if sm_cash < required + reserved:
    return Gate("sm", False, f"SecurityModule ${sm_cash:,.0f} is under the ${required:,.0f} {what} costs{also}: fund it, "
                             "or open a lower cap")
  return Gate("sm", True, f"SecurityModule ${sm_cash:,.0f} covers ${required:,.0f} for {what}{also}")


def gap_max_caps(sm_cash: float, contract_usd: float, im: float) -> list[tuple[float, int]]:
  """(gap, the largest cap the SecurityModule covers) for each gap: every contract a long opened at IM, bankrupt past it,
  so the module pays contract_usd x (gap - IM) a contract (docs/margin-engine-v2.md)."""
  return [(g, math.floor(sm_cash / (contract_usd * (g - im)))) for g in GAPS]


def gaps_gate(sm_cash: float, contract_usd: float, im: float, cap: float) -> Gate:
  """Informational: the decision the cap rests on, at today's mark and cash. Never fails."""
  caps = gap_max_caps(sm_cash, contract_usd, im)
  over = [f"{g * 100:.0f}%" for g, c in caps if cap > c]
  return Gate("gaps", True, "max cap at a " + ", ".join(f"{g * 100:.0f}% gap {c}" for g, c in caps)
              + f" (opening {cap:g}" + (f": NOT covered at {', '.join(over)})" if over else ")"))


def gate_sm_at_cap(chain: Chain, d: dict, stack: dict, cap: float, reserved: tuple[float, str] = (0.0, "")) -> list[Gate]:
  try:
    sm_cash = chain.balance(int(stack["securityModuleAccount"]), d["cash"]) / 1e18
    size = chain.word(d["future"], selector("contractSize")) / 1e18
    mark = mark_usdc_per_cngn(chain, d)
    im = chain.word(d["manager"], selector("futureMarginRequirements") + word_uint(int(d["marketId"])), 1) / 1e18
    return [sm_gate(sm_cash, one_side_usd(cap, size, mark), *reserved), gaps_gate(sm_cash - reserved[0], size * mark, im, cap)]
  except Exception as exc:  # noqa: BLE001 -- unreadable is a failed gate
    return [Gate("sm", False, f"SecurityModule coverage unreadable: {str(exc)[:80]}")]


# Other v2 series, by artifact: each one's SecurityModule draw at its live cap is held back from this one's (sm_gate)
OTHER_SERIES = ("EURC_FUTURE_V2",)


def series_sm_usd(chain: Chain, d: dict) -> float:
  """What the SecurityModule covers for a v2 series at its live cap and mark: the whole SM_MOVE step on one side."""
  m = word_address(d["manager"])
  cap = chain.word(d["future"], selector("totalPositionCap") + m) / 1e18
  size = chain.word(d["future"], selector("contractSize")) / 1e18
  mark = chain.word(d["future"], selector("futureContracts") + word_uint(int(d["subId"])), 5) / 1e18
  return sm_required_usd_linear(one_side_usd(cap, size, mark))


def other_series_reserved(chain: Chain, artifact_dir: Path, names: tuple[str, ...] = OTHER_SERIES) -> tuple[float, str]:
  """(USDC, what) the SecurityModule already covers for the other v2 series deployed in `artifact_dir`."""
  total, held = 0.0, []
  for name in names:
    path = artifact_dir / f"{name}.json"
    if not path.exists():
      continue
    other = json.loads(path.read_text())
    usd = series_sm_usd(chain, other)
    if usd:
      total += usd
      held.append(f"{other.get('symbol', name)} at its cap")
  return total, ", ".join(held)


def engine_keeper_min_cash(cap: float, size_cngn: float, mark: float, im: float) -> float:
  """What v2's keeper must hold, USDC: the IM to take over one full side of the future at the cap."""
  return one_side_usd(cap, size_cngn, mark) * im


def gate_engine_keeper(chain: Chain, d: dict, cap: float) -> Gate:
  url = os.environ.get("ENGINE_V2_KEEPER_HEALTH_URL", "")
  try:
    size = chain.word(d["future"], selector("contractSize")) / 1e18
    im = chain.word(d["manager"], selector("futureMarginRequirements") + word_uint(int(d["marketId"])), 1) / 1e18
    floor = engine_keeper_min_cash(cap, size, mark_usdc_per_cngn(chain, d), im)
  except Exception as exc:  # noqa: BLE001
    return Gate("keeper", False, f"the keeper's floor unreadable: {str(exc)[:80]}")
  if not url:
    return Gate("keeper", False, "ENGINE_V2_KEEPER_HEALTH_URL is not set: v2 needs its own keeper (#258)")
  return keeper_gate(chain.url, d["manager"], "MarginEngine v2", d["cash"], [(d["future"], int(d["subId"]))],
                     url, floor, ENGINE_KEEPER_MIN_ETH)


def chain_fill_band(spot_word: int, band_word: int) -> tuple[float, float]:
  """(low, high) in USDC per cNGN: the index as the feed reads it, -/+ markIndexBand. v2 inverts nothing."""
  index, band = spot_word / 1e18, band_word / 1e18
  return index * (1 - band), index * (1 + band)


def gate_fills(chain: Chain, d: dict, markets_url: str) -> Gate:
  try:
    listing = find_listing(markets(markets_url), d["future"], d["subId"])
  except Exception as exc:  # noqa: BLE001
    return Gate("fills", False, f"markets-service /v1/markets unreadable: {str(exc)[:80]}")
  try:
    low, high = chain_fill_band(chain.word(d["indexFeed"], selector("getSpot")),
                                chain.word(d["future"], selector("markIndexBand") + word_uint(int(d["expiry"]))))
  except Exception as exc:  # noqa: BLE001
    return Gate("fills", False, f"the chain's fill band unreadable: {str(exc)[:80]}")
  return v1p.fills_gate(listing, low, high, unit="USDC per cNGN")


def markets(markets_url: str) -> list[dict]:
  body = http_json(f"{markets_url.rstrip('/')}/v1/markets")
  return (body.get("markets", body) if isinstance(body, dict) else body) or []


def find_listing(entries: list[dict], asset: str, sub_id) -> dict | None:
  return next((e for e in entries if str(e.get("asset_address", "")).lower() == asset.lower()
               and str(e.get("sub_id", "")) == str(sub_id)), None)


def gate_parity(chain: Chain, d: dict, vault: str) -> Gate:
  """Every setting the deploy made, re-read: each market against the same market on v1, the rest against the artifact
  (deploy-margin-engine-v2.s.sol's assertParity and assertDeployment, now the vault owns it all)."""
  v2, v1, future, feed, viewer = d["manager"], d["v1"], d["future"], d["forwardFeed"], d["viewer"]
  w = lambda to, name, *args, index=0: chain.word(to, selector(name) + "".join(args), index)  # noqa: E731
  a = lambda to, name, *args: "0x" + chain.call(to, selector(name) + "".join(args))[24:64]  # noqa: E731
  pairs: list[tuple[str, object, object]] = [("markets", w(v2, "lastMarketId"), w(v1, "lastMarketId"))]
  for name in ("maxAccountSize", "borrowingEnabled", "feeRecipientAcc", "minOIFee"):
    pairs.append((name, w(v2, name), w(v1, name)))
  pairs.append(("stableFeed", a(v2, "stableFeed"), a(v1, "stableFeed")))
  for i in range(2):
    pairs.append((f"depegParams[{i}]", w(v2, "depegParams", index=i), w(v1, "depegParams", index=i)))
  for market in range(1, w(v2, "lastMarketId") + 1):
    mk = word_uint(market)
    for name, n in (("baseMarginParams", 2), ("oracleContingencyParams", 4)):
      for i in range(n):
        pairs.append((f"market {market} {name}[{i}]", w(v2, name, mk, index=i), w(v1, name, mk, index=i)))
    pairs.append((f"market {market} base", a(v2, "assetMap", mk, word_uint(BASE)), a(v1, "assetMap", mk, word_uint(BASE))))
    pairs.append((f"market {market} base is the artifact's", a(v2, "assetMap", mk, word_uint(BASE)), d["escrows"][market - 1]))
    pairs.append((f"market {market} spot feed", a(v2, "getMarketFeeds", mk), a(v1, "getMarketFeeds", mk)))
    pairs.append((f"market {market} lists no perp", a(v2, "assetMap", mk, word_uint(PERP)), "0x" + "00" * 20))
  callee_slot = "0x" + keccak(bytes.fromhex(word_address(d["indexFeed"]) + word_uint(v1p.WHITELISTED_CALLEE_SLOT))).hex()
  m1 = word_uint(int(d["marketId"]))
  pairs += [
    ("the index is a callee", int(rpc(chain.url, "eth_getStorageAt", [v2, callee_slot, "latest"]), 16), 1),
    ("assetMap future", a(v2, "assetMap", m1, word_uint(FUTURE)), future),
    ("futureMarginRequirements mm", w(v2, "futureMarginRequirements", m1, index=0), int(d["futureMMReq"])),
    ("futureMarginRequirements im", w(v2, "futureMarginRequirements", m1, index=1), int(d["futureIMReq"])),
    ("liquidation", a(v2, "liquidation"), d["auction"]),
    ("viewer", a(v2, "viewer"), viewer),
    ("viewer's engine", a(viewer, "marginEngine"), v2),
    ("guardian", a(v2, "guardian"), d["guardian"]),
    ("future OI fee", w(viewer, "OIFeeRateBPS", word_address(future)), 0),
    ("contract size", w(future, "contractSize"), int(d["contractSize"])),
    ("future index", a(future, "indexFeed"), d["indexFeed"]),
    ("future forward feed", a(future, "forwardFeed"), feed),
    ("forward feed's index", a(feed, "spotFeed"), d["indexFeed"]),
    ("forward signer", w(feed, "isSigner", word_address(d["forwardSigner"])), 1),
    ("forward quorum", w(feed, "requiredSigners"), 1),
    ("forward heartbeat", w(feed, "heartbeat"), int(d["forwardHeartbeat"])),
  ]
  for name in ("maxMarkDeviation", "maxMarkDelay", "maxMarkIndexDeviation", "minMarkIndexDeviation", "bandNarrowingPeriod",
               "fixingWindow", "maxSampleGap", "fallbackDelay", "minMarkInterval"):
    pairs.append((f"future {name}", w(future, name), int(d[name])))
  deployer = d["deployer"]
  sent = int(rpc(chain.url, "eth_getTransactionCount", [deployer, "latest"]), 16)
  pairs += [("deployer transactions since the deploy", sent - int(d["deployerNonce"]), 0),
            ("deployer signs the forward", w(feed, "isSigner", word_address(deployer)), 0)]
  for c in owned(d):
    pairs.append((f"{c} owner is not the deployer", a(c, "owner").lower() == deployer.lower(), False))
    pairs.append((f"{c} nominee is not the deployer", a(c, "pendingOwner").lower() == deployer.lower(), False))
  bad = v1p.parity_mismatches(pairs)
  if bad:
    return Gate("parity", False, f"{len(bad)} setting(s) differ from the deploy: " + "; ".join(bad[:4]))
  return Gate("parity", True, f"all {len(pairs)} settings as deployed: every market as on v1, the rest as in the artifact; "
              f"deployer {deployer} holds nothing")


def gate_live(chain: Chain, d: dict) -> list[Gate]:
  """The index is fresh and v2's future is being marked."""
  gates = []
  try:
    age, _ = feed_age(chain.url, d["indexFeed"])
    gates.append(Gate("feeds", age <= FEED_MAX_AGE_SEC, f"index {age}s old (limit {FEED_MAX_AGE_SEC}s)"))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("feeds", False, f"index unreadable: {str(exc)[:80]}"))
  mark_age = chain.head() - chain.word(d["future"], selector("futureContracts") + word_uint(int(d["subId"])), 4)
  gates.append(Gate("marks", mark_age <= MARK_MAX_AGE_SEC, f"last mark {mark_age}s ago (limit {MARK_MAX_AGE_SEC}s)"
                    + ("" if mark_age <= MARK_MAX_AGE_SEC else ": is v2's forward keeper publishing?")))
  return gates


def pager_state() -> Path:
  return Path(os.environ.get("PAGER_STATE_FILE", Path.home() / ".numo-perp-pager.json"))


def gate_enable(chain: Chain, d: dict, stack: dict, vault: str, reserved: tuple[float, str] = (0.0, "")) -> list[Gate]:
  m = word_address(d["manager"])
  not_owned = [c for c in owned(d) if chain.address(c, "owner").lower() != vault.lower()]
  unwired = [i for i, holds in enumerate(postconditions(chain, "setup", d, vault)) if not holds()]
  cap = chain.word(d["future"], selector("totalPositionCap") + m)
  registered = chain.word(d["tradeModule"], selector("isDatedFutureAsset") + word_address(d["future"]))
  problems = ([f"vault does not own {', '.join(not_owned)}"] if not_owned else []) + \
             ([f"setup actions {unwired} have not landed"] if unwired else []) + \
             ([f"v2's future is not closed (cap {cap}, registered {bool(registered)})"] if cap or registered else [])
  oi_cap = int(d["futureOICap"]) / 1e18
  return [Gate("custody", not problems, "; ".join(problems) or "vault owns all four; setup landed; v2's future closed"),
          *gate_live(chain, d), *gate_sm_at_cap(chain, d, stack, oi_cap, reserved),
          gate_pager(pager_state(), future_manager=d["manager"]), gate_engine_keeper(chain, d, oi_cap),
          gate_fills(chain, d, os.environ.get("MARKETS_URL", "https://api.numofx.com")),
          v1p.gate_rfq(chain, {"perpTradeModule": d["tradeModule"]}), gate_parity(chain, d, vault)]


def gate_cap(chain: Chain, d: dict, stack: dict, vault: str, contracts: int,
             reserved: tuple[float, str] = (0.0, "")) -> list[Gate]:
  """What a larger cap changes, at the NEW cap: the SecurityModule and the keeper's cash; and that v2 is live."""
  m = word_address(d["manager"])
  current = chain.word(d["future"], selector("totalPositionCap") + m) / 1e18
  oi = chain.word(d["future"], selector("totalPosition") + m) / 1e18
  return [Gate("custody", chain.address(d["future"], "owner").lower() == vault.lower(), "vault owns v2's future"),
          v1p.cap_bounds_gate(contracts, current, oi), *gate_live(chain, d),
          *gate_sm_at_cap(chain, d, stack, contracts, reserved),
          gate_pager(pager_state(), future_manager=d["manager"]), gate_engine_keeper(chain, d, contracts)]


# ---------------------------------------------------------------------------------------------
# v1 close-only
# ---------------------------------------------------------------------------------------------

def close_only_action(asset: str, v1: str, open_interest: int, what: str) -> dict:
  """asset.setTotalPositionCap(v1, open interest): v1 holds what it has and opens nothing more."""
  data = selector("setTotalPositionCap") + word_address(v1) + word_uint(open_interest)
  return {"description": f"{what}.setTotalPositionCap(v1, {open_interest}) [close-only: v1's open interest]",
          "to": asset, "value": "0", "data": data, "digest": digest(asset, data)}


def v1_capped_assets(chain: Chain, v1d: dict) -> list[tuple[str, str]]:
  """(asset, label) for every cap v1 holds open: each market's base escrow, and the future. Not the perp (cap 0)."""
  v1 = v1d["manager"]
  escrows = [("0x" + chain.call(v1, selector("assetMap") + word_uint(m) + word_uint(BASE))[24:64], f"market {m} escrow")
             for m in range(1, chain.word(v1, selector("lastMarketId")) + 1)]
  return [*escrows, (v1d["future"], "v1 future")]


def close_only_actions(chain: Chain, v1d: dict) -> list[dict]:
  """Rebuilt from the chain each time: open interest moves."""
  m = word_address(v1d["manager"])
  return [close_only_action(asset, v1d["manager"], chain.word(asset, selector("totalPosition") + m), what)
          for asset, what in v1_capped_assets(chain, v1d)]


def close_only_caps_gate(rows: list[tuple[str, int, int]]) -> Gate:
  """(label, current cap, open interest) for each: the new cap is open interest, never a raise."""
  raises = [f"{what} (cap {cap / 1e18:,.4f} < open interest {oi / 1e18:,.4f})" for what, cap, oi in rows if oi > cap]
  if raises:
    return Gate("caps", False, "open interest is already over the cap, so setting it would raise the cap: "
                + "; ".join(raises) + ". Investigate before proposing")
  return Gate("caps", True, "; ".join(f"{what} {cap / 1e18:,.4f} -> {oi / 1e18:,.4f}" for what, cap, oi in rows))


def venue_gate(entries: list[dict], v1d: dict) -> Gate:
  """markets-service lists v1's future close-only, and no listing sends accounts to v1."""
  v1 = v1d["manager"].lower()
  listing = find_listing(entries, v1d["future"], v1d["subId"])
  problems = []
  if listing is None:
    problems.append("v1's future is not on /v1/markets: holders could not close it on the venue")
  elif (listing.get("future") or {}).get("close_only") is not True:
    problems.append("v1's future is listed but not close-only (future.close_only)")
  still = [str(e.get("market") or e.get("asset_address")) for e in entries
           if e is not listing and str(e.get("margin_manager_address", "")).lower() == v1]
  if still:
    problems.append(f"{', '.join(still)} still send accounts to v1 (margin_manager_address): move them to v2 first")
  return Gate("venue", not problems, "; ".join(problems) or "v1's future is close-only on the venue; no listing sends accounts to v1")


def maker_accounts() -> list[str]:
  """The spot makers' accounts, checked whether or not they rest a bid at the read: a paused maker resumes."""
  return [s.strip() for s in os.environ.get("MM_SUBACCOUNT_IDS", DEFAULT_MM_SUBACCOUNT_IDS).split(",") if s.strip()]


def v1_bids_gate(bids: list[tuple[str, str, str]], makers: list[str], managers: dict[str, str], v1: str) -> Gate:
  """(market, account, order id) for each resting spot buy, and each account's manager. A v1 account buying base raises
  the escrow's position under v1 over its close-only cap, so its fill reverts: the bid is frozen
  (MarginEngineV1CloseOnlyFork.testAV1HolderSellsCngnToV2ButCannotBuyIt)."""
  v1 = v1.lower()
  frozen = sorted({f"#{acc} on {market}" + (" (maker)" if oid.startswith("mm:") else "")
                   for market, acc, oid in bids if managers.get(acc, "").lower() == v1})
  idle = [f"#{acc}" for acc in makers if managers.get(acc, "").lower() == v1 and acc not in {b[1] for b in bids}]
  problems = ([f"v1 accounts rest base bids that would freeze: {', '.join(frozen)}"] if frozen else []) + \
             ([f"maker accounts {', '.join(idle)} are under v1 (MM_SUBACCOUNT_IDS)"] if idle else [])
  if problems:
    return Gate("bids", False, "; ".join(problems) + ". Move the makers to v2 accounts first")
  return Gate("bids", True, f"no v1 account rests a spot bid ({len(bids)} read); makers {', '.join(makers) or 'none'} not on v1")


def resting_buys(market: str, book: dict) -> list[tuple[str, str, str]]:
  """(market, account, order id) for each active buy of base in a /v1/book, by its side, not the list it sits in."""
  return [(market, str(o["subaccount_id"]), str(o.get("order_id", ""))) for o in (book.get("bids") or []) + (book.get("asks") or [])
          if o.get("side") == "buy" and o.get("status", "active") == "active"]


def gate_v1_bids(chain: Chain, v1d: dict, entries: list[dict], markets_url: str) -> Gate:
  bids = []
  for e in entries:
    if e.get("contract_type") != "spot":
      continue
    bids += resting_buys(e["market"], http_json(f"{markets_url.rstrip('/')}/v1/book?symbol={e['market']}"))
  makers = maker_accounts()
  managers = {acc: "0x" + chain.call(v1p.SUB_ACCOUNTS, selector("manager") + word_uint(int(acc)))[24:64]
              for acc in {*makers, *(b[1] for b in bids)}}
  return v1_bids_gate(bids, makers, managers, v1d["manager"])


def gate_close_only(chain: Chain, d: dict, v1d: dict, vault: str) -> list[Gate]:
  v1, v2 = word_address(v1d["manager"]), word_address(d["manager"])
  assets = v1_capped_assets(chain, v1d)
  not_owned = [a for a, _ in assets if chain.address(a, "owner").lower() != vault.lower()]
  gates = [Gate("custody", not not_owned, f"vault does not own {', '.join(not_owned)}" if not_owned
                else f"vault owns all {len(assets)} assets v1 holds caps on")]
  perp_cap = chain.word(v1d["perp"], selector("totalPositionCap") + v1)
  gates.append(Gate("perp", perp_cap == 0, f"v1's perp cap is {perp_cap}" + (", closed" if perp_cap == 0 else ": it should be 0 (#251)")))
  # EURC's escrow is wired for v2 at cap 0 until eurc-cap, which runs after this (v1's cap is then its open interest)
  missing = [what for i, (a, what) in enumerate(assets[:-1])
             if not (chain.word(a, selector("whitelistedManager") + v2) == 1
                     and (i == EURC_INDEX or chain.word(a, selector("totalPositionCap") + v2) > 0))]
  if chain.word(d["cash"], selector("whitelistedManager") + v2) != 1:
    missing.append("the cash")
  future_open = (chain.word(d["future"], selector("totalPositionCap") + v2) > 0
                 and chain.word(d["tradeModule"], selector("isDatedFutureAsset") + word_address(d["future"])) == 1)
  if not future_open:
    missing.append("v2's future (not enabled)")
  gates.append(Gate("v2", not missing, f"v2 does not yet take {', '.join(missing)}" if missing
                    else "v2 takes every escrow v1 lists (EURC's at eurc-cap) and the cash, and its future is open"))
  markets_url = os.environ.get("MARKETS_URL", "https://api.numofx.com")
  try:
    entries = markets(markets_url)
    gates.append(venue_gate(entries, v1d))
  except Exception as exc:  # noqa: BLE001
    entries = None
    gates.append(Gate("venue", False, f"markets-service /v1/markets unreadable: {str(exc)[:80]}"))
  try:
    gates.append(gate_v1_bids(chain, v1d, entries, markets_url) if entries is not None
                 else Gate("bids", False, "markets-service /v1/markets unreadable"))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("bids", False, f"spot books or their accounts unreadable: {str(exc)[:80]}"))
  gates.append(close_only_caps_gate([(what, chain.word(a, selector("totalPositionCap") + v1),
                                      chain.word(a, selector("totalPosition") + v1)) for a, what in assets]))
  return gates


def close_only_landed(chain: Chain, v1d: dict, asset: str) -> bool:
  """Close-only holds: no headroom over open interest under v1."""
  m = word_address(v1d["manager"])
  return chain.word(asset, selector("totalPositionCap") + m) <= chain.word(asset, selector("totalPosition") + m)


# ---------------------------------------------------------------------------------------------
# eurc-cap
# ---------------------------------------------------------------------------------------------

def eurc_cap_action(escrow: str, v2: str, cap18: int) -> dict:
  """eurcEscrow.setTotalPositionCap(v2, cap): EURC on v2, on top of whatever v1 still holds."""
  data = selector("setTotalPositionCap") + word_address(v2) + word_uint(cap18)
  return {"description": f"eurcEscrow.setTotalPositionCap(v2, {cap18}) [EURC-USDC on v2: {cap18 / 1e18:,.0f} EURC]",
          "to": escrow, "value": "0", "data": data, "digest": digest(escrow, data)}


def eurc_cap_bounds_gate(cap18: int, current18: int, oi18: int) -> Gate:
  if cap18 == current18:
    return Gate("cap", False, f"v2's EURC cap is already {cap18 / 1e18:,.0f}")
  if cap18 < oi18:
    return Gate("cap", False, f"{cap18 / 1e18:,.0f} is under v2's EURC open interest {oi18 / 1e18:,.4f}: that is close-only, not a cap")
  return Gate("cap", True, f"v2 {current18 / 1e18:,.0f} -> {cap18 / 1e18:,.0f} EURC (open interest {oi18 / 1e18:,.4f})")


def eurc_total_depth_gate(row: dict, v1_18: int, cap18: int) -> Gate:
  """The EURC enable's depth stress gate, at the venue's total: what v1 can hold plus v2's new cap."""
  g = eurc.depth_stress_gate(row, v1_18 + cap18)
  return Gate(g.name, g.ok, f"v1 {v1_18 / 1e18:,.0f} + v2 {cap18 / 1e18:,.0f} EURC; {g.detail}")


def eurc_inventory_gate(health: dict, v1: str, total18: int) -> Gate:
  """The engine keeper's MAX_EURC_INVENTORY was sized to the same depth: the venue's EURC may not exceed it. Unset is
  refused, as at the EURC enable."""
  raw = health.get("maxEurcInventory")
  inventory = int(raw) if raw not in (None, "") else None
  manager = str(health.get("manager") or "").lower()
  ok = manager == v1.lower() and inventory is not None and total18 <= inventory
  limit = "unset (no limit)" if inventory is None else f"{inventory / 1e18:,.0f} EURC"
  return Gate("keeper inventory", ok, f"engine keeper (manager {manager or '(unset)'}) MAX_EURC_INVENTORY {limit} "
                                      f"vs v1 + v2 {total18 / 1e18:,.0f} EURC")


def v1_eurc_capacity(chain: Chain, d: dict, escrow: str) -> int:
  """What v1 can hold on the EURC escrow: its cap, or its open interest where a close-only cap landed under it."""
  v1 = word_address(d["v1"])
  return max(chain.word(escrow, selector("totalPositionCap") + v1), chain.word(escrow, selector("totalPosition") + v1))


def gate_eurc_cap(chain: Chain, d: dict, vault: str, cap18: int) -> list[Gate]:
  escrow, v2 = d["escrows"][EURC_INDEX], word_address(d["manager"])
  token = chain.address(escrow, "wrappedAsset").lower()
  owner = chain.address(escrow, "owner").lower()
  wired = chain.word(escrow, selector("whitelistedManager") + v2) == 1
  problems = ([f"escrow wraps {token}, not EURC"] if token != eurc.EURC else []) + \
             ([f"vault does not own the EURC escrow (owner {owner})"] if owner != vault.lower() else []) + \
             ([] if wired else ["v2 is not whitelisted on it: setup has not landed"])
  v1_18 = v1_eurc_capacity(chain, d, escrow)
  gates = [Gate("custody", not problems, "; ".join(problems) or f"vault owns EURC escrow {escrow}; v2 is wired to it"),
           eurc_cap_bounds_gate(cap18, chain.word(escrow, selector("totalPositionCap") + v2),
                                chain.word(escrow, selector("totalPosition") + v2))]
  try:  # a fresh reading, as the EURC enable takes: the depth timer's 7 days have ended
    depth = eurc._depth()
    reader = depth.P.Rpc(chain.url)
    gates.append(eurc_total_depth_gate(depth.reading(reader, reader.head() - 2), v1_18, cap18))
  except Exception as exc:  # noqa: BLE001 -- unreadable holds, as at the EURC enable
    gates.append(Gate("depth stress", False, f"unreadable: {exc}"))
  try:
    health = http_json(os.environ.get("ENGINE_KEEPER_HEALTH_URL", "http://127.0.0.1:9465/health"))
    gates.append(eurc_inventory_gate(health, d["v1"], v1_18 + cap18))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("keeper inventory", False, f"engine keeper /health unreadable: {exc}"))
  return gates


# ---------------------------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------------------------

def self_test() -> int:
  from abi_selectors import assert_script
  assert_script(__file__)
  for name, want in PINNED.items():
    assert selector(name) == want, f"{name}: {selector(name)} != {want}"
  assert set(PINNED) == set(SIGNATURES), "every signature pinned"

  # A deployment with two markets (cNGN and EURC), its batches as the deploy script writes them, each way a file can be wrong.
  a = lambda n: "0x" + format(n, "040x")  # noqa: E731
  d = {"manager": a(1), "viewer": a(2), "future": a(3), "forwardFeed": a(4), "cash": a(5), "escrows": [a(6), a(7)],
       "escrowCaps": [100_000_000 * 10**18, 2_000_000 * 10**18], "auction": a(8), "tradeModule": a(9), "guardian": a(10),
       "futureOICap": str(30 * 10**18)}
  for batch in ("setup", "enable"):
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
  setup = expected_actions("setup", d)
  # vaultActionCount: four accepts, the cash, two per escrow, the auction, the guardian
  assert len(setup) == 4 + 1 + 2 * 2 + 2, len(setup)
  assert setup[5] == (a(6), selector("setWhitelistManager") + word_address(a(1)) + word_uint(1))
  assert setup[6] == (a(6), selector("setTotalPositionCap") + word_address(a(1)) + word_uint(100_000_000 * 10**18)), "cNGN at v1's cap"
  assert setup[8] == (a(7), selector("setTotalPositionCap") + word_address(a(1)) + word_uint(0)), "EURC at 0"
  # An artifact still carrying v1's EURC cap does not reopen it: setup's EURC cap is 0 whatever the file says.
  stale = [{"description": str(i), "to": to, "value": "0", "data": data, "digest": digest(to, data)}
           for i, (to, data) in enumerate(expected_actions("setup", d))]
  stale[8]["data"] = selector("setTotalPositionCap") + word_address(a(1)) + word_uint(2_000_000 * 10**18)
  stale[8]["digest"] = digest(a(7), stale[8]["data"])
  try:
    verify_actions("setup", d, stale)
  except SystemExit:
    pass
  else:
    raise AssertionError("setup at v1's EURC cap was accepted")
  assert setup[-1] == (a(1), selector("setGuardian") + word_address(a(10)))
  # A v2 deployed before v1 listed EURC-USDC has no EUR market: setup refuses it.
  assert markets_gate(d["escrows"], 2).ok
  assert not markets_gate([a(6)], 1).ok, "v2 without EUR"
  assert not markets_gate([a(6)], 2).ok, "v1 listed EUR after the deploy"
  enable = expected_actions("enable", d)
  assert enable == [(a(3), "0x40a557bd" + word_address(a(1)) + word_uint(30 * 10**18)),
                    (a(9), "0x0ddd8a04" + word_address(a(3)) + word_uint(1))], enable
  # No batch, and no close-only cap, ever opens the delisted perp.
  for to, data in setup + enable:
    assert not opens_a_perp_cap({"to": to, "data": data}), (to, data[:10])

  # Coverage: the whole 15% step on one side. 30 contracts at 0.000743 is a $11,145 side: $1,671.75. The live $3,250
  # covers up to 58 contracts (a $21,547 side, $3,232); 60 needs $3,343.50.
  assert abs(one_side_usd(30, 1_000_000, 0.000743) - 11_145) < 1e-6
  assert sm_gate(1_672, one_side_usd(30, 1_000_000, 0.000743)).ok and not sm_gate(1_671, one_side_usd(30, 1_000_000, 0.000743)).ok
  assert sm_gate(3_250, one_side_usd(58, 1_000_000, 0.000743)).ok and not sm_gate(3_250, one_side_usd(60, 1_000_000, 0.000743)).ok
  # One SecurityModule for every v2 series: with EURC-30NOV26 at 18 contracts ($1,503.63 at 1.1138), 30 cNGN still fits
  # ($1,671.75; $3,175.38 of $3,250) and 32 does not ($1,783.20).
  eurc_held = sm_required_usd_linear(one_side_usd(18, 1_000, 1.1138))
  assert abs(eurc_held - 1_503.63) < 0.01, eurc_held
  assert sm_gate(3_250, one_side_usd(30, 1_000_000, 0.000743), eurc_held, "EURC-30NOV26").ok
  assert not sm_gate(3_250, one_side_usd(32, 1_000_000, 0.000743), eurc_held, "EURC-30NOV26").ok
  assert "held for EURC-30NOV26" in sm_gate(3_250, one_side_usd(30, 1_000_000, 0.000743), eurc_held, "EURC-30NOV26").detail
  # The gap table, as docs/margin-engine-v2.md: $3,250 against $743 contracts at IM 25% covers 87 / 29 / 17.
  assert [c for _, c in gap_max_caps(3_250, 743, 0.25)] == [87, 29, 17], gap_max_caps(3_250, 743, 0.25)
  assert gaps_gate(3_250, 743, 0.25, 30).ok and "NOT covered at 40%, 50%" in gaps_gate(3_250, 743, 0.25, 30).detail
  assert "NOT" not in gaps_gate(3_250, 743, 0.25, 16).detail
  # The keeper's floor: a full side's IM, 25% of $11,145.
  assert abs(engine_keeper_min_cash(30, 1_000_000, 0.000743, 0.25) - 2_786.25) < 1e-6
  # The fill band as the chain reads it, not inverted: 0.000733418 USDC per cNGN, 10%.
  low, high = chain_fill_band(733418223364218, 10**17)
  assert abs(low - 0.000733418223364218 * 0.9) < 1e-15 and abs(high - 0.000733418223364218 * 1.1) < 1e-15, (low, high)
  listed = {"fill_band_enforced": True, "fill_band_low": str(low), "fill_band_high": str(high)}
  assert v1p.fills_gate(listed, low, high, unit="USDC per cNGN").ok
  assert not v1p.fills_gate({**listed, "fill_band_low": str(1 / high), "fill_band_high": str(1 / low)}, low, high).ok, \
    "an inverted (cNGN per USDC) band is refused"

  # v1 close-only: the cap is open interest exactly (18dp, not whole contracts), on v1, never a raise.
  v1 = "0xA19E296021c9DF25b90D96C2A0793CC3D0800758"
  act = close_only_action(a(3), v1, 22_696_000_000_000_000_000, "v1 future")
  assert act["data"] == "0x40a557bd" + word_address(v1) + word_uint(22_696_000_000_000_000_000) and act["digest"] == digest(a(3), act["data"])
  assert not opens_a_perp_cap({"to": perp_cap_guard.PERP_ASSET, "data": selector("setTotalPositionCap") + word_address(v1) + word_uint(0)})
  assert close_only_caps_gate([("escrow", 10**26, 396_131 * 10**18), ("future", 30 * 10**18, 22_696 * 10**15)]).ok
  assert close_only_caps_gate([("future", 22 * 10**18, 22 * 10**18)]).ok, "already at open interest"
  assert not close_only_caps_gate([("future", 22 * 10**18, 23 * 10**18)]).ok, "a raise is refused"
  # The venue: v1's future listed close-only, every other listing on v2.
  v1d = {"manager": v1, "future": a(3), "subId": 1796047200}
  fut = {"asset_address": a(3), "sub_id": "1796047200", "margin_manager_address": v1, "future": {"close_only": True}}
  spot = {"market": "cNGN-USDC", "asset_address": a(6), "sub_id": "0", "margin_manager_address": a(1)}
  assert venue_gate([fut, spot], v1d).ok
  assert not venue_gate([{**fut, "future": {}}, spot], v1d).ok, "not close-only"
  assert not venue_gate([spot], v1d).ok, "v1's future delisted: holders could not close"
  assert "cNGN-USDC" in venue_gate([fut, {**spot, "margin_manager_address": v1.lower()}], v1d).detail, "spot still on v1"
  # Bids: a v1 account's base buy would freeze under the new cap; a v2 account's would not; a v1 ask only reduces.
  mgrs = {"34": v1.lower(), "36": v1, "40": a(1), "41": a(1)}
  bid34 = ("cNGN-USDC", "34", "mm:cNGN-USDC:buy:1")
  assert not v1_bids_gate([bid34], [], mgrs, v1).ok and "#34 on cNGN-USDC (maker)" in v1_bids_gate([bid34], [], mgrs, v1).detail
  assert v1_bids_gate([("EURC-USDC", "40", "mm:EURC-USDC:buy:1")], ["40", "41"], mgrs, v1).ok, "the makers on v2"
  book = {"bids": [], "asks": [{"subaccount_id": "34", "side": "sell", "status": "active", "order_id": "mm:cNGN-USDC:sell:1"}]}
  assert resting_buys("cNGN-USDC", book) == [] and v1_bids_gate(resting_buys("cNGN-USDC", book), [], mgrs, v1).ok, "a v1 ask alone"
  book["bids"] = [{"subaccount_id": 34, "side": "buy", "status": "active", "order_id": "mm:cNGN-USDC:buy:1"}]
  assert resting_buys("cNGN-USDC", book) == [bid34]
  assert "#36" in v1_bids_gate([], ["36", "40"], mgrs, v1).detail and not v1_bids_gate([], ["36"], mgrs, v1).ok, \
    "a maker under v1 is refused while it rests nothing"

  # eurc-cap: the depth stress gate at v1 + N, not at N. At 86,202 EURC of depth without the largest LP the bar is
  # 43,101: with v1 at 40,000, v2 may take 3,000 and not 4,000; with v1 close-only at 5,000 open interest, 38,000.
  row = {"block": 1, "total_sell_eurc_ex_largest_lp": "86202", "main_pool_largest_lp_share": "0.5"}
  e18 = 10**18
  assert eurc_total_depth_gate(row, 40_000 * e18, 3_000 * e18).ok
  assert not eurc_total_depth_gate(row, 40_000 * e18, 4_000 * e18).ok, "v1's 40,000 + 4,000 is over the depth bar"
  assert eurc_total_depth_gate(row, 0, 43_000 * e18).ok and not eurc_total_depth_gate(row, 0, 44_000 * e18).ok
  assert eurc_total_depth_gate(row, 5_000 * e18, 38_000 * e18).ok and not eurc_total_depth_gate(row, 5_000 * e18, 39_000 * e18).ok
  assert not eurc_total_depth_gate({**row, "total_sell_eurc_ex_largest_lp": ""}, 0, e18).ok, "unknown depth holds"
  # The engine keeper's MAX_EURC_INVENTORY: v1's keeper, set, and at least the total.
  health = {"manager": v1.lower(), "maxEurcInventory": str(40_000 * e18)}
  assert eurc_inventory_gate(health, v1, 40_000 * e18).ok and not eurc_inventory_gate(health, v1, 40_001 * e18).ok
  assert not eurc_inventory_gate({**health, "maxEurcInventory": None}, v1, e18).ok, "unset is refused"
  assert not eurc_inventory_gate({**health, "manager": a(1)}, v1, e18).ok, "another manager's keeper"
  assert eurc_cap_bounds_gate(3_000 * e18, 0, 0).ok
  assert not eurc_cap_bounds_gate(0, 0, 0).ok and not eurc_cap_bounds_gate(e18, 0, 2 * e18).ok
  act = eurc_cap_action(a(7), a(1), 3_000 * e18)
  assert act["data"] == "0x40a557bd" + word_address(a(1)) + word_uint(3_000 * e18) and act["digest"] == digest(a(7), act["data"])

  # Every send goes through perp_cap_guard.
  import inspect
  for fn in (main, run_batch, run_close_only, run_cap, run_eurc_cap):
    assert "propose(token" not in inspect.getsource(fn), f"{fn.__name__} calls propose() directly"
  print("self-test ok: selectors compiled and pinned; a wrong target, calldata, value, digest, count or order is refused; "
        "coverage, gap, keeper and fill-band sized in USDC per cNGN; close-only caps at open interest, never a raise, "
        "and refused while a v1 account rests a spot bid; setup opens EURC at 0 and eurc-cap holds v1 + v2 to the depth bar")
  return 0


# ---------------------------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------------------------

def await_approval(token: str, vault_uuid: str, vault: str, action: dict, rpc_url: str, holds) -> None:
  uuid = perp_cap_guard.propose_checked(token, vault_uuid, vault, action, propose)
  print(f"  proposed uuid={uuid}\n       {action['description']}\n       digest {action['digest']}\n       -> approve in MPCVault now")
  deadline, tx_hash = time.time() + CONFIRM_TIMEOUT_SEC, None
  while time.time() < deadline and not tx_hash:
    time.sleep(CONFIRM_POLL_SEC)
    tx_hash = request_tx_hash(token, uuid)
  if not tx_hash:
    raise SystemExit("not approved within the timeout")
  confirm_on_chain(rpc_url, tx_hash)
  if not await_postcondition(holds):
    raise SystemExit("mined, but its postcondition does not read back after 60s: stop and investigate")


def credentials() -> tuple[str, str]:
  token, vault_uuid = os.environ.get("MPCVAULT_TOKEN", ""), os.environ.get("MPCVAULT_VAULT", "")
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh on the ops box)")
  return token, vault_uuid


def run_batch(args, d: dict, stack: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  actions = json.loads((args.dir / FILES[args.batch]).read_text())
  verify_actions(args.batch, d, actions)

  def gates() -> list[Gate]:
    if args.batch == "setup":
      return gate_setup(chain, d, vault)
    return gate_enable(chain, d, stack, vault, other_series_reserved(chain, args.dir))

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
    if args.batch == "setup":
      return parity_after_setup(chain, d, vault)
    return 0
  if not passed:
    print("\nGATES FAILED: nothing proposed.")
    return 1
  if not args.propose:
    print("\ndry run: nothing proposed. Re-run with --propose; compare each digest with MPCVault before approving.")
    return 0
  token, vault_uuid = credentials()
  first = done.index(False)
  for i, a in enumerate(actions):
    if holds[i]():
      print(f"  [{i}] already landed, skipped: {a['description']}")
      continue
    # Re-read before each: a feed, keeper or pager that died while an approval waited must stop the rest. Between the
    # two enable actions the cap is raised, so custody ("closed") is expected to fail there.
    if i > first:
      again = gates_after_mining(lambda: [g for g in gates() if not (args.batch == "enable" and g.name == "custody")])
      if not report(again):
        raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    await_approval(token, vault_uuid, vault, a, rpc_url, holds[i])
  print(f"\n{args.batch}: done." + (" v2's future is open: markets-service can list it." if args.batch == "enable" else ""))
  return parity_after_setup(chain, d, vault) if args.batch == "setup" else 0


def parity_after_setup(chain: Chain, d: dict, vault: str) -> int:
  """The vault owns everything now: re-read what the deployer could have changed while it did."""
  gates: list[Gate] = []
  await_postcondition(lambda: gates.append(gate_parity(chain, d, vault)) or gates[-1].ok)
  report(gates[-1:])
  if not gates[-1].ok:
    print("\nPARITY BROKEN after the setup batch: a setting differs from the deploy. Do not enable; investigate.")
    return 1
  return 0


def run_cap(args, d: dict, stack: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  if args.contracts is None:
    raise SystemExit("cap needs --contracts (both sides, whole contracts)")
  action = v1p.cap_action(d, args.contracts)
  gates = gate_cap(chain, d, stack, vault, args.contracts, other_series_reserved(chain, args.dir))
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
  m = word_address(d["manager"])
  await_approval(*credentials(), vault, action, rpc_url,
                 lambda: chain.word(d["future"], selector("totalPositionCap") + m) == args.contracts * 10**18)
  print(f"cap: v2's future cap reads {args.contracts} contracts")
  return 0


def run_eurc_cap(args, d: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  if args.eurc is None or args.eurc < 0:
    raise SystemExit("eurc-cap needs --eurc (v2's cap on the EURC escrow, whole EURC)")
  cap18, escrow = args.eurc * 10**18, d["escrows"][EURC_INDEX]
  action = eurc_cap_action(escrow, d["manager"], cap18)
  gates = gate_eurc_cap(chain, d, vault, cap18)
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
  m = word_address(d["manager"])
  await_approval(*credentials(), vault, action, rpc_url,
                 lambda: chain.word(escrow, selector("totalPositionCap") + m) == cap18)
  print(f"eurc-cap: v2's EURC cap reads {args.eurc:,} EURC")
  return 0


def run_close_only(args, d: dict, v1d: dict, chain: Chain, rpc_url: str, vault: str) -> int:
  gates = gate_close_only(chain, d, v1d, vault)
  passed = report(gates)
  actions = close_only_actions(chain, v1d)
  done = [close_only_landed(chain, v1d, a["to"]) for a in actions]
  print()
  for i, a in enumerate(actions):
    print(f"  {i}  {'landed ' if done[i] else 'pending'}  {a['to']}  {a['digest']}  {a['description']}")
  if args.json:
    print(json.dumps({"gates": [asdict(g) for g in gates], "landed": done}))
  if all(done):
    print("\nv1-close-only: every cap v1 holds is at or under its open interest; nothing to propose.")
    return 0
  if not passed:
    print("\nGATES FAILED: nothing proposed.")
    return 1
  if not args.propose:
    print("\ndry run: nothing proposed. Open interest moves: with --propose each cap is re-read and rebuilt just before it is"
          " proposed, so its digest can differ from this sheet's. Compare the one printed then with MPCVault.")
    return 0
  token, vault_uuid = credentials()
  for i in range(len(actions)):
    gates = gates_after_mining(lambda: gate_close_only(chain, d, v1d, vault))
    if not report(gates):
      raise SystemExit(f"a gate failed before action {i}: stop and investigate")
    a = close_only_actions(chain, v1d)[i]
    if close_only_landed(chain, v1d, a["to"]):
      print(f"  [{i}] already close-only, skipped: {a['to']}")
      continue
    await_approval(token, vault_uuid, vault, a, rpc_url, lambda a=a: close_only_landed(chain, v1d, a["to"]))
  m = word_address(v1d["manager"])
  for asset, what in v1_capped_assets(chain, v1d):
    cap, oi = chain.word(asset, selector("totalPositionCap") + m), chain.word(asset, selector("totalPosition") + m)
    print(f"  {what}: cap {cap / 1e18:,.4f}, open interest {oi / 1e18:,.4f}"
          + (" (under it: close-only, holders can still reduce and withdraw)" if cap < oi else ""))
  print("\nv1-close-only: done. Write it back today: OPS_BOX_CHANGES.md and the v1 docs.")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose MarginEngine v2's vault batches and v1's close-only")
  ap.add_argument("batch", nargs="?", choices=("setup", "enable", "cap", "v1-close-only", "eurc-cap"))
  ap.add_argument("--contracts", type=int, help="cap: the new total-position cap, both sides, in whole contracts")
  ap.add_argument("--eurc", type=int, help="eurc-cap: v2's cap on the EURC escrow, in whole EURC")
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
    ap.error("name a batch: setup, enable, cap, v1-close-only or eurc-cap")

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
    raise SystemExit(f"{artifact} does not exist: v2 is not deployed (deploy-margin-engine-v2.s.sol writes it)")
  d = json.loads(artifact.read_text())
  if d["v1"].lower() != json.loads((args.dir / f"{V1_NAME}.json").read_text())["manager"].lower():
    raise SystemExit("MARGIN_ENGINE_V2.json names a v1 that is not MARGIN_ENGINE.json's")
  chain = Chain(rpc_url)
  if args.batch == "eurc-cap":
    return run_eurc_cap(args, d, chain, rpc_url, vault)
  if args.batch == "v1-close-only":
    return run_close_only(args, d, json.loads((args.dir / f"{V1_NAME}.json").read_text()), chain, rpc_url, vault)
  stack = json.loads(args.stack.read_text())
  if args.batch == "cap":
    return run_cap(args, d, stack, chain, rpc_url, vault)
  return run_batch(args, d, stack, chain, rpc_url, vault)


if __name__ == "__main__":
  raise SystemExit(main())
