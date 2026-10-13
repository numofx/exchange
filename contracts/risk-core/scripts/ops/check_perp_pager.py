#!/usr/bin/env python3
"""Pages the operator's phone for the cNGN-PERP conditions that may need the guardian.

Run every minute (numo-perp-pager.timer). Each condition pages once when it starts, again every
REPAGE_SEC while it lasts, and sends a resolved notice when it clears. Every page is mirrored to the
Slack webhook, so the channel has the same record.

  feed-halt          the index, mark or an impact feed is past its warn age (index 960s of a 1200s
                     heartbeat): a stale index halts trading AND liquidations
  keeper-unhealthy   the keeper's /health is unreachable, in dry run, failing, or stale. Armed once
                     the keeper has reported healthy at least once, or the market is open (cap > 0):
                     before that, a keeper that is not running yet is not a page.
  sm-seed            the SecurityModule's cash is under the seed rule: a sixth of one side's notional
                     at the cap (totalPositionCap / 2 at the index). The next insolvency may socialize.
  oi-vs-keeper       one side's open interest, in USD at the index, is 3x or more the keeper's bid
                     account cash (KEEPER_ACCOUNT): the keeper could not margin the positions it may
                     have to take. Slack-only warning at 2x.
  low-gas-<name>     an EOA the venue burns gas from (executor, relayer, keeper) holds less than 2
                     days of its own measured burn, or less than its floor. A Slack-only warning goes
                     out under 7 days.
  sm-payout          the SecurityModule's cash fell since the last run: it paid for a liquidation
  insolvent-account  the keeper's last pass saw an account below zero (mark-to-market < 0)
  peg-guard          perp-feeds refused the index because cNGN left NGN parity by more than
                     PEG_GUARD_BPS (read from its status file, PERP_INDEX_STATUS_FILE)

The cNGN future on MarginEngine (FUTURE_ARTIFACT, default deployments/8453/MARGIN_ENGINE.json; skipped
while it does not exist) liquidates through the same auction and SecurityModule, so:
  sm-coverage        counts the future's one-side open interest beside the perp's, each at its own IM.
  future-pool-reserve  the future's VM pool holds less than a quarter of its reserve target (Slack
                     under half). The target is FUTURE_RESERVE_MOVE of one side's notional at the
                     position cap, in cNGN at the index; FUTURE_POOL_RESERVE_CNGN overrides it.
                     FUTURE_RESERVE_MOVE is 0 since 2026-10-13 (no reserve: winners are paid in USDC
                     once the pool holds no cNGN), so this is off unless the override sets one.
  future-escrow-cap  the cNGN escrow's cap for the future's manager has less headroom left than the
                     pool's reserve target: a full reserve top-up would no longer fit, and the
                     deposit would revert. Slack from 75% used. Raise the cap (vault) or ask traders
                     to margin in USDC.
  future-pool-borrowing  the pool's USDC cash is below -FUTURE_POOL_BORROW_PAGE_USD: winners were paid
                     in borrowed cash before losers paid in. Slack at any negative balance.
  future-pool-deficit-stuck  the pool's USDC cash has stayed below zero for FUTURE_POOL_DEFICIT_STUCK_SEC
                     (one hourly mark and its sweep, 75 min), at any size. With no reserve a deficit
                     between a winner and its loser settling is expected; one that outlasts the next
                     mark's sweep means a loser is not being settled.

Pager (one of; secrets from SSM via run-with-ssm-pager.sh):
  PAGER_PROVIDER=pushover     PUSHOVER_TOKEN, PUSHOVER_USER. Emergency priority: repeats every 60s
                              until acknowledged in the app, and can be set to break through Do Not
                              Disturb (Pushover "critical alerts" on iOS).
  PAGER_PROVIDER=pagerduty    PAGERDUTY_ROUTING_KEY (Events API v2): trigger and resolve with a
                              dedup key per condition, so PagerDuty's own escalation applies.

Other env: RPC_URL, KEEPER_HEALTH_URL, ALERT_WEBHOOK_URL (Slack mirror), PAGER_STATE_FILE
(default ~/.numo-perp-pager.json), PAGE_PREFIX (e.g. "[REHEARSAL] ", prepended to every page),
PAGER_HEARTBEAT_URL: the dead-man's switch, REQUIRED. A healthchecks.io-style check URL, pinged
after every run that completes and pages nothing that failed; its `/fail` endpoint
(PAGER_HEARTBEAT_FAIL_URL overrides it) is pinged when a run fails, so the switch fires at once
instead of after its grace period. If this script stops running at all -- the timer, the host,
the RPC -- the pings stop, and that service pages you. Without a heartbeat URL the pager pages you
about THAT, once a day. Each run's outcome is recorded in the state file (lastRunAt, lastRunOk),
which the enable gate reads (propose_perp_enable_batch.py, gate "pager"). PUSHOVER_URL / PAGERDUTY_URL override
the endpoints, for tests against a local capture server only.

  python3 scripts/ops/check_perp_pager.py                 one run
  python3 scripts/ops/check_perp_pager.py --self-test     offline: conditions, state, payloads
  python3 scripts/ops/check_perp_pager.py --test-page     sends one [TEST] page; a person must
                                                          confirm the phone received it
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_feed_staleness import SPOT_DETAIL_SLOT, load_env_file, rpc  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
STACK_ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_PERP_STACK.json"
SUB_ACCOUNTS = "0x7019244E25FA416e6Ca2ed2F3cA25277aef72843"

# Warn ages, seconds, against heartbeats of 1200 (index), 900 (mark) and 1200 (impacts). 16 minutes,
# not 15: a publish is due every 5, and two refused in a row (a Textile 502 run) reach exactly 15
# (replay of 2026-09-27..30), which is not yet a halt.
INDEX_HALT_SEC = 960
MARK_HALT_SEC = 600
IMPACT_HALT_SEC = 960
REPAGE_SEC = 1800
# perp-feeds writes its status every sample (a minute); older than this, it says nothing current.
INDEX_STATUS_MAX_AGE_SEC = 600
DEFAULT_INDEX_STATUS_FILE = "/home/ec2-user/exchange/services/perp-feeds/perp-index-status.json"
UNWATCHED_REPAGE_SEC = 86_400  # "no dead-man's switch" pages daily, not every half hour
SM_PAYOUT_MIN = 1.0  # USD: below this a fall is rounding, not a payout

SEL_SPOT_DIFF_DETAILS = "0xf8ff41bd"  # spotDiffDetails()
NEVER_PUBLISHED = -1  # a feed whose last-update timestamp is 0: not stale, never written
SEL_TOTAL_POSITION_CAP = "0x745ab570"  # totalPositionCap(address) -- `cast sig`, pinned in --self-test
SEL_TOTAL_POSITION = "0xa9578774"  # totalPosition(address): |position| summed over BOTH sides
SEL_GET_SPOT = "0x2b37269c"  # getSpot() on the index feed: USDC per cNGN, 18dp
# One side's OI notional against the keeper's cash. The keeper must hold maintenance margin (20%)
# for what it inherits in an auction and may carry several accounts at once, so 3x is where a full
# side could no longer be taken in one go; 2x is the warning to top up (runbook: keeper collateral).
# SecurityModule coverage, leverage-aware (cngn-perp-leverage-batch.sol, CngnPerpLeverageBatchFork):
# the module's payout when one whole side is liquidated at maintenance margin after a 25% step is
# one-side notional x 25% x (1 - IM), within 0.2% of the fork's measured payouts (a sixth of a side at
# 3x, a fifth at 5x). Read against ACTUAL one-side open interest, not the cap: Slack once open
# interest passes what the module covers at the current IM, page at 1.2x of it.
SM_STEP = 0.25
SM_COVERAGE_PAGE_X = 1.2
SM_COVERAGE_WARN_REPEAT_SEC = 6 * 3600
SEL_PERP_MARGIN_REQUIREMENTS = "0xbf270f9d"  # perpMarginRequirements(uint256) -> (mm, im) -- `cast sig`, pinned in --self-test
OI_KEEPER_WARN_X = 2.0
OI_KEEPER_PAGE_X = 3.0
OI_WARN_REPEAT_SEC = 6 * 3600
# Gas watch. Burn is measured as the balance 24h ago minus now (a top-up in between reads as no
# burn, which then falls back to the floor). Floors are two days at the worst case measured in the
# runbook: relayer 0.0013/day (a mark a minute), executor ~0.00001 per settlement, keeper ~100 full
# liquidation cycles (3M gas ≈ 0.00002 ETH each). `GAS_WATCH` overrides: "name=0xaddr:floorEth,...". `KEEPER_EOA` adds the keeper.
BLOCKS_PER_DAY = 43_200  # Base, 2s blocks
GAS_PAGE_DAYS = 2.0
GAS_WARN_DAYS = 7.0
GAS_WARN_REPEAT_SEC = 6 * 3600
DEFAULT_GAS_WATCH = "executor=0xF68ebcC8934B068655E1A4367Ba6C0e564678703:0.002,relayer=0xC9F1FfdEd29f7051538ad3a72729C3d07F920FDc:0.003"
KEEPER_GAS_FLOOR_ETH = 0.002  # ~100 liquidation cycles at 3M gas and Base gas prices; the keeper idles at ~0 burn
# The matcher: a dead one is a venue nobody can close on. It heartbeats service_heartbeats every 5s
# and markets-service serves that on GET /v1/health (MATCHER_HEALTH_URL); older than MATCHER_DEAD_SEC
# pages. Its position indexer (reduce-only ledger) reports the block it has applied up to; more than
# MATCHER_INDEXER_LAG_SEC of Base blocks (2s) behind the pager's own head pages too: the match-time
# chain read still guards every reduce-only fill, but the ledger the venue trusts is no longer current.
DEFAULT_MATCHER_HEALTH_URL = "https://api.numofx.com/v1/health"
MATCHER_DEAD_SEC = 60
MATCHER_INDEXER_LAG_SEC = 120
BLOCK_SEC = 2
SEL_GET_BALANCE = "0x0806e640"  # getBalance(uint256,address,uint256) -- `cast sig`, pinned in --self-test
# Negative cash across the perp: CashAsset.totalBorrow(), the sum of every account's cash below zero
# (losses not yet repaid, fees of cNGN-margined accounts, and USDC withdrawn against cNGN on chain).
# The venue does not pay out borrowed cash through its own withdrawals, so growth here is either
# losses sitting unpaid or a borrower going around the venue. Slack from $1,500, page at 2x.
SEL_TOTAL_BORROW = "0x8285ef40"  # totalBorrow()
NEGATIVE_CASH_WARN_USD = 1_500.0
NEGATIVE_CASH_PAGE_USD = 3_000.0
NEGATIVE_CASH_WARN_REPEAT_SEC = 6 * 3600
# The cNGN future. Its artifact exists only once it is deployed; until then none of this is read.
FUTURE_ARTIFACT = ROOT / "deployments" / "8453" / "MARGIN_ENGINE.json"
SEL_CONTRACT_SIZE = "0x3d7cc610"  # contractSize() -- `cast sig`, pinned in --self-test
SEL_FUTURE_MARGIN_REQUIREMENTS = "0x84033e5e"  # futureMarginRequirements(uint256) -> (mmReq, imReq) on MarginEngine
# The pool's cNGN reserve, as a fraction of one side's notional at the cap. 0 since 2026-10-13 (decided):
# launch traders margin in USDC, so a seed would drain to winners and be refilled in USDC within a few
# marks, and the reserve changes neither settlement (which never reverts) nor anyone's margin. Without it
# a winner settling before its loser is paid in borrowed cash for that window; future-pool-borrowing and
# future-pool-deficit-stuck watch that instead. The earlier sizing, for raising it again: 0.30 (a full side
# paying in USDC through a 25% move, plus one 5% mark a winner can draw between sweeps).
FUTURE_RESERVE_MOVE = 0.0
FUTURE_RESERVE_PAGE_FRACTION = 0.25
FUTURE_RESERVE_WARN_FRACTION = 0.5
FUTURE_POOL_BORROW_PAGE_USD = 250.0
FUTURE_POOL_DEFICIT_STUCK_SEC = 75 * 60
FUTURE_ESCROW_WARN_USED = 0.75
FUTURE_WARN_REPEAT_SEC = 6 * 3600


@dataclass(frozen=True)
class Condition:
  key: str
  message: str


def head_timestamp(url: str) -> int:
  return head_block(url)[1]


def head_block(url: str) -> tuple[int, int]:
  block = rpc(url, "eth_getBlockByNumber", ["latest", False])
  return int(block["number"], 16), int(block["timestamp"], 16)


def index_age(url: str, feed: str, now: int) -> int:
  word = int(rpc(url, "eth_getStorageAt", [feed, SPOT_DETAIL_SLOT, "latest"]), 16)
  ts = (word >> 160) & 0xFFFFFFFFFFFFFFFF
  return now - ts if ts else NEVER_PUBLISHED


def diff_age(url: str, feed: str, now: int) -> int:
  raw = rpc(url, "eth_call", [{"to": feed, "data": SEL_SPOT_DIFF_DETAILS}, "latest"])[2:]
  ts = int(raw[128:192], 16)
  return now - ts if ts else NEVER_PUBLISHED


def feed_condition(ages: dict[str, int | None]) -> Condition | None:
  """ages: feed name -> seconds since its last update, None when unreadable."""
  limits = {"index": INDEX_HALT_SEC, "mark": MARK_HALT_SEC, "impact ask": IMPACT_HALT_SEC, "impact bid": IMPACT_HALT_SEC}
  late = [f"{name} {'unreadable' if age is None else 'never published' if age == NEVER_PUBLISHED else f'{age}s old'}"
          for name, age in ages.items() if age is None or age == NEVER_PUBLISHED or age > limits[name]]
  if not late:
    return None
  return Condition("feed-halt", f"cNGN-PERP feed halt: {', '.join(late)}. A stale index halts trading and liquidations.")


def keeper_condition(health: dict | None, now: int, armed: bool = True) -> Condition | None:
  """`armed` is False until the keeper has ever reported healthy and the market is still closed:
  a keeper that is not installed yet, or running its DRY_RUN smoke (go-live steps 14-17), is not
  a page. Once the market is open, no keeper at all is the loudest condition there is."""
  if not armed:
    return None
  if health is None:
    return Condition("keeper-unhealthy", "cNGN-PERP keeper /health unreachable: nothing is liquidating.")
  if health.get("dryRun", True):
    return Condition("keeper-unhealthy", "cNGN-PERP keeper is in DRY_RUN: it decides but sends nothing.")
  stale_after = 3 * max(int(health.get("pollIntervalMs", 15_000)) // 1000, 20)
  age = now - int(health.get("lastPassAt", 0))
  if not health.get("lastPassOk") or age > stale_after:
    return Condition("keeper-unhealthy", f"cNGN-PERP keeper unhealthy: last pass ok={health.get('lastPassOk')} {age}s ago.")
  return None


def matcher_conditions(health: dict | None, head_block: int) -> list[Condition]:
  """Pages for a matcher that stopped heartbeating, and for a position indexer that fell behind."""
  if health is None:
    return [Condition("matcher-dead", "cNGN matcher health unreadable (markets-service /v1/health down or unreachable): "
                      "if the matcher is down, nobody can close.")]
  matcher = health.get("matcher")
  if not matcher:
    return [Condition("matcher-dead", "cNGN matcher has never written a heartbeat: nothing is matching, nobody can close.")]
  out: list[Condition] = []
  age = float(matcher.get("age_seconds", 1e9))
  if age > MATCHER_DEAD_SEC:
    out.append(Condition("matcher-dead", f"cNGN matcher last heartbeat {age:.0f}s ago: nothing is matching, nobody can close."))
  indexer = (matcher.get("details") or {}).get("indexer")
  if indexer and head_block:
    cursor = int(indexer.get("cursor_block", 0))
    lag_sec = max(0, head_block - cursor) * BLOCK_SEC
    if lag_sec > MATCHER_INDEXER_LAG_SEC:
      out.append(Condition("matcher-indexer-lag", f"perp position indexer is {head_block - cursor} blocks (~{lag_sec}s) behind head"
                           f"{' (' + indexer['last_error'][:80] + ')' if indexer.get('last_error') else ''}: the reduce-only ledger "
                           "is stale; the chain read still guards each fill."))
  return out


def keeper_healthy(health: dict | None, now: int) -> bool:
  return health is not None and keeper_condition(health, now, armed=True) is None


def gas_watch() -> list[tuple[str, str, float]]:
  """(name, address, floor ETH) from GAS_WATCH, plus the keeper EOA when KEEPER_EOA is set."""
  out = []
  for item in os.environ.get("GAS_WATCH", DEFAULT_GAS_WATCH).split(","):
    if not item.strip():
      continue
    name, rest = item.split("=", 1)
    address, floor = rest.split(":", 1)
    out.append((name.strip(), address.strip(), float(floor)))
  keeper = os.environ.get("KEEPER_EOA", "").strip()
  if keeper:
    out.append(("keeper", keeper, float(os.environ.get("KEEPER_GAS_FLOOR_ETH", KEEPER_GAS_FLOOR_ETH))))
  return out


def gas_condition(name: str, balance: float, burn_per_day: float, floor: float) -> Condition | None:
  """Page under 2 days of measured burn, or under the floor when the burn is unmeasurable (0)."""
  need = max(GAS_PAGE_DAYS * burn_per_day, floor)
  if balance >= need:
    return None
  runway = f"{balance / burn_per_day:.1f} days" if burn_per_day > 0 else "unknown burn"
  return Condition(f"low-gas-{name}", f"cNGN-PERP {name} low on gas: {balance:.5f} ETH, burning {burn_per_day:.5f}/day "
                   f"({runway}); needs {need:.5f}. Top it up before it stops {'settling' if name == 'executor' else 'publishing' if name == 'relayer' else 'liquidating'}.")


def gas_warning(name: str, balance: float, burn_per_day: float) -> str | None:
  """Slack-only, under 7 days of measured burn."""
  if burn_per_day <= 0 or balance / burn_per_day >= GAS_WARN_DAYS:
    return None
  return f"cNGN-PERP {name} gas runway {balance / burn_per_day:.1f} days ({balance:.5f} ETH at {burn_per_day:.5f}/day): top up this week."


def sm_covered_one_side_usd(sm_cash_usd: float, im: float) -> float:
  """One-side notional the SecurityModule covers through a 25% step at initial margin `im` (a fraction)."""
  if not 0 < im < 1:
    return 0.0
  return sm_cash_usd / (SM_STEP * (1 - im))


def sm_required_usd(books: list[tuple[float, float]]) -> float:
  """What the SecurityModule pays if one whole side of every book is liquidated after a 25% step:
  sum of one-side notional x 25% x (1 - IM), over (one-side USD, IM) pairs. The perp's term is the
  fork-measured one; the future's uses the same formula (same auction, margin as a fraction of
  notional) and has not been measured on a fork."""
  return sum(one_side * SM_STEP * (1 - im) for one_side, im in books if 0 < im < 1)


def sm_combined_condition(books: dict[str, tuple[float, float]], sm_cash_usd: float) -> Condition | None:
  """sm-coverage across the perp and the future together: pages at 1.2x of what the module holds."""
  required = sm_required_usd(list(books.values()))
  if required <= 0 or required < SM_COVERAGE_PAGE_X * sm_cash_usd:
    return None
  parts = ", ".join(f"{name} one side ${one_side:,.0f} at IM {im * 100:.0f}%" for name, (one_side, im) in books.items())
  return Condition("sm-coverage", f"cNGN SecurityModule ${sm_cash_usd:,.0f} covers less than 1/{SM_COVERAGE_PAGE_X:.1f} of a 25% step "
                   f"across {parts} (needs ${required:,.0f}). Fund the SecurityModule, or set cap = current OI.")


def sm_combined_warning(books: dict[str, tuple[float, float]], sm_cash_usd: float) -> str | None:
  required = sm_required_usd(list(books.values()))
  if required <= sm_cash_usd or required >= SM_COVERAGE_PAGE_X * sm_cash_usd:
    return None
  return (f"cNGN SecurityModule ${sm_cash_usd:,.0f} is short of the ${required:,.0f} a 25% step across the perp and the future "
          f"would cost (page at {SM_COVERAGE_PAGE_X:.1f}x): fund it.")


def future_pool_conditions(pool_cngn: float, pool_cash_usd: float, reserve_cngn: float | None,
                           open_: bool, negative_for_sec: float = 0) -> tuple[list[Condition], list[str]]:
  """(pages, Slack warnings) for the future's VM pool. Nothing before the market opens. reserve_cngn None
  is an unreadable target; 0 is no reserve (FUTURE_RESERVE_MOVE 0). negative_for_sec: how long the pool's
  cash has been below zero without a break."""
  if not open_:
    return [], []
  pages: list[Condition] = []
  warnings: list[str] = []
  if reserve_cngn is None:
    warnings.append("cNGN future is open but its VM pool reserve target is unreadable (index?): the reserve is not watched.")
  elif reserve_cngn > 0:
    held = pool_cngn / reserve_cngn
    if held < FUTURE_RESERVE_PAGE_FRACTION:
      pages.append(Condition("future-pool-reserve", f"cNGN future VM pool holds {pool_cngn:,.0f} cNGN, {held * 100:.0f}% of its "
                             f"{reserve_cngn:,.0f} reserve: winners are being paid in USDC, not cNGN. Top it up from the pool's USDC."))
    elif held < FUTURE_RESERVE_WARN_FRACTION:
      warnings.append(f"cNGN future VM pool at {held * 100:.0f}% of its {reserve_cngn:,.0f} cNGN reserve: top it up this week.")
  if pool_cash_usd < -FUTURE_POOL_BORROW_PAGE_USD:
    pages.append(Condition("future-pool-borrowing", f"cNGN future VM pool is ${-pool_cash_usd:,.0f} below zero in USDC cash: winners were "
                           "paid in borrowed cash before losers paid in. Check the keeper's VM sweep, and top the pool up."))
  elif pool_cash_usd < 0:
    warnings.append(f"cNGN future VM pool is ${-pool_cash_usd:,.2f} below zero in USDC cash (page past ${FUTURE_POOL_BORROW_PAGE_USD:,.0f}).")
  if pool_cash_usd < 0 and negative_for_sec >= FUTURE_POOL_DEFICIT_STUCK_SEC:
    pages.append(Condition("future-pool-deficit-stuck", f"cNGN future VM pool has been ${-pool_cash_usd:,.2f} below zero in USDC cash for "
                           f"{negative_for_sec / 60:,.0f} min, past a mark and its sweep: a loser is not being settled. Check "
                           "numo-future-feeds' sweep and settle the payers (settleAccount)."))
  return pages, warnings


def pool_negative_for(state: dict, open_: bool, pool_cash_usd: float, now: float) -> float:
  """Seconds the future pool's cash has been below zero without a break, kept across runs in `state`
  (futurePoolNegativeSince): any run that reads it at or above zero, or the market closed, restarts it."""
  if open_ and pool_cash_usd < 0:
    return now - state.setdefault("futurePoolNegativeSince", now)
  state.pop("futurePoolNegativeSince", None)
  return 0.0


def future_escrow_conditions(used_cngn: float, cap_cngn: float, reserve_cngn: float | None,
                             open_: bool) -> tuple[list[Condition], list[str]]:
  """(pages, Slack warnings) for the cNGN escrow cap under the future's manager, which holds both the
  pool's reserve and traders' cNGN collateral. Nothing before the market opens."""
  if not open_ or cap_cngn <= 0:
    return [], []
  headroom = cap_cngn - used_cngn
  used = used_cngn / cap_cngn
  if reserve_cngn and headroom < reserve_cngn:
    return [Condition("future-escrow-cap", f"cNGN escrow cap for the future is {used * 100:.0f}% used ({used_cngn:,.0f} of {cap_cngn:,.0f}): "
                      f"{max(headroom, 0):,.0f} left, less than the {reserve_cngn:,.0f} pool reserve, so a reserve top-up would revert. "
                      "Raise the cap (vault), or ask traders to margin in USDC.")], []
  if used >= FUTURE_ESCROW_WARN_USED:
    return [], [f"cNGN escrow cap for the future is {used * 100:.0f}% used ({used_cngn:,.0f} of {cap_cngn:,.0f}): raise it before "
                f"headroom falls under the pool reserve."]
  return [], []


def future_reserve_target_cngn(cap_contracts: float, contract_size_usd: float, usdc_per_cngn: float) -> float | None:
  """The pool's cNGN reserve target: FUTURE_RESERVE_MOVE of one side's notional at the cap (the cap
  counts both sides), in cNGN at the index. None with no index; 0 with no reserve."""
  if usdc_per_cngn <= 0:
    return None
  return cap_contracts / 2 * contract_size_usd * FUTURE_RESERVE_MOVE / usdc_per_cngn


def account_balance(url: str, account: int, asset: str) -> int:
  raw = rpc(url, "eth_call", [{"to": SUB_ACCOUNTS, "data": SEL_GET_BALANCE + f"{account:064x}"
                               + asset.lower().removeprefix("0x").rjust(64, "0") + "0" * 64}, "latest"])
  value = int(raw, 16)
  return value - 2**256 if value >= 2**255 else value


def read_future(url: str, future: dict) -> dict:
  """The future's book, its IM, whether it is open, and its pool's balances."""
  manager_word = future["manager"].lower().removeprefix("0x").rjust(64, "0")
  call = lambda to, data: rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])[2:]  # noqa: E731
  total = int(call(future["future"], SEL_TOTAL_POSITION + manager_word), 16)
  size = int(call(future["future"], SEL_CONTRACT_SIZE), 16)
  cap = int(call(future["future"], SEL_TOTAL_POSITION_CAP + manager_word), 16)
  im = int(call(future["manager"], SEL_FUTURE_MARGIN_REQUIREMENTS + f"{int(future['marketId']):064x}")[64:128], 16) / 1e18
  spot = int(call(future["indexFeed"], SEL_GET_SPOT)[:64], 16) / 1e18
  escrow_used = int(call(future["cngnEscrow"], SEL_TOTAL_POSITION + manager_word), 16) / 1e18
  escrow_cap = int(call(future["cngnEscrow"], SEL_TOTAL_POSITION_CAP + manager_word), 16) / 1e18
  pool = int(future["poolAccount"])
  return {
    "one_side_usd": (total / 2) / 1e18 * (size / 1e18),
    "im": im,
    "open": cap > 0,
    "reserve_target_cngn": future_reserve_target_cngn(cap / 1e18, size / 1e18, spot),
    "escrow_used_cngn": escrow_used,
    "escrow_cap_cngn": escrow_cap,
    "pool_cngn": account_balance(url, pool, future["cngnEscrow"]) / 1e18,
    "pool_cash_usd": account_balance(url, pool, future["cash"]) / 1e18,
  }


def future_artifact() -> dict | None:
  path = Path(os.environ.get("FUTURE_ARTIFACT", FUTURE_ARTIFACT))
  return json.loads(path.read_text()) if path.exists() else None


def sm_coverage_condition(one_side_usd: float, covered_usd: float, im: float) -> Condition | None:
  if one_side_usd <= 0 or (covered_usd > 0 and one_side_usd < SM_COVERAGE_PAGE_X * covered_usd):
    return None
  return Condition("sm-coverage", f"cNGN-PERP one-side OI ${one_side_usd:,.0f} is past {SM_COVERAGE_PAGE_X:.1f}x what the SecurityModule "
                   f"covers (${covered_usd:,.0f} at IM {im * 100:.0f}%: a 25% step on that side would cost it more than it holds). "
                   "Fund the SecurityModule, or set cap = current OI.")


def sm_coverage_warning(one_side_usd: float, covered_usd: float, im: float) -> str | None:
  """Slack-only, from coverage up to the page."""
  if covered_usd <= 0 or one_side_usd <= covered_usd or one_side_usd >= SM_COVERAGE_PAGE_X * covered_usd:
    return None
  return (f"cNGN-PERP one-side OI ${one_side_usd:,.0f} exceeds the ${covered_usd:,.0f} the SecurityModule covers at IM {im * 100:.0f}% "
          f"(page at {SM_COVERAGE_PAGE_X:.1f}x): fund it before the next step costs more than it holds.")


def perp_manager(stack: dict) -> str:
  """The manager the perp's open interest and margin are read under: the live SRM until the MarginEngine cutover, then
  PERP_MANAGER set to the engine (one setting, changed on the cutover day)."""
  return os.environ.get("PERP_MANAGER", "").strip() or stack["srm"]


def read_perp_im(url: str, stack: dict) -> float:
  """The perp's initial margin requirement on the SRM, as a fraction."""
  market_word = f"{int(stack['marketId']):064x}"
  raw = rpc(url, "eth_call", [{"to": perp_manager(stack), "data": SEL_PERP_MARGIN_REQUIREMENTS + market_word}, "latest"])[2:]
  return int(raw[64:128], 16) / 1e18


def read_one_side_usd(url: str, stack: dict) -> float:
  """One side's open interest in USD at the index: totalPosition(srm) / 2 x getSpot()."""
  srm_word = perp_manager(stack).lower().removeprefix("0x").rjust(64, "0")
  total = int(rpc(url, "eth_call", [{"to": stack["perp"], "data": SEL_TOTAL_POSITION + srm_word}, "latest"]), 16)
  spot = int(rpc(url, "eth_call", [{"to": stack["indexFeed"], "data": SEL_GET_SPOT}, "latest"])[2:66], 16)
  return (total / 2) / 1e18 * (spot / 1e18)


def oi_condition(one_side_usd: float, keeper_cash_usd: float) -> Condition | None:
  if keeper_cash_usd <= 0:
    return Condition("oi-vs-keeper", f"cNGN-PERP keeper bid account holds no cash while one side's OI is ${one_side_usd:,.0f}: nothing can take a liquidation.")
  ratio = one_side_usd / keeper_cash_usd
  if ratio < OI_KEEPER_PAGE_X:
    return None
  return Condition("oi-vs-keeper", f"cNGN-PERP one-side OI ${one_side_usd:,.0f} is {ratio:.1f}x the keeper's ${keeper_cash_usd:,.0f} cash "
                   f"(page at {OI_KEEPER_PAGE_X:.0f}x): top the keeper account up, or set cap = current OI.")


def negative_cash_condition(total_borrow_usd: float) -> Condition | None:
  if total_borrow_usd < NEGATIVE_CASH_PAGE_USD:
    return None
  return Condition("negative-cash", f"cNGN-PERP accounts owe ${total_borrow_usd:,.0f} of negative cash (page at "
                   f"${NEGATIVE_CASH_PAGE_USD:,.0f}): unpaid losses, or USDC borrowed against cNGN around the venue. "
                   "Liquidate or lower the cNGN collateral cap.")


def negative_cash_warning(total_borrow_usd: float) -> str | None:
  if total_borrow_usd < NEGATIVE_CASH_WARN_USD or total_borrow_usd >= NEGATIVE_CASH_PAGE_USD:
    return None
  return f"cNGN-PERP accounts owe ${total_borrow_usd:,.0f} of negative cash (warn at ${NEGATIVE_CASH_WARN_USD:,.0f}, page at ${NEGATIVE_CASH_PAGE_USD:,.0f})."


def read_total_borrow(url: str, stack: dict) -> float:
  raw = rpc(url, "eth_call", [{"to": stack["cash"], "data": SEL_TOTAL_BORROW}, "latest"])
  return int(raw, 16) / 1e18


def oi_warning(one_side_usd: float, keeper_cash_usd: float) -> str | None:
  """Slack-only, from 2x up to the page."""
  if keeper_cash_usd <= 0 or one_side_usd / keeper_cash_usd < OI_KEEPER_WARN_X or one_side_usd / keeper_cash_usd >= OI_KEEPER_PAGE_X:
    return None
  return f"cNGN-PERP one-side OI ${one_side_usd:,.0f} is {one_side_usd / keeper_cash_usd:.1f}x the keeper's ${keeper_cash_usd:,.0f} cash: top it up before 3x pages."


def read_oi_and_keeper(url: str, stack: dict, keeper_account: int) -> tuple[float, float]:
  """(one side's OI in USD at the index, keeper account cash in USD)."""
  srm_word = perp_manager(stack).lower().removeprefix("0x").rjust(64, "0")
  total = int(rpc(url, "eth_call", [{"to": stack["perp"], "data": SEL_TOTAL_POSITION + srm_word}, "latest"]), 16)
  spot = int(rpc(url, "eth_call", [{"to": stack["indexFeed"], "data": SEL_GET_SPOT}, "latest"])[2:66], 16)
  one_side_usd = (total / 2) / 1e18 * (spot / 1e18)
  raw = rpc(url, "eth_call", [{"to": SUB_ACCOUNTS, "data": SEL_GET_BALANCE + f"{keeper_account:064x}"
                               + stack["cash"].lower().removeprefix("0x").rjust(64, "0") + "0" * 64}, "latest"])
  cash = int(raw, 16)
  cash = cash - 2**256 if cash >= 2**255 else cash
  return one_side_usd, cash / 1e18


def read_gas(url: str, head_block: int, address: str) -> tuple[float, float]:
  """(balance ETH, burn ETH/day) from the balance now and ~24h of blocks ago."""
  now_wei = int(rpc(url, "eth_getBalance", [address, "latest"]), 16)
  then_wei = int(rpc(url, "eth_getBalance", [address, hex(max(head_block - BLOCKS_PER_DAY, 0))]), 16)
  return now_wei / 1e18, max(then_wei - now_wei, 0) / 1e18


def market_open(url: str, stack: dict) -> bool:
  raw = rpc(url, "eth_call", [{"to": stack["perp"], "data": SEL_TOTAL_POSITION_CAP + perp_manager(stack).lower().removeprefix("0x").rjust(64, "0")}, "latest"])
  return int(raw, 16) > 0


def insolvent_condition(health: dict | None) -> Condition | None:
  accounts = (health or {}).get("insolventAccounts") or []
  if not accounts:
    return None
  return Condition("insolvent-account", f"cNGN-PERP insolvent account(s) {', '.join(accounts)}: the SecurityModule will pay.")


def peg_condition(status: dict | None, now_wall: float) -> Condition | None:
  """A tripped peg guard in perp-feeds' last sample. A missing or stale status says nothing: a dead
  publisher is the feed-halt page's job."""
  if not status or now_wall - float(status.get("at", 0)) / 1000 > INDEX_STATUS_MAX_AGE_SEC:
    return None
  if not status.get("pegGuardTripped"):
    return None
  peg = status.get("peg") or {}
  return Condition("peg-guard", f"cNGN-PERP index HALTED by the peg guard: cNGN at {peg.get('ngnPerCngn')} NGN, "
                   f"{float(peg.get('deviationBps', 0)):.0f}bps from parity. The index will not update until it returns.")


def read_index_status() -> dict | None:
  path = Path(os.environ.get("PERP_INDEX_STATUS_FILE", DEFAULT_INDEX_STATUS_FILE))
  try:
    return json.loads(path.read_text())
  except Exception:  # noqa: BLE001
    return None


def sm_condition(previous: float | None, current: float) -> Condition | None:
  if previous is None or previous - current < SM_PAYOUT_MIN:
    return None
  return Condition("sm-payout", f"cNGN-PERP SecurityModule paid ${previous - current:,.2f} (now ${current:,.2f}).")


def step_state(state: dict, active: list[Condition], now: int) -> tuple[list[Condition], list[str]]:
  """Which conditions to page (new, or due a repage) and which keys resolved. Mutates state."""
  seen = state.setdefault("active", {})
  to_page = []
  for condition in active:
    entry = seen.get(condition.key)
    repage = UNWATCHED_REPAGE_SEC if condition.key == "pager-unwatched" else REPAGE_SEC
    if entry is None or now - entry["lastPagedAt"] >= repage:
      to_page.append(condition)
      seen[condition.key] = {"since": entry["since"] if entry else now, "lastPagedAt": now}
  keys = {c.key for c in active}
  resolved = [key for key in list(seen) if key not in keys]
  for key in resolved:
    del seen[key]
  # sm-payout is an event, not a state: once paged it is done, and the baseline has moved.
  seen.pop("sm-payout", None)
  return to_page, resolved


def pushover_payload(token: str, user: str, title: str, message: str, emergency: bool) -> dict:
  payload = {"token": token, "user": user, "title": title, "message": message}
  if emergency:
    payload.update({"priority": "2", "retry": "60", "expire": "3600"})
  return payload


def pagerduty_payload(routing_key: str, key: str, message: str, resolve: bool) -> dict:
  body = {"routing_key": routing_key, "event_action": "resolve" if resolve else "trigger", "dedup_key": f"numo-perp-{key}"}
  if not resolve:
    body["payload"] = {"summary": message[:1000], "source": "numo-perp-pager", "severity": "critical"}
  return body


def send_page(key: str, message: str, resolve: bool = False) -> None:
  prefix = os.environ.get("PAGE_PREFIX", "")
  text = f"{prefix}{'RESOLVED: ' if resolve else ''}{message}"
  provider = os.environ.get("PAGER_PROVIDER", "")
  if provider == "pushover":
    data = urllib.parse.urlencode(pushover_payload(
      os.environ["PUSHOVER_TOKEN"], os.environ["PUSHOVER_USER"], f"{prefix}numo perp", text, emergency=not resolve)).encode()
    urllib.request.urlopen(urllib.request.Request(os.environ.get("PUSHOVER_URL", "https://api.pushover.net/1/messages.json"), data=data), timeout=15).read()
  elif provider == "pagerduty":
    body = json.dumps(pagerduty_payload(os.environ["PAGERDUTY_ROUTING_KEY"], key, text, resolve)).encode()
    urllib.request.urlopen(urllib.request.Request(
      os.environ.get("PAGERDUTY_URL", "https://events.pagerduty.com/v2/enqueue"), data=body, headers={"Content-Type": "application/json"}), timeout=15).read()
  else:
    raise RuntimeError("PAGER_PROVIDER is not set to pushover or pagerduty: nothing can page the phone")
  print(f"paged ({provider}): {text}")
  mirror(text)


def mirror(text: str) -> None:
  webhook = os.environ.get("ALERT_WEBHOOK_URL")
  if not webhook:
    return
  body = json.dumps({"text": text, "content": text}).encode()
  try:
    urllib.request.urlopen(urllib.request.Request(webhook, data=body, headers={"Content-Type": "application/json"}), timeout=15).read()
  except Exception as exc:  # noqa: BLE001
    print(f"slack mirror failed: {exc}", file=sys.stderr)


def read_health(url: str | None) -> dict | None:
  if not url:
    return None
  try:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "numo-perp-pager/1"}), timeout=10) as resp:
      return json.loads(resp.read())
  except Exception:  # noqa: BLE001
    return None


def heartbeat_urls() -> tuple[str | None, str | None]:
  """(success URL, failure URL). The failure URL defaults to healthchecks.io's `<check>/fail`."""
  ok = os.environ.get("PAGER_HEARTBEAT_URL") or None
  fail = os.environ.get("PAGER_HEARTBEAT_FAIL_URL") or (f"{ok.rstrip('/')}/fail" if ok else None)
  return ok, fail


def ping(url: str | None) -> None:
  if not url:
    return
  try:
    urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "numo-perp-pager/1"}), timeout=10).read()
  except Exception as exc:  # noqa: BLE001
    print(f"heartbeat ping failed ({url}): {exc}", file=sys.stderr)


def state_path() -> Path:
  return Path(os.environ.get("PAGER_STATE_FILE", Path.home() / ".numo-perp-pager.json"))


def run(stack_path: Path) -> int:
  """One pager run. Any exception is a failed run: the dead-man's switch is told at once."""
  state_file = state_path()
  state = json.loads(state_file.read_text()) if state_file.exists() else {}
  ok_url, fail_url = heartbeat_urls()
  try:
    failures = check_and_page(stack_path, state)
  except Exception as exc:  # noqa: BLE001
    print(f"PAGER RUN FAILED: {exc}", file=sys.stderr)
    mirror(f"{os.environ.get('PAGE_PREFIX', '')}perp pager run FAILED: {exc}")
    failures = 1
  state["lastRunAt"] = int(time.time())
  state["lastRunOk"] = failures == 0
  state["provider"] = os.environ.get("PAGER_PROVIDER", "")
  state["heartbeatConfigured"] = ok_url is not None
  state_file.write_text(json.dumps(state))
  ping(ok_url if failures == 0 else fail_url)
  return 1 if failures else 0


def check_and_page(stack_path: Path, state: dict) -> int:
  url = os.environ["RPC_URL"]
  stack = json.loads(stack_path.read_text())
  number, now = head_block(url)

  ages: dict[str, int | None] = {}
  for name, feed, reader in [("index", stack["indexFeed"], index_age), ("mark", stack["markFeed"], diff_age),
                             ("impact ask", stack["impactAskFeed"], diff_age), ("impact bid", stack["impactBidFeed"], diff_age)]:
    try:
      ages[name] = reader(url, feed, now)
    except Exception:  # noqa: BLE001
      ages[name] = None

  health = read_health(os.environ.get("KEEPER_HEALTH_URL"))
  matcher_health = read_health(os.environ.get("MATCHER_HEALTH_URL", DEFAULT_MATCHER_HEALTH_URL))
  matcher = matcher_conditions(matcher_health, number)
  if matcher_health and matcher_health.get("matcher"):
    m = matcher_health["matcher"]
    idx = (m.get("details") or {}).get("indexer") or {}
    print(f"matcher: heartbeat {float(m.get('age_seconds', 0)):.0f}s ago; indexer cursor {idx.get('cursor_block', '?')} vs head {number}")
  else:
    print("matcher: health unreadable")
  sm_raw = rpc(url, "eth_call", [{"to": SUB_ACCOUNTS, "data": SEL_GET_BALANCE
                                  + f"{int(stack['securityModuleAccount']):064x}"
                                  + stack["cash"].lower().removeprefix("0x").rjust(64, "0") + "0" * 64}, "latest"])
  sm_cash = int(sm_raw, 16) / 1e18

  if keeper_healthy(health, now):
    state["keeperSeenAt"] = now
  try:
    armed = state.get("keeperSeenAt") is not None or market_open(url, stack)
  except Exception as exc:  # noqa: BLE001
    print(f"market_open unreadable ({str(exc)[:80]}); keeper page stays as it was")
    armed = state.get("keeperSeenAt") is not None

  gas = []
  warned = state.setdefault("gasWarnedAt", {})
  for name, address, floor in gas_watch():
    try:
      balance, burn = read_gas(url, number, address)
    except Exception as exc:  # noqa: BLE001
      print(f"gas {name}: unreadable ({str(exc)[:80]})")
      continue
    gas.append(gas_condition(name, balance, burn, floor))
    warning = gas_warning(name, balance, burn)
    if warning and gas[-1] is None and time.time() - warned.get(name, 0) >= GAS_WARN_REPEAT_SEC:
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      warned[name] = time.time()
    print(f"gas {name}: {balance:.5f} ETH, burn {burn:.5f}/day, floor {floor}")

  # Every secondary read is fenced: a stale index makes getSpot() revert, and a pager that dies on
  # that would never send the feed-halt page it exists for (2026-10-01, the first stale index).
  oi = None
  keeper_account = os.environ.get("KEEPER_ACCOUNT", "").strip()
  if keeper_account:
    try:
      one_side_usd, keeper_cash = read_oi_and_keeper(url, stack, int(keeper_account))
      oi = oi_condition(one_side_usd, keeper_cash)
      warning = oi_warning(one_side_usd, keeper_cash)
      if warning and time.time() - state.get("oiWarnedAt", 0) >= OI_WARN_REPEAT_SEC:
        mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
        state["oiWarnedAt"] = time.time()
      print(f"oi: one side ${one_side_usd:,.0f} vs keeper #{keeper_account} cash ${keeper_cash:,.0f}")
    except Exception as exc:  # noqa: BLE001
      print(f"oi: unreadable ({str(exc)[:80]}); feed-halt covers a stale index")
  else:
    print("oi: KEEPER_ACCOUNT unset, not watched")

  coverage = None
  future_pages: list[Condition] = []
  try:
    im = read_perp_im(url, stack)
    one_side_now = read_one_side_usd(url, stack)
    books = {"perp": (one_side_now, im)}
    future = future_artifact()
    if future is not None:
      f = read_future(url, future)
      books["future"] = (f["one_side_usd"], f["im"])
      override = os.environ.get("FUTURE_POOL_RESERVE_CNGN", "").strip()
      reserve = float(override) if override else f["reserve_target_cngn"]
      negative_for = pool_negative_for(state, f["open"], f["pool_cash_usd"], time.time())
      future_pages, warnings = future_pool_conditions(f["pool_cngn"], f["pool_cash_usd"], reserve, f["open"], negative_for)
      escrow_pages, escrow_warnings = future_escrow_conditions(f["escrow_used_cngn"], f["escrow_cap_cngn"], reserve or None, f["open"])
      future_pages += escrow_pages
      warnings += escrow_warnings
      if warnings and time.time() - state.get("futureWarnedAt", 0) >= FUTURE_WARN_REPEAT_SEC:
        for warning in warnings:
          mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
        state["futureWarnedAt"] = time.time()
      print(f"future: one side ${f['one_side_usd']:,.0f} at IM {f['im'] * 100:.0f}%, {'open' if f['open'] else 'closed'}; "
            f"pool {f['pool_cngn']:,.0f} cNGN (reserve {'unreadable' if reserve is None else f'{reserve:,.0f}'}{' set' if override else ' at the cap'}), "
            f"${f['pool_cash_usd']:,.2f} cash{f' (below zero {negative_for / 60:,.0f} min)' if negative_for else ''}; "
            f"escrow {f['escrow_used_cngn']:,.0f} of {f['escrow_cap_cngn']:,.0f} cNGN")
    else:
      print("future: not deployed (no artifact)")
    coverage = sm_combined_condition(books, sm_cash)
    warning = sm_combined_warning(books, sm_cash)
    if warning and time.time() - state.get("smCoverageWarnedAt", 0) >= SM_COVERAGE_WARN_REPEAT_SEC:
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      state["smCoverageWarnedAt"] = time.time()
    print(f"sm coverage: ${sm_cash:,.0f} against ${sm_required_usd(list(books.values())):,.0f} for a 25% step across "
          f"{', '.join(f'{n} ${o:,.0f}' for n, (o, _) in books.items())} (page at {SM_COVERAGE_PAGE_X:.1f}x)")
  except Exception as exc:  # noqa: BLE001
    print(f"sm coverage: unreadable ({str(exc)[:80]})")

  negative_cash = None
  try:
    total_borrow = read_total_borrow(url, stack)
    negative_cash = negative_cash_condition(total_borrow)
    warning = negative_cash_warning(total_borrow)
    if warning and time.time() - state.get("negativeCashWarnedAt", 0) >= NEGATIVE_CASH_WARN_REPEAT_SEC:
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      state["negativeCashWarnedAt"] = time.time()
    print(f"negative cash: ${total_borrow:,.0f} (warn ${NEGATIVE_CASH_WARN_USD:,.0f}, page ${NEGATIVE_CASH_PAGE_USD:,.0f})")
  except Exception as exc:  # noqa: BLE001
    print(f"negative cash: unreadable ({str(exc)[:80]})")

  previous_sm = state.get("smCash")
  active = [c for c in (feed_condition(ages), keeper_condition(health, now, armed), insolvent_condition(health),
                        sm_condition(previous_sm, sm_cash), unwatched_condition(heartbeat_urls()[0]),
                        peg_condition(read_index_status(), time.time()), coverage, oi, negative_cash, *future_pages, *gas, *matcher) if c is not None]
  to_page, resolved = step_state(state, active, now)
  state["smCash"] = sm_cash

  failures = 0
  for condition in to_page:
    try:
      send_page(condition.key, condition.message)
    except Exception as exc:  # noqa: BLE001
      failures += 1
      print(f"PAGE FAILED for {condition.key}: {exc}", file=sys.stderr)
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}PAGE FAILED ({exc}); unpaged: {condition.message}")
      state["active"].pop(condition.key, None)  # retry next run
  for key in resolved:
    try:
      send_page(key, f"{key} cleared.", resolve=True)
    except Exception as exc:  # noqa: BLE001
      print(f"resolve notice failed for {key}: {exc}", file=sys.stderr)
  print(f"ok: {len(active)} active ({', '.join(c.key for c in active) or 'none'}); SM ${sm_cash:,.2f}")
  return failures


def unwatched_condition(heartbeat_url: str | None) -> Condition | None:
  if heartbeat_url:
    return None
  return Condition("pager-unwatched", "cNGN-PERP pager has no dead-man's switch (PAGER_HEARTBEAT_URL): "
                   "if the pager itself stops, nothing will tell you.")


def self_test() -> int:
  # every selector and signature this script pins must name a compiled function, not just match `cast sig`
  from abi_selectors import assert_script
  assert_script(__file__)
  now = 1_000_000
  assert feed_condition({"index": 60, "mark": 60, "impact ask": 60, "impact bid": 60}) is None
  # Two refused publishes (15 min) is not a page; 16 is.
  assert feed_condition({"index": 900, "mark": 60, "impact ask": 60, "impact bid": 60}) is None
  assert feed_condition({"index": 961, "mark": 60, "impact ask": 60, "impact bid": 60}).key == "feed-halt"
  assert feed_condition({"index": 60, "mark": 60, "impact ask": 961, "impact bid": 60}).key == "feed-halt"
  assert "unreadable" in feed_condition({"index": None, "mark": 60, "impact ask": 60, "impact bid": 60}).message
  never = feed_condition({"index": NEVER_PUBLISHED, "mark": 60, "impact ask": 60, "impact bid": 60})
  assert never.key == "feed-halt" and "index never published" in never.message and "s old" not in never.message
  live = {"dryRun": False, "lastPassOk": True, "lastPassAt": now - 10, "pollIntervalMs": 15_000}
  assert keeper_condition(live, now) is None
  # Matcher: unreadable or silent pages; a fresh heartbeat with a current indexer does not; a lagging
  # indexer pages on its own key.
  assert [c.key for c in matcher_conditions(None, 100)] == ["matcher-dead"]
  assert [c.key for c in matcher_conditions({"status": "unknown"}, 100)] == ["matcher-dead"]
  fresh = {"status": "ok", "matcher": {"age_seconds": 4.2, "details": {"indexer": {"cursor_block": 998, "head_block": 1000}}}}
  assert matcher_conditions(fresh, 1000) == []
  assert [c.key for c in matcher_conditions({"matcher": {"age_seconds": 61, "details": {}}}, 1000)] == ["matcher-dead"]
  assert [c.key for c in matcher_conditions({"matcher": {"age_seconds": 4, "details": {"indexer": {"cursor_block": 939}}}}, 1000)] == ["matcher-indexer-lag"]
  assert matcher_conditions({"matcher": {"age_seconds": 4, "details": {"indexer": {"cursor_block": 940}}}}, 1000) == []
  assert [c.key for c in matcher_conditions({"matcher": {"age_seconds": 90, "details": {"indexer": {"cursor_block": 1}}}}, 1000)] == ["matcher-dead", "matcher-indexer-lag"]
  assert keeper_condition(None, now).key == "keeper-unhealthy"
  # Not armed (never seen healthy, market closed): neither an absent keeper nor the DRY_RUN smoke
  # is a page. Armed, both are.
  assert keeper_condition(None, now, armed=False) is None
  assert keeper_condition({**live, "dryRun": True}, now, armed=False) is None
  assert keeper_condition({**live, "dryRun": True}, now, armed=True) is not None
  assert keeper_healthy(live, now) and not keeper_healthy(None, now) and not keeper_healthy({**live, "dryRun": True}, now)
  # Gas: 2 days of burn, or the floor when burn is unmeasurable; Slack warning under 7 days.
  assert gas_condition("relayer", 0.015, 0.0013, 0.003) is None
  assert gas_condition("relayer", 0.0025, 0.0013, 0.003).key == "low-gas-relayer"
  assert gas_condition("executor", 0.0019, 0.0, 0.002) is not None and "unknown burn" in gas_condition("executor", 0.0019, 0.0, 0.002).message
  assert gas_condition("executor", 0.0079, 0.00003, 0.002) is None
  assert gas_warning("relayer", 0.015, 0.0013) is None and "runway 5.0 days" in gas_warning("relayer", 0.0065, 0.0013)
  # SecurityModule coverage: $3,250 covers a $19,500 side at 3x (a sixth) and $16,250 at 5x (a fifth);
  # Slack past coverage, page at 1.2x; nothing while open interest is under it.
  assert round(sm_covered_one_side_usd(3_250, 1 / 3)) == 19_500 and round(sm_covered_one_side_usd(3_250, 0.2)) == 16_250
  assert sm_coverage_condition(18_000, 19_500, 1 / 3) is None and sm_coverage_warning(18_000, 19_500, 1 / 3) is None
  assert "$17,000" in sm_coverage_warning(17_000, 16_250, 0.2) and sm_coverage_condition(17_000, 16_250, 0.2) is None
  assert sm_coverage_condition(19_500, 16_250, 0.2).key == "sm-coverage" and sm_coverage_warning(19_500, 16_250, 0.2) is None
  assert sm_coverage_condition(2, 16_250, 0.2) is None and sm_covered_one_side_usd(3_250, 0) == 0.0
  # Coverage across both books: the perp alone at $3,250 covers a $19,500 side at 3x; a $4,000 futures side
  # at IM 25% adds $750 of need. Perp-only matches the single-book rule exactly.
  assert round(sm_required_usd([(19_500, 1 / 3)])) == 3_250
  assert round(sm_required_usd([(19_500, 1 / 3), (4_000, 0.25)])) == 4_000
  assert sm_combined_condition({"perp": (19_500, 1 / 3)}, 3_250) is None
  # +$1,000 a side of futures needs $187.50 more: past what the module holds, short of the 1.2x page
  assert sm_combined_condition({"perp": (19_500, 1 / 3), "future": (1_000, 0.25)}, 3_250) is None
  assert "3,438" in sm_combined_warning({"perp": (19_500, 1 / 3), "future": (1_000, 0.25)}, 3_250)
  # +$4,000 needs $4,000 in all, past 1.2 x $3,250: a page the perp alone would not raise
  assert sm_combined_condition({"perp": (19_500, 1 / 3), "future": (4_000, 0.25)}, 3_250).key == "sm-coverage"
  combined = sm_combined_condition({"perp": (19_500, 1 / 3), "future": (20_000, 0.25)}, 3_250)
  assert combined.key == "sm-coverage" and "future one side $20,000 at IM 25%" in combined.message
  assert sm_combined_condition({"perp": (0, 1 / 3), "future": (0, 0.25)}, 0) is None
  # The future's pool: nothing while closed; reserve page under a quarter, Slack under half; an unreadable
  # reserve warns, a zero one (no reserve, the launch) is silent; borrowing pages past $250, Slack below zero.
  assert future_pool_conditions(0, -1_000, 1_000_000, open_=False) == ([], [])
  assert future_pool_conditions(600_000, 0, 1_000_000, open_=True) == ([], [])
  pages, warns = future_pool_conditions(400_000, 0, 1_000_000, open_=True)
  assert pages == [] and "40%" in warns[0]
  pages, warns = future_pool_conditions(249_999, 0, 1_000_000, open_=True)
  assert [p.key for p in pages] == ["future-pool-reserve"] and warns == []
  assert "not watched" in future_pool_conditions(0, 0, None, open_=True)[1][0]
  assert future_pool_conditions(0, 0, 0, open_=True) == ([], []), "no reserve: an empty pool is not a condition"
  # A deficit is expected between a winner and its loser settling; one that outlasts a mark and its sweep
  # (75 min) pages at any size, and not while closed.
  assert future_pool_conditions(0, -5, 0, open_=True, negative_for_sec=74 * 60)[0] == []
  pages, warns = future_pool_conditions(0, -5, 0, open_=True, negative_for_sec=75 * 60)
  assert [p.key for p in pages] == ["future-pool-deficit-stuck"] and "75 min" in pages[0].message and "$5.00 below zero" in warns[0]
  assert [p.key for p in future_pool_conditions(0, -300, 0, open_=True, negative_for_sec=80 * 60)[0]] == \
    ["future-pool-borrowing", "future-pool-deficit-stuck"]
  assert future_pool_conditions(0, 0, 0, open_=True, negative_for_sec=999_999)[0] == [], "only while below zero"
  assert future_pool_conditions(0, -5, 0, open_=False, negative_for_sec=999_999) == ([], [])
  # The timer across runs: starts at the first negative read, grows, and restarts on any read at or above
  # zero (or the market closed), so two separate short deficits never add up to a page.
  st: dict = {}
  assert pool_negative_for(st, True, -5, 1_000) == 0 and pool_negative_for(st, True, -9, 1_000 + 75 * 60) == 75 * 60
  assert pool_negative_for(st, True, 0, 6_000) == 0 and "futurePoolNegativeSince" not in st
  assert pool_negative_for(st, True, -5, 7_000) == 0 and pool_negative_for(st, True, -5, 7_000 + 74 * 60) == 74 * 60
  assert pool_negative_for(st, False, -5, 99_000) == 0 and "futurePoolNegativeSince" not in st
  # The escrow cap at 30M against an 8.2M reserve (a 40-contract cap): fine at 70%, Slack from 75%, a page
  # once under 8.2M is left (72.7% used), whichever comes first; nothing while closed or with no cap read.
  assert future_escrow_conditions(15_000_000, 30_000_000, 8_200_000, open_=True) == ([], [])
  assert future_escrow_conditions(21_000_000, 30_000_000, 5_000_000, open_=True) == ([], [])
  pages, warns = future_escrow_conditions(22_500_000, 30_000_000, 5_000_000, open_=True)
  assert pages == [] and "75% used" in warns[0]
  pages, warns = future_escrow_conditions(21_900_000, 30_000_000, 8_200_000, open_=True)
  assert [p.key for p in pages] == ["future-escrow-cap"] and "8,100,000 left" in pages[0].message and warns == []
  assert future_escrow_conditions(30_000_000, 30_000_000, 8_200_000, open_=False) == ([], [])
  # The launch: a full book margined in cNGN (~20.5M) beside the ~6.14M reserve is ~26.6M. Under a 30M cap
  # that leaves 3.4M, less than one reserve, so it pages; under 50M it leaves ~23.4M and says nothing.
  assert [p.key for p in future_escrow_conditions(26_600_000, 30_000_000, 6_140_000, open_=True)[0]] == ["future-escrow-cap"]
  assert future_escrow_conditions(26_600_000, 50_000_000, 6_140_000, open_=True) == ([], [])
  assert future_escrow_conditions(1, 0, 8_200_000, open_=True) == ([], [])
  # The reserve target: none at launch (FUTURE_RESERVE_MOVE 0), and unreadable with no index. At the
  # earlier 0.30, the launch cap of 30 contracts (15 a side) of $1,000 at 1,363.7 cNGN per USDC was
  # 30% of $15,000 = $4,500, about 6.14M cNGN, doubling with the cap.
  assert FUTURE_RESERVE_MOVE == 0.0 and future_reserve_target_cngn(30, 1_000, 1 / 1_363.7) == 0.0
  assert future_reserve_target_cngn(40, 1_000, 0) is None
  assert round(30 / 2 * 1_000 * 0.30 * 1_363.7) == round(4_500 * 1_363.7)
  pages, warns = future_pool_conditions(1_000_000, -10, 1_000_000, open_=True)
  assert pages == [] and "$10.00 below zero" in warns[0]
  assert [p.key for p in future_pool_conditions(1_000_000, -251, 1_000_000, open_=True)[0]] == ["future-pool-borrowing"]
  # OI against the keeper's cash: warning from 2x, page from 3x, page at any OI with no cash.
  assert oi_condition(9_999, 5_000) is None and oi_warning(9_999, 5_000) is None
  assert "2.2x" in oi_warning(11_000, 5_000) and oi_condition(11_000, 5_000) is None
  assert oi_condition(15_000, 5_000).key == "oi-vs-keeper" and oi_warning(15_000, 5_000) is None
  assert "no cash" in oi_condition(100, 0).message
  # Negative cash across the perp: Slack from $1,500, page from $3,000.
  assert negative_cash_condition(1_499) is None and negative_cash_warning(1_499) is None
  assert "$1,600" in negative_cash_warning(1_600) and negative_cash_condition(1_600) is None
  assert negative_cash_condition(3_000).key == "negative-cash" and negative_cash_warning(3_000) is None
  os.environ["GAS_WATCH"] = "executor=0xF68ebcC8934B068655E1A4367Ba6C0e564678703:0.002"
  os.environ["KEEPER_EOA"] = "0x00000000000000000000000000000000000000aa"
  assert [(n, f) for n, _, f in gas_watch()] == [("executor", 0.002), ("keeper", KEEPER_GAS_FLOOR_ETH)]
  os.environ.pop("GAS_WATCH"); os.environ.pop("KEEPER_EOA")
  assert [n for n, _, _ in gas_watch()] == ["executor", "relayer"]
  assert keeper_condition({**live, "dryRun": True}, now) is not None
  assert keeper_condition({**live, "lastPassAt": now - 120}, now) is not None
  assert insolvent_condition({**live, "insolventAccounts": []}) is None
  assert "7, 9" in insolvent_condition({**live, "insolventAccounts": ["7", "9"]}).message
  assert sm_condition(None, 5_000) is None and sm_condition(5_000, 5_000.5) is None
  assert "$1,018.00" in sm_condition(8_000, 6_982).message

  # Paged once when it starts, not again until REPAGE_SEC, resolved when it clears.
  state: dict = {}
  halt = Condition("feed-halt", "x")
  assert [c.key for c in step_state(state, [halt], now)[0]] == ["feed-halt"]
  assert step_state(state, [halt], now + 60)[0] == []
  assert [c.key for c in step_state(state, [halt], now + REPAGE_SEC)[0]] == ["feed-halt"]
  assert step_state(state, [], now + REPAGE_SEC + 60)[1] == ["feed-halt"]
  # A payout pages every time it happens, never "resolves".
  payout = Condition("sm-payout", "y")
  assert step_state(state, [payout], now)[0] == [payout]
  assert step_state(state, [payout], now + 60)[0] == [payout]

  assert pushover_payload("t", "u", "T", "m", emergency=True)["priority"] == "2"
  assert "priority" not in pushover_payload("t", "u", "T", "m", emergency=False)
  assert pagerduty_payload("k", "feed-halt", "m", resolve=False)["dedup_key"] == "numo-perp-feed-halt"
  assert "payload" not in pagerduty_payload("k", "feed-halt", "m", resolve=True)
  # The perp is read under the SRM until PERP_MANAGER names the engine.
  os.environ.pop("PERP_MANAGER", None)
  assert perp_manager({"srm": "0xsrm"}) == "0xsrm"
  os.environ["PERP_MANAGER"] = "0xengine"
  assert perp_manager({"srm": "0xsrm"}) == "0xengine"
  os.environ.pop("PERP_MANAGER")
  # Selectors against their signatures, so a hand-typed one cannot ship (one did, in review).
  from resolve_cngn_action6 import keccak
  assert SEL_PERP_MARGIN_REQUIREMENTS == "0x" + keccak(b"perpMarginRequirements(uint256)").hex()[:8]
  for selector, signature in [(SEL_GET_BALANCE, "getBalance(uint256,address,uint256)"),
                              (SEL_SPOT_DIFF_DETAILS, "spotDiffDetails()"),
                              (SEL_TOTAL_POSITION_CAP, "totalPositionCap(address)"),
                              (SEL_TOTAL_POSITION, "totalPosition(address)"), (SEL_GET_SPOT, "getSpot()"),
                              (SEL_CONTRACT_SIZE, "contractSize()"),
                              (SEL_FUTURE_MARGIN_REQUIREMENTS, "futureMarginRequirements(uint256)")]:
    assert selector == "0x" + keccak(signature.encode()).hex()[:8], signature
  # The peg guard pages from perp-feeds' status; missing or stale status is silent (feed-halt covers it).
  wall = 2_000_000_000.0
  tripped = {"at": wall * 1000 - 60_000, "pegGuardTripped": True, "peg": {"ngnPerCngn": 0.985, "deviationBps": 150}}
  assert peg_condition(tripped, wall).key == "peg-guard" and "150bps" in peg_condition(tripped, wall).message
  assert peg_condition({**tripped, "pegGuardTripped": False}, wall) is None
  assert peg_condition({**tripped, "at": (wall - INDEX_STATUS_MAX_AGE_SEC - 1) * 1000}, wall) is None
  assert peg_condition(None, wall) is None
  # The dead-man's switch: a missing heartbeat is its own page, daily; the failure URL follows
  # healthchecks.io's convention unless overridden.
  assert unwatched_condition(None).key == "pager-unwatched" and unwatched_condition("https://hc/x") is None
  daily: dict = {}
  unwatched = unwatched_condition(None)
  assert step_state(daily, [unwatched], now)[0] == [unwatched]
  assert step_state(daily, [unwatched], now + REPAGE_SEC)[0] == []
  assert step_state(daily, [unwatched], now + UNWATCHED_REPAGE_SEC)[0] == [unwatched]
  os.environ["PAGER_HEARTBEAT_URL"] = "https://hc-ping.com/abc/"
  os.environ.pop("PAGER_HEARTBEAT_FAIL_URL", None)
  assert heartbeat_urls() == ("https://hc-ping.com/abc/", "https://hc-ping.com/abc/fail")
  os.environ.pop("PAGER_HEARTBEAT_URL")
  assert heartbeat_urls() == (None, None)
  print("self-test ok")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Page the operator for cNGN-PERP conditions")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--test-page", action="store_true", help="send one [TEST] page through the configured pager")
  ap.add_argument("--stack", type=Path, default=STACK_ARTIFACT)
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  load_env_file(Path.home() / ".numo-perp-pager.env")
  if args.test_page:
    os.environ["PAGE_PREFIX"] = "[TEST] " + os.environ.get("PAGE_PREFIX", "")
    send_page("test", "pager check: if this reached your phone, paging works. Reply that you saw it.")
    return 0
  return run(args.stack)


if __name__ == "__main__":
  raise SystemExit(main())
