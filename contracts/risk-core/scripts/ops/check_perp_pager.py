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
  perp-oi            the perp, wound down 2026-10-20, holds open interest: the SecurityModule is sized for
                     the future alone, so that open interest is uncovered.
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
  sm-coverage        the SecurityModule's cash against what an SM_MOVE move costs on the future's one-side
                     open interest (sm_required_usd); Slack past it, page at 1.2x.
  future-pool-reserve  the future's VM pool holds less than a quarter of its reserve target (Slack
                     under half). The target is FUTURE_RESERVE_MOVE of one side's notional at the
                     position cap, in cNGN at the index; FUTURE_POOL_RESERVE_CNGN overrides it.
                     FUTURE_RESERVE_MOVE is 0 since 2026-10-13 (no reserve: winners are paid in USDC
                     once the pool holds no cNGN), so this is off unless the override sets one.
  future-escrow-cap  the cNGN escrow's cap for the future's manager has less headroom left than the
                     pool's reserve target: a full reserve top-up would no longer fit, and the
                     deposit would revert. Slack from 75% used. Raise the cap (vault) or ask traders
                     to margin in USDC.
  future-pool-borrowing  the pool's net (USDC cash plus cNGN at the index, the engine's spot feed) is below
                     -FUTURE_POOL_BORROW_PAGE_USD: winners were paid before losers paid in. Slack at any
                     negative net. cNGN held against a USDC debt counts, so a pool that is short in cash
                     but covered in cNGN is not a condition; a naira fall that uncovers it is.
  future-pool-deficit-stuck  the pool's net has stayed below zero for FUTURE_POOL_DEFICIT_STUCK_SEC (75 min),
                     at any size. numo-future-feeds settles losers every minute while the net is below
                     zero (up to 10 a tick, and alerts future-pool-deficit-stranded if none are left), so
                     a deficit that lasts this long means it is not working or cannot: top the pool up.

MarginEngine v2's futures (FUTURE_V2_ARTIFACTS, comma-separated, default deployments/8453/MARGIN_ENGINE_V2.json: one
artifact per series, cNGN-30NOV26 now and EURC-30NOV26 once deployed; each skipped while missing). Linear, VM in USDC
cash through the engine's pool, so no reserve target and no escrow cap: the pool is cash only.
  sm-coverage        counts every future it reads, v1's and each v2 series' (sm_required_usd_linear, the whole
                     SM_MOVE step on one side), against the one SecurityModule they share.
  future-pool-borrowing-v2  v2's pool cash is below -FUTURE_POOL_BORROW_PAGE_USD (Slack at any negative cash), per engine:
                     every series on it shares the pool.
  future-pool-deficit-stuck-v2  that cash has stayed below zero for FUTURE_POOL_DEFICIT_STUCK_SEC, at any size.
  keeper-unhealthy-v2 / insolvent-account-v2  v2's liquidation keeper (ENGINE_V2_KEEPER_HEALTH_URL, unset: not
                     watched), as keeper-unhealthy and insolvent-account; armed once healthy or a v2 future is open.

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
import math
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
# SecurityModule sizing, for the future alone since the perp's wind-down (MarginEngineDeployFork
# .testSecurityModuleCoverageAgainstTheFork): one whole side opened at IM is left at maintenance margin, the naira
# loses SM_MOVE of its USD value with the losers settled at every mark, and the auction runs to its end. The module
# pays nothing while the side stays solvent and, once it is not, the step's whole loss, because an insolvent auction
# ends at the account's maintenance margin:
#   one-side notional x premium x ln(1 / (1 - SM_MOVE)) when that exceeds one-side notional x MM, else 0
# premium is mark / index. Never below the fork and within 2.2% of it from 15% to 30%. At MM 15% the cliff is a move of
# 1 - exp(-MM / premium), 13.8% at premium 1.0106: below it the module pays nothing at any open interest. 0.15 clears
# it while premium stays above 0.923 (the future less than 7.7% under the index); 0.14 sat on it, at 0.9945.
# SM_MOVE is the one place the assumed move is set: 0.25 until 2026-10-20 (the perp's rule), then 0.15. Read against
# ACTUAL one-side open interest here (Slack past coverage, page at 1.2x), against the cap by the proposer's sm gate.
# docs/cngn-future-security-module.md has the reasoning.
SM_MOVE = 0.15
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
# A deploy replaces the matcher stop-before-start (one task; exchange #235 is the overlap fix), so every deploy
# leaves ~70s with no heartbeat. infra/aws/with-matcher-mute.sh writes /numo/pager/mute_matcher_dead_until (unix
# seconds) while it runs and deletes it after; run-with-ssm-pager.sh exports it as PAGER_MUTE_MATCHER_DEAD_UNTIL.
# A mute keeps a NEW matcher-dead from paging. It never hides one already paging, and one set more than
# MATCHER_MUTE_MAX_SEC ahead is ignored, so a typo or a crashed deploy cannot silence a dead matcher for long.
MATCHER_MUTE_MAX_SEC = 900
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
# MarginEngine v2's series, one artifact each (FUTURE_V2_ARTIFACTS overrides, comma-separated).
FUTURE_V2_ARTIFACTS = [ROOT / "deployments" / "8453" / "MARGIN_ENGINE_V2.json"]
SEL_CONTRACT_SIZE = "0x3d7cc610"  # contractSize() -- `cast sig`, pinned in --self-test
SEL_FUTURE_MARGIN_REQUIREMENTS = "0x84033e5e"  # futureMarginRequirements(uint256) -> (mmReq, imReq) on MarginEngine
SEL_FUTURE_CONTRACTS = "0xc3c74b34"  # futureContracts(uint256) -> FutureContract; markPrice is word 5 -- `cast sig`, pinned in --self-test
# The pool's cNGN reserve, as a fraction of one side's notional at the cap. 0 since 2026-10-13 (decided):
# launch traders margin in USDC, so a seed would drain to winners and be refilled in USDC within a few
# marks, and the reserve changes neither settlement (which never reverts) nor anyone's margin. Without it
# a winner settling before its loser is paid in borrowed cash for that window; future-pool-borrowing and
# future-pool-deficit-stuck watch that instead. The earlier sizing, for raising it again: 0.30 (a full side
# paying in USDC through a 25% move, plus one 5% mark a winner can draw before its losers settle).
FUTURE_RESERVE_MOVE = 0.0
FUTURE_RESERVE_PAGE_FRACTION = 0.25
FUTURE_RESERVE_WARN_FRACTION = 0.5
FUTURE_POOL_BORROW_PAGE_USD = 250.0
FUTURE_POOL_DEFICIT_STUCK_SEC = 75 * 60
# A net within $1 of zero is covered: settlement's rounding, and the cash rate on a USDC debt the pool's cNGN
# covers, are not worth a page. The interest on a $5,000 debt at 10% crosses $1 within a day, about when a
# top-up is worth doing. numo-future-feeds uses the same tolerance (POOL_NET_TOLERANCE).
FUTURE_POOL_DUST_USD = 1.0
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


def keeper_condition(health: dict | None, now: int, armed: bool = True, name: str = "cNGN-PERP",
                     key: str = "keeper-unhealthy") -> Condition | None:
  """`armed` is False until the keeper has ever reported healthy and the market is still closed:
  a keeper that is not installed yet, or running its DRY_RUN smoke (go-live steps 14-17), is not
  a page. Once the market is open, no keeper at all is the loudest condition there is. `name` and `key`
  tell a second keeper apart (v2's: "MarginEngine v2", keeper-unhealthy-v2)."""
  if not armed:
    return None
  if health is None:
    return Condition(key, f"{name} keeper /health unreachable: nothing is liquidating.")
  if health.get("dryRun", True):
    return Condition(key, f"{name} keeper is in DRY_RUN: it decides but sends nothing.")
  stale_after = 3 * max(int(health.get("pollIntervalMs", 15_000)) // 1000, 20)
  age = now - int(health.get("lastPassAt", 0))
  if not health.get("lastPassOk") or age > stale_after:
    return Condition(key, f"{name} keeper unhealthy: last pass ok={health.get('lastPassOk')} {age}s ago.")
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


def matcher_mute(until: str | None, now: float) -> tuple[bool, str]:
  """Whether a deploy has muted matcher-dead now, and a line saying why (empty when no mute is set)."""
  if not until or not until.strip():
    return False, ""
  try:
    deadline = float(until)
  except ValueError:
    return False, f"matcher-dead mute ignored: {until.strip()[:40]!r} is not a unix time"
  left = deadline - now
  if left <= 0:
    return False, ""
  if left > MATCHER_MUTE_MAX_SEC:
    return False, f"matcher-dead mute ignored: it runs {left:.0f}s ahead, more than the {MATCHER_MUTE_MAX_SEC}s a deploy may take"
  return True, f"matcher-dead muted for a deploy for {left:.0f}s more"


def unmuted_matcher_conditions(conditions: list[Condition], muted: bool, state: dict) -> list[Condition]:
  """The matcher conditions to page on. A mute drops a matcher-dead that is not already paging; one that is
  stays, so a deploy started during an outage cannot resolve it. The indexer lag is never muted."""
  if not muted or "matcher-dead" in state.get("active", {}):
    return conditions
  return [c for c in conditions if c.key != "matcher-dead"]


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


def sm_required_usd(one_side_usd: float, mm: float, premium: float, move: float = SM_MOVE) -> float:
  """What the SecurityModule pays if one whole side of the future, at maintenance margin `mm`, is liquidated after the
  naira loses `move` of its value (the fit at SM_MOVE): the whole loss once the side is insolvent, 0 before."""
  if one_side_usd <= 0 or not 0 < move < 1:
    return 0.0
  loss = one_side_usd * premium * math.log(1 / (1 - move))
  return loss if loss > one_side_usd * mm else 0.0


def sm_required_usd_linear(one_side_usd: float, move: float = SM_MOVE) -> float:
  """MarginEngine v2's future (USDC VM, linear in price): what the SecurityModule pays if one whole side is liquidated
  after a `move` against it, taken as the whole step, one_side x move. An upper bound until #245's coverage test runs
  against v2 (docs/margin-engine-v2.md): on v1 the fork found the module paid close to the whole step once a side was
  insolvent, and a linear side at MM 15% is insolvent at exactly a 15% move, where sm_required_usd's "0 until
  insolvent" would read nothing at all."""
  if one_side_usd <= 0 or not 0 < move < 1:
    return 0.0
  return one_side_usd * move


def sm_coverage_condition(required_by: dict[str, float], sm_cash_usd: float) -> Condition | None:
  """sm-coverage across every future the one SecurityModule backs (v1's, each v2 series'): what each needs for an
  SM_MOVE step against one side, summed, which is conservative across bases. Pages at 1.2x of what the module holds."""
  required = sum(required_by.values())
  if required <= 0 or required < SM_COVERAGE_PAGE_X * sm_cash_usd:
    return None
  parts = ", ".join(f"{label} ${need:,.0f}" for label, need in required_by.items() if need > 0)
  return Condition("sm-coverage", f"cNGN SecurityModule ${sm_cash_usd:,.0f} covers less than 1/{SM_COVERAGE_PAGE_X:.1f} of a "
                   f"{SM_MOVE * 100:.0f}% move on the futures' one side (needs ${required:,.0f}: {parts}). "
                   "Fund the SecurityModule, or set cap = current OI.")


def sm_coverage_warning(required_by: dict[str, float], sm_cash_usd: float) -> str | None:
  required = sum(required_by.values())
  if required <= sm_cash_usd or required >= SM_COVERAGE_PAGE_X * sm_cash_usd:
    return None
  return (f"cNGN SecurityModule ${sm_cash_usd:,.0f} is short of the ${required:,.0f} a {SM_MOVE * 100:.0f}% move on the futures "
          f"would cost (page at {SM_COVERAGE_PAGE_X:.1f}x): fund it.")


def v1_coverage_label(one_side_usd: float, mm: float) -> str:
  return f"USDC-cNGN one side ${one_side_usd:,.0f} at MM {mm * 100:.0f}%"


def sm_future_condition(one_side_usd: float, mm: float, premium: float, sm_cash_usd: float) -> Condition | None:
  """sm-coverage for v1's future alone."""
  return sm_coverage_condition({v1_coverage_label(one_side_usd, mm): sm_required_usd(one_side_usd, mm, premium)}, sm_cash_usd)


def sm_future_warning(one_side_usd: float, mm: float, premium: float, sm_cash_usd: float) -> str | None:
  return sm_coverage_warning({v1_coverage_label(one_side_usd, mm): sm_required_usd(one_side_usd, mm, premium)}, sm_cash_usd)


def perp_oi_condition(one_side_usd: float) -> Condition | None:
  """The SecurityModule is sized for the future alone since the perp's wind-down: perp open interest is uncovered."""
  if one_side_usd < 1:
    return None
  return Condition("perp-oi", f"cNGN-PERP holds ${one_side_usd:,.0f} of one-side open interest, which the SecurityModule is no "
                   "longer sized for (wound down 2026-10-20). Close it, and set the perp's cap to 0 (vault).")


def pool_net_usd(pool_cngn: float, pool_cash_usd: float, spot_usd_per_cngn: float) -> float:
  """The future's VM pool as numo-future-feeds judges it: its USDC cash plus its cNGN at the engine's spot feed."""
  return pool_cash_usd + pool_cngn * spot_usd_per_cngn


def future_pool_conditions(pool_cngn: float, pool_net: float, reserve_cngn: float | None,
                           open_: bool, negative_for_sec: float = 0) -> tuple[list[Condition], list[str]]:
  """(pages, Slack warnings) for the future's VM pool. Nothing before the market opens. reserve_cngn None
  is an unreadable target; 0 is no reserve (FUTURE_RESERVE_MOVE 0). pool_net: pool_net_usd. negative_for_sec:
  how long the net has been below zero without a break."""
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
  if pool_net >= -FUTURE_POOL_DUST_USD:
    return pages, warnings
  if pool_net < -FUTURE_POOL_BORROW_PAGE_USD:
    pages.append(Condition("future-pool-borrowing", f"cNGN future VM pool is ${-pool_net:,.0f} below zero, net (USDC plus cNGN at the "
                           "index): winners were paid before losers paid in. Check numo-future-feeds' deficit cover, and top the pool up."))
  else:
    warnings.append(f"cNGN future VM pool is ${-pool_net:,.2f} below zero, net of its cNGN (page past ${FUTURE_POOL_BORROW_PAGE_USD:,.0f}).")
  if negative_for_sec >= FUTURE_POOL_DEFICIT_STUCK_SEC:
    pages.append(Condition("future-pool-deficit-stuck", f"cNGN future VM pool has been ${-pool_net:,.2f} below zero, net of its cNGN, for "
                           f"{negative_for_sec / 60:,.0f} min: numo-future-feeds settles losers every minute while it is, so it is "
                           "not working or has no loser left (future-pool-deficit-stranded): top up the pool account."))
  return pages, warnings


def pool_negative_for(state: dict, open_: bool, pool_net: float, now: float, key: str = "futurePoolNegativeSince") -> float:
  """Seconds the future pool's net has been below zero without a break, kept across runs in `state`
  (`key`: futurePoolNegativeSince for v1's pool, one per engine for v2's): any run that reads it at or above zero, or
  the market closed, restarts it."""
  if open_ and pool_net < -FUTURE_POOL_DUST_USD:
    return now - state.setdefault(key, now)
  state.pop(key, None)
  return 0.0


def v2_pool_conditions(label: str, pool: int, cash_usd: float, open_: bool,
                       negative_for_sec: float = 0) -> tuple[list[Condition], list[str]]:
  """(pages, Slack warnings) for a MarginEngine v2 VM pool (`label`: the engine, "v2"). Cash only: VM is USDC, nothing
  converted, so the net is the cash and there is no reserve to hold. Same thresholds as v1's pool. Nothing while no series
  on the engine is open."""
  if not open_ or cash_usd >= -FUTURE_POOL_DUST_USD:
    return [], []
  pages: list[Condition] = []
  warnings: list[str] = []
  if cash_usd < -FUTURE_POOL_BORROW_PAGE_USD:
    pages.append(Condition(f"future-pool-borrowing-{label}", f"MarginEngine {label} VM pool #{pool} is ${-cash_usd:,.0f} below zero in "
                           "cash: winners were paid before losers paid in. Check the v2 future keepers' deficit cover, and top the pool up."))
  else:
    warnings.append(f"MarginEngine {label} VM pool #{pool} is ${-cash_usd:,.2f} below zero in cash (page past ${FUTURE_POOL_BORROW_PAGE_USD:,.0f}).")
  if negative_for_sec >= FUTURE_POOL_DEFICIT_STUCK_SEC:
    pages.append(Condition(f"future-pool-deficit-stuck-{label}", f"MarginEngine {label} VM pool #{pool} has been ${-cash_usd:,.2f} below "
                           f"zero for {negative_for_sec / 60:,.0f} min: its future keepers settle losers every minute while it is, so "
                           "they are not working or have no loser left (future-pool-deficit-stranded): top up the pool account."))
  return pages, warnings


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
  requirements = call(future["manager"], SEL_FUTURE_MARGIN_REQUIREMENTS + f"{int(future['marketId']):064x}")
  mm, im = int(requirements[:64], 16) / 1e18, int(requirements[64:128], 16) / 1e18
  spot = int(call(future["indexFeed"], SEL_GET_SPOT)[:64], 16) / 1e18
  mark = int(call(future["future"], SEL_FUTURE_CONTRACTS + f"{int(future['subId']):064x}")[5 * 64:6 * 64], 16) / 1e18
  escrow_used = int(call(future["cngnEscrow"], SEL_TOTAL_POSITION + manager_word), 16) / 1e18
  escrow_cap = int(call(future["cngnEscrow"], SEL_TOTAL_POSITION_CAP + manager_word), 16) / 1e18
  pool = int(future["poolAccount"])
  return {
    "one_side_usd": (total / 2) / 1e18 * (size / 1e18),
    "im": im,
    "mm": mm,
    # mark / index: the short's loss per dollar of notional per unit of move
    "premium": mark * spot,
    "open": cap > 0,
    "reserve_target_cngn": future_reserve_target_cngn(cap / 1e18, size / 1e18, spot),
    "escrow_used_cngn": escrow_used,
    "escrow_cap_cngn": escrow_cap,
    "pool_cngn": account_balance(url, pool, future["cngnEscrow"]) / 1e18,
    "pool_cash_usd": account_balance(url, pool, future["cash"]) / 1e18,
    # the index feed is the engine's spot feed for the market (getMarketFeeds), the one settlement converts at
    "spot": spot,
  }


def read_future_v2(url: str, future: dict) -> dict:
  """A MarginEngine v2 series (USDC per unit of its base, a contract of the base): one side's notional at the mark, its
  margin rates, whether it is open. The pool is the engine's, read once per engine (read_pool_cash)."""
  manager_word = future["manager"].lower().removeprefix("0x").rjust(64, "0")
  call = lambda to, data: rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])[2:]  # noqa: E731
  total = int(call(future["future"], SEL_TOTAL_POSITION + manager_word), 16) / 1e18
  size = int(call(future["future"], SEL_CONTRACT_SIZE), 16) / 1e18
  cap = int(call(future["future"], SEL_TOTAL_POSITION_CAP + manager_word), 16)
  requirements = call(future["manager"], SEL_FUTURE_MARGIN_REQUIREMENTS + f"{int(future['marketId']):064x}")
  mark = int(call(future["future"], SEL_FUTURE_CONTRACTS + f"{int(future['subId']):064x}")[5 * 64:6 * 64], 16) / 1e18
  return {
    "one_side_usd": v2_one_side_usd(total, size, mark),
    "mm": int(requirements[:64], 16) / 1e18,
    "im": int(requirements[64:128], 16) / 1e18,
    "open": cap > 0,
    "mark": mark,
  }


def v2_one_side_usd(total_contracts: float, contract_size: float, mark: float) -> float:
  """One side's notional in USD: half the both-sides total, each contract contract_size of the base at the mark."""
  return total_contracts / 2 * contract_size * mark


def read_pool_cash(url: str, future: dict) -> float:
  return account_balance(url, int(future["poolAccount"]), future["cash"]) / 1e18


def record_watched(state: dict, future: dict) -> None:
  """Records in the state file a future this run read: its manager under futureManagers and its asset under futures,
  which the enable gates read (propose_margin_engine_v2_batch.py the manager, propose_eurc_future_v2_batch.py the
  asset). Called only after the read succeeded, so a future that failed to read is not listed as watched."""
  for key, value in (("futureManagers", future["manager"]), ("futures", future["future"])):
    watched = state.setdefault(key, [])
    if value not in watched:
      watched.append(value)


def future_v2_artifacts() -> list[tuple[Path, dict]]:
  """Each v2 series' artifact that exists, with its path. A missing one (a series not yet deployed) is skipped."""
  raw = os.environ.get("FUTURE_V2_ARTIFACTS", "").strip()
  paths = [Path(p.strip()) for p in raw.split(",") if p.strip()] if raw else FUTURE_V2_ARTIFACTS
  return [(path, json.loads(path.read_text())) for path in paths if path.exists()]


def series_label(future: dict) -> str:
  """cNGN-30NOV26-style, for messages: the artifact's symbol (EURC_FUTURE_V2.json names one), else its base (default
  cNGN, MARGIN_ENGINE_V2.json names none) and expiry."""
  if future.get("symbol"):
    return future["symbol"]
  return f"{future.get('baseSymbol', 'cNGN')}-{time.strftime('%d%b%y', time.gmtime(int(future['expiry']))).upper()}"


def future_artifact() -> dict | None:
  path = Path(os.environ.get("FUTURE_ARTIFACT", FUTURE_ARTIFACT))
  return json.loads(path.read_text()) if path.exists() else None


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


def insolvent_condition(health: dict | None, name: str = "cNGN-PERP", key: str = "insolvent-account") -> Condition | None:
  accounts = (health or {}).get("insolventAccounts") or []
  if not accounts:
    return None
  return Condition(key, f"{name} insolvent account(s) {', '.join(accounts)}: the SecurityModule will pay.")


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
  muted, mute_note = matcher_mute(os.environ.get("PAGER_MUTE_MATCHER_DEAD_UNTIL"), time.time())
  if mute_note:
    print(mute_note)
  matcher = unmuted_matcher_conditions(matcher, muted, state)
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
  perp_oi = None
  future_pages: list[Condition] = []
  # What a SM_MOVE step on one side of each future would cost the SecurityModule they all share, by future.
  coverage_parts: dict[str, float] = {}
  futures_read = False
  try:
    perp_one_side = read_one_side_usd(url, stack)
    perp_oi = perp_oi_condition(perp_one_side)
    print(f"perp: one side ${perp_one_side:,.0f} (wound down: the SecurityModule is not sized for it)")
  except Exception as exc:  # noqa: BLE001
    print(f"perp: unreadable ({str(exc)[:80]})")
  try:
    future = future_artifact()
    # Which manager's future this run read, for the MarginEngine enable gate: a pager that does not read
    # the engine's future (an old copy, a missing artifact, a failed read) must not pass it.
    state.pop("futureManager", None)
    state.pop("futureManagers", None)
    state.pop("futures", None)
    if future is not None:
      f = read_future(url, future)
      state["futureManager"] = future["manager"]
      record_watched(state, future)
      override = os.environ.get("FUTURE_POOL_RESERVE_CNGN", "").strip()
      reserve = float(override) if override else f["reserve_target_cngn"]
      net = pool_net_usd(f["pool_cngn"], f["pool_cash_usd"], f["spot"])
      negative_for = pool_negative_for(state, f["open"], net, time.time())
      future_pages, warnings = future_pool_conditions(f["pool_cngn"], net, reserve, f["open"], negative_for)
      escrow_pages, escrow_warnings = future_escrow_conditions(f["escrow_used_cngn"], f["escrow_cap_cngn"], reserve or None, f["open"])
      future_pages += escrow_pages
      warnings += escrow_warnings
      if warnings and time.time() - state.get("futureWarnedAt", 0) >= FUTURE_WARN_REPEAT_SEC:
        for warning in warnings:
          mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
        state["futureWarnedAt"] = time.time()
      print(f"future: one side ${f['one_side_usd']:,.0f} at IM {f['im'] * 100:.0f}%, {'open' if f['open'] else 'closed'}; "
            f"pool {f['pool_cngn']:,.0f} cNGN (reserve {'unreadable' if reserve is None else f'{reserve:,.0f}'}{' set' if override else ' at the cap'}), "
            f"${f['pool_cash_usd']:,.2f} cash, net ${net:,.2f}{f' (below zero {negative_for / 60:,.0f} min)' if negative_for else ''}; "
            f"escrow {f['escrow_used_cngn']:,.0f} of {f['escrow_cap_cngn']:,.0f} cNGN")
      coverage_parts[v1_coverage_label(f["one_side_usd"], f["mm"])] = sm_required_usd(f["one_side_usd"], f["mm"], f["premium"])
      futures_read = True
    else:
      print("future: not deployed (no artifact)")
  except Exception as exc:  # noqa: BLE001
    print(f"future: unreadable ({str(exc)[:80]})")

  # MarginEngine v2: each series' side for the SecurityModule, and each engine's cash-only pool, once.
  v2_open: dict[str, bool] = {}
  v2_pools: dict[str, dict] = {}
  try:
    for path, series in future_v2_artifacts():
      label = series_label(series)
      f2 = read_future_v2(url, series)
      record_watched(state, series)
      need = sm_required_usd_linear(f2["one_side_usd"])
      coverage_parts[f"{label} one side ${f2['one_side_usd']:,.0f}"] = need
      futures_read = True
      engine = series["manager"].lower()
      v2_open[engine] = v2_open.get(engine, False) or f2["open"]
      v2_pools.setdefault(engine, series)
      print(f"future {label} (v2, {path.name}): one side ${f2['one_side_usd']:,.0f} at mark {f2['mark']:.9f}, IM {f2['im'] * 100:.0f}%, "
            f"{'open' if f2['open'] else 'closed'}; SM needs ${need:,.0f} for a {SM_MOVE * 100:.0f}% step")
    v2_warnings: list[str] = []
    for engine, series in v2_pools.items():
      # one engine today ("v2"); a further engine would take its own label from its artifact
      engine_label = series.get("engineLabel", "v2")
      cash = read_pool_cash(url, series)
      negative_for = pool_negative_for(state, v2_open[engine], cash, time.time(), f"futurePoolNegativeSince:{engine}")
      pages, warnings = v2_pool_conditions(engine_label, int(series["poolAccount"]), cash, v2_open[engine], negative_for)
      future_pages += pages
      v2_warnings += warnings
      print(f"pool {engine_label} #{series['poolAccount']}: ${cash:,.2f} cash{f' (below zero {negative_for / 60:,.0f} min)' if negative_for else ''}")
    if v2_warnings and time.time() - state.get("futureV2WarnedAt", 0) >= FUTURE_WARN_REPEAT_SEC:
      for warning in v2_warnings:
        mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      state["futureV2WarnedAt"] = time.time()
  except Exception as exc:  # noqa: BLE001
    print(f"v2 futures: unreadable ({str(exc)[:80]})")

  if futures_read:
    coverage = sm_coverage_condition(coverage_parts, sm_cash)
    warning = sm_coverage_warning(coverage_parts, sm_cash)
    if warning and time.time() - state.get("smCoverageWarnedAt", 0) >= SM_COVERAGE_WARN_REPEAT_SEC:
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      state["smCoverageWarnedAt"] = time.time()
    print(f"sm coverage: ${sm_cash:,.0f} against ${sum(coverage_parts.values()):,.0f} for a {SM_MOVE * 100:.0f}% move on every "
          f"future's one side ({'; '.join(f'{k}: ${v:,.0f}' for k, v in coverage_parts.items())}; page at {SM_COVERAGE_PAGE_X:.1f}x)")

  # v2's liquidation keeper, when its health URL is set: armed once it has reported healthy, or a v2 future is open.
  v2_keeper: list[Condition | None] = []
  v2_health_url = os.environ.get("ENGINE_V2_KEEPER_HEALTH_URL", "").strip()
  if v2_health_url:
    v2_health = read_health(v2_health_url)
    if keeper_healthy(v2_health, now):
      state["keeperV2SeenAt"] = now
    v2_armed = state.get("keeperV2SeenAt") is not None or any(v2_open.values())
    v2_keeper = [keeper_condition(v2_health, now, v2_armed, "MarginEngine v2", "keeper-unhealthy-v2"),
                 insolvent_condition(v2_health, "MarginEngine v2", "insolvent-account-v2")]
    print(f"v2 keeper: {'unreachable' if v2_health is None else ('ok' if keeper_healthy(v2_health, now) else 'unhealthy')}")

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
                        peg_condition(read_index_status(), time.time()), coverage, perp_oi, oi, negative_cash, *future_pages, *v2_keeper,
                        *gas, *matcher) if c is not None]
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
  # A deploy's mute: honoured until it lapses, never past MATCHER_MUTE_MAX_SEC ahead, never on garbage.
  assert matcher_mute(None, now) == (False, "") and matcher_mute("", now) == (False, "")
  assert matcher_mute(str(now + 600), now)[0] is True
  assert matcher_mute(str(now - 1), now) == (False, "")
  assert matcher_mute(str(now + MATCHER_MUTE_MAX_SEC + 1), now)[0] is False and "ignored" in matcher_mute(str(now + 86400), now)[1]
  assert matcher_mute("tomorrow", now)[0] is False and "ignored" in matcher_mute("tomorrow", now)[1]
  dead_and_lagging = matcher_conditions({"matcher": {"age_seconds": 90, "details": {"indexer": {"cursor_block": 1}}}}, 1000)
  assert [c.key for c in unmuted_matcher_conditions(dead_and_lagging, True, {})] == ["matcher-indexer-lag"]
  assert unmuted_matcher_conditions(dead_and_lagging, False, {}) == dead_and_lagging
  paging = {"active": {"matcher-dead": {"since": now - 300, "lastPagedAt": now - 300}}}
  assert unmuted_matcher_conditions(dead_and_lagging, True, paging) == dead_and_lagging
  # Through step_state: a muted deploy gap pages nothing, and pages once the mute lapses.
  quiet: dict = {}
  assert step_state(quiet, unmuted_matcher_conditions(dead_and_lagging[:1], True, quiet), now) == ([], [])
  assert [c.key for c in step_state(quiet, unmuted_matcher_conditions(dead_and_lagging[:1], False, quiet), now)[0]] == ["matcher-dead"]
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
  # SecurityModule coverage, against the fork (MarginEngineDeployFork.testSecurityModuleCoverageAgainstTheFork: a $15,000
  # side at MM 15%, premium 1.0225): the fit is 0 while the side stays solvent and the whole loss after, never below the
  # fork and within 2.2% of it.
  for move, fork in [(0.10, 0.0), (0.125, 0.0), (0.15, 2_440.57), (0.20, 3_348.51), (0.25, 4_320.07), (0.30, 5_354.55)]:
    fit = sm_required_usd(15_000, 0.15, 1.0225, move)
    assert (fit == 0) if fork == 0 else (fork <= fit <= fork * 1.05), (move, fit, fork)
  # At the default move (15%) a side at MM 15% is past the cliff: the launch cap's side costs $2,468 and the 1,200
  # cap's $98,721 at today's premium; a 10% move costs nothing at any size.
  assert SM_MOVE == 0.15 and round(sm_required_usd(15_000, 0.15, 1.0124)) == 2_468
  assert int(sm_required_usd(600_000, 0.15, 1.0124)) == 98_720 and sm_required_usd(600_000, 0.15, 1.0124, 0.10) == 0.0
  # The edge of 15%: only with the future more than 7.7% under the index (premium < 0.923) does the side survive it.
  assert sm_required_usd(15_000, 0.15, 0.923) > 0 and sm_required_usd(15_000, 0.15, 0.922) == 0.0
  # 14% sat on the edge: half a percent under the index was enough.
  assert sm_required_usd(15_000, 0.15, 0.995, 0.14) > 0 and sm_required_usd(15_000, 0.15, 0.994, 0.14) == 0.0
  # v2's linear rule: the whole step. A 30-contract cap at 0.000743 is a $11,145 side, $1,671.75 at 15%; nothing for no side.
  assert sm_required_usd_linear(15 * 1_000_000 * 0.000743) == 15 * 1_000_000 * 0.000743 * 0.15
  assert sm_required_usd_linear(0) == 0.0 and sm_required_usd_linear(11_145, 0.40) == 11_145 * 0.40
  # Slack past coverage, page at 1.2x of it.
  assert "2,468" in sm_future_warning(15_000, 0.15, 1.0124, 2_100) and sm_future_condition(15_000, 0.15, 1.0124, 2_100) is None
  assert sm_future_condition(15_000, 0.15, 1.0124, 2_000).key == "sm-coverage"
  assert sm_future_condition(15_000, 0.15, 1.0124, 2_469) is None and sm_future_warning(15_000, 0.15, 1.0124, 2_469) is None
  # Across futures: one SecurityModule backs v1's and every v2 series', so their needs add up. Each alone is covered by
  # $3,250 (v1 $2,468; v2 cNGN 15 contracts at 0.000743, $1,671.75); together they are not, and page at 1.2x.
  v2_side = v2_one_side_usd(30, 1_000_000, 0.000743)
  assert abs(v2_side - 11_145) < 1e-6
  parts = {"USDC-cNGN": sm_required_usd(15_000, 0.15, 1.0124), "cNGN-30NOV26": sm_required_usd_linear(v2_side)}
  assert sm_coverage_condition({"cNGN-30NOV26": parts["cNGN-30NOV26"]}, 3_250) is None
  assert "4,140" in sm_coverage_warning(parts, 3_500) and sm_coverage_condition(parts, 3_500) is None
  assert sm_coverage_condition(parts, 3_250).key == "sm-coverage" and "cNGN-30NOV26 $1,672" in sm_coverage_condition(parts, 3_250).message
  # an EURC series (1,000 EURC at 1.1625, 20 contracts) is one more part, priced by its own mark
  parts["EURC-30NOV26"] = sm_required_usd_linear(v2_one_side_usd(20, 1_000, 1.1625))
  assert abs(parts["EURC-30NOV26"] - 10 * 1_000 * 1.1625 * 0.15) < 1e-6
  assert series_label({"expiry": 1796047200}) == "cNGN-30NOV26"
  assert series_label({"expiry": 1796047200, "baseSymbol": "EURC"}) == "EURC-30NOV26"
  # EURC_FUTURE_V2.json names its series in `symbol` and has no baseSymbol: read as cNGN it would share cNGN's label
  assert series_label({"expiry": 1796054400, "symbol": "EURC-30NOV26"}) == "EURC-30NOV26"
  # What the run read goes to the state file: each manager once, each future asset (v1's, then every v2 series).
  watched: dict = {}
  record_watched(watched, {"manager": "0xv1", "future": "0xf1"})
  record_watched(watched, {"manager": "0xv2", "future": "0xcngn"})
  record_watched(watched, {"manager": "0xv2", "future": "0xeurc"})
  assert watched == {"futureManagers": ["0xv1", "0xv2"], "futures": ["0xf1", "0xcngn", "0xeurc"]}
  # v2's pool: cash only, no reserve, its own keys; the same $1 dust, $250 page and 75-minute stuck page as v1's.
  assert v2_pool_conditions("v2", 37, -1_000, open_=False) == ([], [])
  assert v2_pool_conditions("v2", 37, -1.0, open_=True, negative_for_sec=999_999) == ([], [])
  pages, warns = v2_pool_conditions("v2", 37, -5, open_=True)
  assert pages == [] and "#37 is $5.00 below zero in cash" in warns[0]
  pages, warns = v2_pool_conditions("v2", 37, -300, open_=True, negative_for_sec=75 * 60)
  assert [p.key for p in pages] == ["future-pool-borrowing-v2", "future-pool-deficit-stuck-v2"] and warns == []
  # each engine's timer is its own, apart from v1's
  st2: dict = {"futurePoolNegativeSince": 1}
  assert pool_negative_for(st2, True, -5, 1_000, "futurePoolNegativeSince:0xv2") == 0
  assert pool_negative_for(st2, True, -5, 1_600, "futurePoolNegativeSince:0xv2") == 600 and st2["futurePoolNegativeSince"] == 1
  # v2's keeper pages under its own keys
  assert keeper_condition(None, now, True, "MarginEngine v2", "keeper-unhealthy-v2").key == "keeper-unhealthy-v2"
  assert keeper_condition(None, now, False, "MarginEngine v2", "keeper-unhealthy-v2") is None
  assert insolvent_condition({"insolventAccounts": ["40"]}, "MarginEngine v2", "insolvent-account-v2").key == "insolvent-account-v2"
  # The perp is wound down: any open interest on it pages, rounding does not.
  assert perp_oi_condition(0.4) is None and perp_oi_condition(801).key == "perp-oi"
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
  # A deficit is expected between a winner and its loser settling; one that outlasts the keeper's cover
  # (75 min) pages at any size, and not while closed.
  assert future_pool_conditions(0, -5, 0, open_=True, negative_for_sec=74 * 60)[0] == []
  pages, warns = future_pool_conditions(0, -5, 0, open_=True, negative_for_sec=75 * 60)
  assert [p.key for p in pages] == ["future-pool-deficit-stuck"] and "75 min" in pages[0].message and "$5.00 below zero" in warns[0]
  assert [p.key for p in future_pool_conditions(0, -300, 0, open_=True, negative_for_sec=80 * 60)[0]] == \
    ["future-pool-borrowing", "future-pool-deficit-stuck"]
  assert future_pool_conditions(0, 0, 0, open_=True, negative_for_sec=999_999)[0] == [], "only while below zero"
  assert future_pool_conditions(0, -5, 0, open_=False, negative_for_sec=999_999) == ([], [])
  # The net counts the pool's cNGN at the index: -$7 in cash covered by 10,000 cNGN at 0.0007 is no deficit,
  # and the same cNGN after the naira falls 30% (0.00049) leaves $2.10 uncovered.
  assert abs(pool_net_usd(10_000, -7, 0.0007)) < 1e-9
  # within $1 is covered: no warning, no page, no timer
  assert future_pool_conditions(0, -1.0, 0, open_=True, negative_for_sec=999_999) == ([], [])
  assert pool_negative_for({}, True, -1.0, 1_000) == 0
  assert future_pool_conditions(10_000, pool_net_usd(10_000, -7, 0.0007), 0, open_=True) == ([], [])
  assert abs(pool_net_usd(10_000, -7, 0.00049) + 2.1) < 1e-9
  assert "$2.10 below zero, net" in future_pool_conditions(10_000, pool_net_usd(10_000, -7, 0.00049), 0, open_=True)[1][0]
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
                              (SEL_FUTURE_MARGIN_REQUIREMENTS, "futureMarginRequirements(uint256)"),
                              (SEL_FUTURE_CONTRACTS, "futureContracts(uint256)")]:
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
