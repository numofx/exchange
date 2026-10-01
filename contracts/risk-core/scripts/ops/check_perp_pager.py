#!/usr/bin/env python3
"""Pages the operator's phone for the USDCcNGN-PERP conditions that may need the guardian.

Run every minute (numo-perp-pager.timer). Each condition pages once when it starts, again every
REPAGE_SEC while it lasts, and sends a resolved notice when it clears. Every page is mirrored to the
Slack webhook, so the channel has the same record.

  feed-halt          the index, mark or an impact feed is past its warn age (index 960s of a 1200s
                     heartbeat): a stale index halts trading AND liquidations
  keeper-unhealthy   the keeper's /health is unreachable, in dry run, failing, or stale. Armed once
                     the keeper has reported healthy at least once, or the market is open (cap > 0):
                     before that, a keeper that is not running yet is not a page.
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
OI_KEEPER_WARN_X = 2.0
OI_KEEPER_PAGE_X = 3.0
OI_WARN_REPEAT_SEC = 6 * 3600
# Gas watch. Burn is measured as the balance 24h ago minus now (a top-up in between reads as no
# burn, which then falls back to the floor). Floors are two days at the worst case measured in the
# runbook: relayer 0.0013/day (a mark a minute), executor ~0.00001 per settlement, keeper two full
# liquidation cycles. `GAS_WATCH` overrides: "name=0xaddr:floorEth,...". `KEEPER_EOA` adds the keeper.
BLOCKS_PER_DAY = 43_200  # Base, 2s blocks
GAS_PAGE_DAYS = 2.0
GAS_WARN_DAYS = 7.0
GAS_WARN_REPEAT_SEC = 6 * 3600
DEFAULT_GAS_WATCH = "executor=0xF68ebcC8934B068655E1A4367Ba6C0e564678703:0.002,relayer=0xC9F1FfdEd29f7051538ad3a72729C3d07F920FDc:0.003"
KEEPER_GAS_FLOOR_ETH = 0.005
SEL_GET_BALANCE = "0x0806e640"  # getBalance(uint256,address,uint256) -- `cast sig`, pinned in --self-test


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
  return Condition("feed-halt", f"USDCcNGN-PERP feed halt: {', '.join(late)}. A stale index halts trading and liquidations.")


def keeper_condition(health: dict | None, now: int, armed: bool = True) -> Condition | None:
  """`armed` is False until the keeper has ever reported healthy and the market is still closed:
  a keeper that is not installed yet, or running its DRY_RUN smoke (go-live steps 14-17), is not
  a page. Once the market is open, no keeper at all is the loudest condition there is."""
  if not armed:
    return None
  if health is None:
    return Condition("keeper-unhealthy", "USDCcNGN-PERP keeper /health unreachable: nothing is liquidating.")
  if health.get("dryRun", True):
    return Condition("keeper-unhealthy", "USDCcNGN-PERP keeper is in DRY_RUN: it decides but sends nothing.")
  stale_after = 3 * max(int(health.get("pollIntervalMs", 15_000)) // 1000, 20)
  age = now - int(health.get("lastPassAt", 0))
  if not health.get("lastPassOk") or age > stale_after:
    return Condition("keeper-unhealthy", f"USDCcNGN-PERP keeper unhealthy: last pass ok={health.get('lastPassOk')} {age}s ago.")
  return None


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
  return Condition(f"low-gas-{name}", f"USDCcNGN-PERP {name} low on gas: {balance:.5f} ETH, burning {burn_per_day:.5f}/day "
                   f"({runway}); needs {need:.5f}. Top it up before it stops {'settling' if name == 'executor' else 'publishing' if name == 'relayer' else 'liquidating'}.")


def gas_warning(name: str, balance: float, burn_per_day: float) -> str | None:
  """Slack-only, under 7 days of measured burn."""
  if burn_per_day <= 0 or balance / burn_per_day >= GAS_WARN_DAYS:
    return None
  return f"USDCcNGN-PERP {name} gas runway {balance / burn_per_day:.1f} days ({balance:.5f} ETH at {burn_per_day:.5f}/day): top up this week."


def oi_condition(one_side_usd: float, keeper_cash_usd: float) -> Condition | None:
  if keeper_cash_usd <= 0:
    return Condition("oi-vs-keeper", f"USDCcNGN-PERP keeper bid account holds no cash while one side's OI is ${one_side_usd:,.0f}: nothing can take a liquidation.")
  ratio = one_side_usd / keeper_cash_usd
  if ratio < OI_KEEPER_PAGE_X:
    return None
  return Condition("oi-vs-keeper", f"USDCcNGN-PERP one-side OI ${one_side_usd:,.0f} is {ratio:.1f}x the keeper's ${keeper_cash_usd:,.0f} cash "
                   f"(page at {OI_KEEPER_PAGE_X:.0f}x): top the keeper account up, or set cap = current OI.")


def oi_warning(one_side_usd: float, keeper_cash_usd: float) -> str | None:
  """Slack-only, from 2x up to the page."""
  if keeper_cash_usd <= 0 or one_side_usd / keeper_cash_usd < OI_KEEPER_WARN_X or one_side_usd / keeper_cash_usd >= OI_KEEPER_PAGE_X:
    return None
  return f"USDCcNGN-PERP one-side OI ${one_side_usd:,.0f} is {one_side_usd / keeper_cash_usd:.1f}x the keeper's ${keeper_cash_usd:,.0f} cash: top it up before 3x pages."


def read_oi_and_keeper(url: str, stack: dict, keeper_account: int) -> tuple[float, float]:
  """(one side's OI in USD at the index, keeper account cash in USD)."""
  srm_word = stack["srm"].lower().removeprefix("0x").rjust(64, "0")
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
  raw = rpc(url, "eth_call", [{"to": stack["perp"], "data": SEL_TOTAL_POSITION_CAP + stack["srm"].lower().removeprefix("0x").rjust(64, "0")}, "latest"])
  return int(raw, 16) > 0


def insolvent_condition(health: dict | None) -> Condition | None:
  accounts = (health or {}).get("insolventAccounts") or []
  if not accounts:
    return None
  return Condition("insolvent-account", f"USDCcNGN-PERP insolvent account(s) {', '.join(accounts)}: the SecurityModule will pay.")


def peg_condition(status: dict | None, now_wall: float) -> Condition | None:
  """A tripped peg guard in perp-feeds' last sample. A missing or stale status says nothing: a dead
  publisher is the feed-halt page's job."""
  if not status or now_wall - float(status.get("at", 0)) / 1000 > INDEX_STATUS_MAX_AGE_SEC:
    return None
  if not status.get("pegGuardTripped"):
    return None
  peg = status.get("peg") or {}
  return Condition("peg-guard", f"USDCcNGN-PERP index HALTED by the peg guard: cNGN at {peg.get('ngnPerCngn')} NGN, "
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
  return Condition("sm-payout", f"USDCcNGN-PERP SecurityModule paid ${previous - current:,.2f} (now ${current:,.2f}).")


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
  sm_raw = rpc(url, "eth_call", [{"to": SUB_ACCOUNTS, "data": SEL_GET_BALANCE
                                  + f"{int(stack['securityModuleAccount']):064x}"
                                  + stack["cash"].lower().removeprefix("0x").rjust(64, "0") + "0" * 64}, "latest"])
  sm_cash = int(sm_raw, 16) / 1e18

  if keeper_healthy(health, now):
    state["keeperSeenAt"] = now
  armed = state.get("keeperSeenAt") is not None or market_open(url, stack)

  gas = []
  warned = state.setdefault("gasWarnedAt", {})
  for name, address, floor in gas_watch():
    balance, burn = read_gas(url, number, address)
    gas.append(gas_condition(name, balance, burn, floor))
    warning = gas_warning(name, balance, burn)
    if warning and gas[-1] is None and time.time() - warned.get(name, 0) >= GAS_WARN_REPEAT_SEC:
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      warned[name] = time.time()
    print(f"gas {name}: {balance:.5f} ETH, burn {burn:.5f}/day, floor {floor}")

  oi = None
  keeper_account = os.environ.get("KEEPER_ACCOUNT", "").strip()
  if keeper_account:
    one_side_usd, keeper_cash = read_oi_and_keeper(url, stack, int(keeper_account))
    oi = oi_condition(one_side_usd, keeper_cash)
    warning = oi_warning(one_side_usd, keeper_cash)
    if warning and time.time() - state.get("oiWarnedAt", 0) >= OI_WARN_REPEAT_SEC:
      mirror(f"{os.environ.get('PAGE_PREFIX', '')}{warning}")
      state["oiWarnedAt"] = time.time()
    print(f"oi: one side ${one_side_usd:,.0f} vs keeper #{keeper_account} cash ${keeper_cash:,.0f}")
  else:
    print("oi: KEEPER_ACCOUNT unset, not watched")

  previous_sm = state.get("smCash")
  active = [c for c in (feed_condition(ages), keeper_condition(health, now, armed), insolvent_condition(health),
                        sm_condition(previous_sm, sm_cash), unwatched_condition(heartbeat_urls()[0]),
                        peg_condition(read_index_status(), time.time()), oi, *gas) if c is not None]
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
  return Condition("pager-unwatched", "USDCcNGN-PERP pager has no dead-man's switch (PAGER_HEARTBEAT_URL): "
                   "if the pager itself stops, nothing will tell you.")


def self_test() -> int:
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
  # OI against the keeper's cash: warning from 2x, page from 3x, page at any OI with no cash.
  assert oi_condition(9_999, 5_000) is None and oi_warning(9_999, 5_000) is None
  assert "2.2x" in oi_warning(11_000, 5_000) and oi_condition(11_000, 5_000) is None
  assert oi_condition(15_000, 5_000).key == "oi-vs-keeper" and oi_warning(15_000, 5_000) is None
  assert "no cash" in oi_condition(100, 0).message
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
  # Selectors against their signatures, so a hand-typed one cannot ship (one did, in review).
  from resolve_cngn_action6 import keccak
  for selector, signature in [(SEL_GET_BALANCE, "getBalance(uint256,address,uint256)"),
                              (SEL_SPOT_DIFF_DETAILS, "spotDiffDetails()"),
                              (SEL_TOTAL_POSITION_CAP, "totalPositionCap(address)"),
                              (SEL_TOTAL_POSITION, "totalPosition(address)"), (SEL_GET_SPOT, "getSpot()")]:
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
  ap = argparse.ArgumentParser(description="Page the operator for USDCcNGN-PERP conditions")
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
