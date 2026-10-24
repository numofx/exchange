#!/usr/bin/env python3
"""EURC/USDC depth on Base within 2%, sampled into a CSV to size the EURC deposit cap on evidence.

The cap was set on 2026-10-24 at 50% of the LATEST 2% sell depth (50,000 EURC from 112,052), not 50% of the median the
first plan used: over the first 7 readings depth fell 590k -> 112k, and a falling market makes the median overstate
today. (Fell overall, not at every reading: 205k -> 264k between the third and the fourth.) The engine keeper's
MAX_EURC_INVENTORY stays at or below the cap. Sell depth is what a liquidator unwinding EURC meets. --summary prints
both, so a later change to the cap can be read off the same data.

The stress check, which gates the EURC enable (propose_eurc_spot_batch.py --batch enable takes a reading of its own):
50% of the 2% sell depth WITHOUT the main pool's largest LP must be at least the cap. That depth is simulated, not
scaled by the LP's share: the main pool's ticks are read, the largest LP's staked positions taken out of them, and the
swap run locally (pools.cl_swap_out). The same simulation with nothing removed must reproduce the pool's quoter first,
or the reading says why (sim_check) and the check is `unknown`, which holds the enable like a failure. Only the LP's
staked positions are known; any unstaked liquidity of theirs, and their positions in other pools, stay in. The
largest LP's share is still reported, as context, not as a gate.

Each reading compares the check with the last state it delivered and alerts ALERT_WEBHOOK_URL (run-with-ssm-readonly.sh
supplies it) on any change, either way, and on the first evaluation. An undelivered alert exits 1 and is retried at the
next reading: `stress_alerted` only moves when the webhook accepted it.

Depth at 2%, per pool and direction: the input size whose MARGINAL execution price (fee included) is 2% worse than a
$10 trade's in the same pool and direction, marginal = (out(1.002x) - out(x)) / 0.002x, found by doubling then
bisection against each venue's own quoter. Splitting an order until every pool's marginal is 2% worse is how an
optimal router fills it, so the per-pool sum is that router's depth, not just an upper bound. Every quote in a reading
is at one block.
  sell: EURC in, USDC out, in EURC        buy: USDC in, EURC out, in USDC

On 2026-10-21 (block 52894906) the sell side ended in a cliff, not a slope: the main pool's USDC is reachable within
~0.35% average slippage and then runs out, so the 2% sell depth is close to the USDC sitting in the pools.

  python3 scripts/ops/eurc_depth/depth.py --once       one reading, one CSV row (refuses after the 7-day window)
  python3 scripts/ops/eurc_depth/depth.py --summary    median / min / max of the readings and the cap it implies
  python3 scripts/ops/eurc_depth/depth.py --self-test

Env: RPC_URL (on the box, run-with-ssm-readonly.sh supplies the provider endpoint; the public one rate-limits a
reading's ~1,000 calls), EURC_DEPTH_CSV, EURC_DEPTH_STATE (the gauge scan's progress), EURC_DEPTH_DAYS (default 7).
Scheduled by numo-eurc-depth.{service,timer} at 00:00 and 12:00 UTC.
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import statistics
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pools as P  # noqa: E402
from propose_eurc_spot_batch import MAX_CAP  # noqa: E402  the cap the configure batch sets (and the most it may)

DEVIATION = 0.02
REF_IN = 10_000_000  # $10 / 10 EURC, 6dp
MAX_IN = 10**14  # 100M tokens: past this the doubling stops
CSV_PATH = Path(os.environ.get("EURC_DEPTH_CSV", str(Path.home() / "numo-eurc-depth.csv")))
STATE_PATH = Path(os.environ.get("EURC_DEPTH_STATE", str(Path.home() / "numo-eurc-depth-state.json")))
WINDOW_DAYS = float(os.environ.get("EURC_DEPTH_DAYS", "7"))
CAP_FRACTION = 0.5

COLUMNS = (["timestamp_utc", "block", "block_time_utc"]
           + [f"{name}_{side}" for name, *_ in P.POOLS for side in ("sell_eurc", "buy_usdc")]
           + ["total_sell_eurc", "total_buy_usdc", "other_pools_usdc",
              "main_pool_staked_lps", "main_pool_staked_lps_in_range", "main_pool_largest_lp",
              "main_pool_largest_lp_share", "main_pool_unattributed_share", "lp_check",
              # appended 2026-10-24: older files are rewritten with these columns empty (read_rows, append)
              "main_pool_sell_eurc_ex_largest_lp", "total_sell_eurc_ex_largest_lp", "sim_check", "stress",
              "stress_alerted"])
STRESS_STATES = ("pass", "hold", "unknown")


# --- quoters: quote(token_in, amount_in_6dp) -> amount_out_6dp, 0 when the pool cannot fill ------

def quoter(rpc: P.Rpc, kind: str, param, block: int):
  def out_of(tin: str, amount: int) -> int:
    tout = P.USDC if tin == P.EURC else P.EURC
    if kind == "uni3":
      data = P.calldata("quoteExactInputSingle((address,address,uint256,uint24,uint160))", (tin, tout, amount, param, 0))
      return P.words(rpc.call(P.UNI3_QUOTER, data, block))[0]
    if kind == "cl":
      data = P.calldata("quoteExactInputSingle((address,address,uint256,int24,uint160))", (tin, tout, amount, param, 0))
      return P.words(rpc.call(P.CL_QUOTER, data, block))[0]
    if kind == "uni4":
      fee, spacing = param
      c0, c1 = sorted([P.EURC, P.USDC], key=lambda a: int(a, 16))
      data = P.calldata("quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))",
                        ((c0, c1, fee, spacing, P.ZERO), tin == c0, amount, "0x"))
      return P.words(rpc.call(P.UNI4_QUOTER, data, block))[0]
    if kind == "aero":
      data = P.calldata("getAmountsOut(uint256,(address,address,bool,address)[])", amount,
                        [(tin, tout, param, P.AERO_FACTORY)])
      w = P.words(rpc.call(P.AERO_ROUTER, data, block))
      return w[2 + w[1] - 1]  # uint256[]: offset, length, then the amounts; the last is the output
    raise ValueError(kind)

  def safe(tin: str, amount: int) -> int:
    try:
      return out_of(tin, amount)
    except P.RpcError:
      return 0  # a quoter reverts when the pool cannot fill: no depth at this size
  return safe


def depth_at(quote, tin: str, deviation: float = DEVIATION) -> float:
  """Largest input (whole tokens) whose marginal price is within `deviation` of a $10 trade's."""
  ref = quote(tin, REF_IN) / REF_IN
  if ref == 0:
    return 0.0
  floor = ref * (1 - deviation)

  def ok(x: int) -> bool:
    a, b = quote(tin, x), quote(tin, int(x * 1.002))
    return a > 0 and b > a and (b - a) / (int(x * 1.002) - x) >= floor

  lo = hi = REF_IN
  while ok(hi) and hi < MAX_IN:
    lo, hi = hi, hi * 2
  if lo == hi:
    return 0.0
  for _ in range(18):
    mid = (lo + hi) // 2
    lo, hi = (mid, hi) if ok(mid) else (lo, mid)
  return lo / 1e6


def reading(rpc: P.Rpc, block: int) -> dict:
  def pool_row(pool):
    name, kind, param, _ = pool
    q = quoter(rpc, kind, param, block)
    return name, depth_at(q, P.EURC), depth_at(q, P.USDC)

  with ThreadPoolExecutor(max_workers=len(P.POOLS)) as ex:
    rows = list(ex.map(pool_row, P.POOLS))
  row = {"timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "block": block,
         "block_time_utc": datetime.fromtimestamp(rpc.block_time(block), timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
  for name, sell, buy in rows:
    row[f"{name}_sell_eurc"], row[f"{name}_buy_usdc"] = round(sell), round(buy)
  row["total_sell_eurc"] = round(sum(r[1] for r in rows))
  row["total_buy_usdc"] = round(sum(r[2] for r in rows))
  row["other_pools_usdc"] = round(P.other_pools_usdc(rpc, block))
  try:
    row.update(P.main_pool_lps(rpc, block, STATE_PATH))
  except (P.RpcError, KeyError, ValueError) as error:  # depth still lands; the LP columns say why they are empty
    row["lp_check"] = f"unreadable: {error}"[:200]
  positions = row.pop("_largest_lp_positions", None)
  if positions is None:
    row["sim_check"] = f"no largest LP: lp_check {row['lp_check']}"[:200]
    return row
  try:
    row.update(ex_largest_lp(rpc, block, row, positions))
  except (P.RpcError, KeyError, ValueError) as error:
    row["sim_check"] = f"unreadable: {error}"[:200]
  return row


def ex_largest_lp(rpc: P.Rpc, block: int, row: dict, positions: list[tuple[int, int, int]]) -> dict:
  """The main pool's 2% sell depth with the largest LP's staked positions withdrawn, and the total with it."""
  name, kind, spacing, pool = P.POOLS[0]
  state = P.cl_state(rpc, pool, block)
  real = quoter(rpc, kind, spacing, block)
  for x in sorted({REF_IN, max(REF_IN, int(row[f"{name}_sell_eurc"] * 10**6))}):
    want, got = real(P.EURC, x), P.cl_swap_out(state, True, x)
    if abs(want - got) > max(1, want // 10**6):
      return {"sim_check": f"local swap {got} != quoter {want} selling {x / 1e6:,.0f} EURC"}
  net, liquidity = P.without_positions(state, positions)
  main = round(depth_at(lambda tin, x: P.cl_swap_out(state, tin == P.EURC, x, net, liquidity), P.EURC))
  return {"sim_check": "ok", "main_pool_sell_eurc_ex_largest_lp": main,
          "total_sell_eurc_ex_largest_lp": row["total_sell_eurc"] - row[f"{name}_sell_eurc"] + main}


# --- the stress check and its alert ---------------------------------------------------------------

def stress(row: dict, cap_eurc: float) -> tuple[str, str]:
  """(pass | hold | unknown, why). 50% of the 2% sell depth without the main pool's largest LP against the cap."""
  ex = row.get("total_sell_eurc_ex_largest_lp")
  if ex in (None, ""):
    return "unknown", f"no depth without the largest LP ({row.get('sim_check') or 'not computed'})"
  half = float(ex) * CAP_FRACTION
  verdict = "pass" if half >= cap_eurc else "hold"
  return verdict, (f"50% of the 2% sell depth without the main pool's largest LP is {half:,.0f} EURC, "
                   f"{'at least' if verdict == 'pass' else 'below'} the {cap_eurc:,.0f} EURC cap")


def share_context(row: dict) -> str:
  share = row.get("main_pool_largest_lp_share")
  return f"largest LP {float(share):.1%} of the main pool's in-range liquidity (context, not a gate)" if share not in (
    None, "") else "largest LP share unknown"


def post_webhook(text: str) -> bool:
  webhook = os.environ.get("ALERT_WEBHOOK_URL")
  if not webhook:
    print("ALERT_WEBHOOK_URL is unset: this alert reached nobody", file=sys.stderr)
    return False
  body = json.dumps({"text": text, "content": text}).encode()
  try:
    urllib.request.urlopen(urllib.request.Request(webhook, data=body, headers={"Content-Type": "application/json"}),
                           timeout=15).read()
  except Exception as exc:  # noqa: BLE001
    print(f"webhook delivery failed: {exc}", file=sys.stderr)
    return False
  return True


def judge(rows: list[dict], row: dict, cap_eurc: float, post=post_webhook) -> bool:
  """Fill `stress` and `stress_alerted` for this reading, alerting on a change from the last delivered state.
  False only when an alert was due and did not go out."""
  delivered = next((r["stress_alerted"] for r in reversed(rows) if r.get("stress_alerted")), "")
  verdict, why = stress(row, cap_eurc)
  row["stress"], row["stress_alerted"] = verdict, delivered
  if verdict == delivered:
    return True
  was = delivered or "first evaluation"
  text = (f"[eurc-depth] EURC enable stress check: {was} -> {verdict.upper()}. {why}. {share_context(row)}. "
          f"Block {row['block']}; {'the enable may proceed' if verdict == 'pass' else 'the enable is held'}.")
  if not post(text):
    return False
  row["stress_alerted"] = verdict
  return True


# --- the CSV and the window ---------------------------------------------------------------------

def read_rows(path: Path) -> list[dict]:
  if not path.exists():
    return []
  with path.open() as f:
    reader = csv.DictReader(f)
    names = reader.fieldnames or []
    if names != COLUMNS[:len(names)] or len(names) < COLUMNS.index("lp_check") + 1:
      raise SystemExit(f"REFUSED: {path} has other columns; start a new file rather than mix readings")
    return [{c: r.get(c) or "" for c in COLUMNS} for r in reader]  # a file from before the stress columns: empty


def window_closed(rows: list[dict], now: float, days: float = WINDOW_DAYS) -> bool:
  if not rows:
    return False
  first = datetime.strptime(rows[0]["timestamp_utc"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
  return now - first >= days * 86400


def append(path: Path, row: dict) -> None:
  if path.exists():
    with path.open() as f:
      header = next(csv.reader(f), None)
    if header != COLUMNS:  # older columns (read_rows refuses anything else): rewrite with the new header, atomically
      rows = read_rows(path)
      tmp = path.with_suffix(".tmp")
      with tmp.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)
      tmp.replace(path)
  new = not path.exists()
  with path.open("a", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=COLUMNS)
    if new:
      writer.writeheader()
    writer.writerow({c: row.get(c, "") for c in COLUMNS})


def summary(rows: list[dict]) -> dict:
  sells = [float(r["total_sell_eurc"]) for r in rows if r["total_sell_eurc"]]
  if not sells:
    return {"readings": 0}
  median = statistics.median(sells)
  latest = rows[-1]
  verdict, why = stress(latest, MAX_CAP / 1e18)
  return {"readings": len(sells), "first": rows[0]["timestamp_utc"], "last": latest["timestamp_utc"],
          "median_sell_eurc": round(median), "min_sell_eurc": round(min(sells)), "max_sell_eurc": round(max(sells)),
          "latest_sell_eurc": round(sells[-1]),
          "cap_at_50pct_of_median_eurc": round(median * CAP_FRACTION),
          "cap_at_50pct_of_latest_eurc": round(sells[-1] * CAP_FRACTION),
          "latest_sell_eurc_ex_largest_lp": latest["total_sell_eurc_ex_largest_lp"] or "-",
          "latest_stress": f"{verdict}: {why}",
          "latest_largest_lp_share": f"{latest['main_pool_largest_lp_share'] or '-'} (context, not a gate)"}


def once() -> int:
  rows = read_rows(CSV_PATH)
  if window_closed(rows, time.time()):
    print(f"window complete: {len(rows)} readings since {rows[0]['timestamp_utc']} ({WINDOW_DAYS:g} days); nothing "
          "sampled. Disable the timer (systemctl disable --now numo-eurc-depth.timer) and run --summary.")
    return 0
  rpc = P.rpc_from_env()
  block = rpc.head() - 2  # a couple behind the head, so every node behind the RPC has it
  row = reading(rpc, block)
  alerted = judge(rows, row, MAX_CAP / 1e18)
  append(CSV_PATH, row)
  print(f"block {block}: sell {row['total_sell_eurc']:,} EURC, buy {row['total_buy_usdc']:,} USDC within 2%; "
        f"main pool LPs {row.get('main_pool_staked_lps', '-')} staked, largest {row.get('main_pool_largest_lp_share', '-')}, "
        f"unattributed {row.get('main_pool_unattributed_share', '-')} ({row['lp_check']}); "
        f"without the largest LP {row.get('total_sell_eurc_ex_largest_lp') or '-'} ({row.get('sim_check')}); "
        f"stress {row['stress']} -> {CSV_PATH}")
  if not alerted:
    print(f"the stress check is {row['stress']} but the alert did not go out; retried at the next reading", file=sys.stderr)
    return 1
  return 0


# --- self-test ----------------------------------------------------------------------------------

def self_test() -> int:
  sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
  from abi_selectors import assert_script  # every signature here is an external contract: NOT_COMPILED, with reasons
  assert_script(__file__)
  assert_script(P.__file__)
  import tempfile

  # Selectors as `cast sig` gives them (derived 2026-10-21; two hand-written ones were wrong before that check).
  for sig, want in [("quoteExactInputSingle((address,address,uint256,uint24,uint160))", "c6a5026a"),
                    ("quoteExactInputSingle((address,address,uint256,int24,uint160))", "9e7defe6"),
                    ("aggregate3((address,bool,bytes)[])", "82ad56cb"), ("balanceOf(address)", "70a08231"),
                    ("positions(uint256)", "99fbab88"), ("stakedLiquidity()", "3ab04b20"),
                    ("ticks(int24)", "f30dba93"), ("tickBitmap(int16)", "5339c296"), ("fee()", "ddca3f43"),
                    ("tickSpacing()", "d0c93a7c")]:
    assert P.selector(sig) == want, (sig, P.selector(sig))
  assert P.DEPOSIT_TOPIC == "0x1c8ab8c7f45390d58f58f1d655213a82cca5d12179761a87c16f098813b8f211"
  # ABI: a static tuple inline, bytes and arrays in the tail.
  assert P.encode(["(address,uint24)"], [(P.ZERO, 500)]) == "0" * 64 + f"{500:064x}"
  assert P.encode(["bytes"], ["0x"]) == f"{32:064x}" + "0" * 64
  assert P.encode(["uint256[]"], [[1, 2]]) == f"{32:064x}{2:064x}{1:064x}{2:064x}"
  assert P.signed(2**24 - 1, 24) == -1 and P.signed(5, 24) == 5

  # The 2% search, on a constant-product pool of 1M a side with a 5 bps fee: marginal price
  # (1 - fee) R^2 / (R + x)^2 is 2% worse than the start at x = R (1/sqrt(0.98) - 1) = 10,153.
  R = 1_000_000 * 10**6
  q = lambda tin, x: int(x * 0.9995 * R / (R + x * 0.9995))  # noqa: E731
  got = depth_at(q, P.EURC)
  assert abs(got - 10_153) < 15, got
  assert depth_at(lambda tin, x: 0, P.EURC) == 0.0, "a pool that cannot fill has no depth"
  # A cliff, as the main pool showed: full price up to 400k, nothing past it. The marginal is measured over
  # [x, 1.002x], so a probe straddling the cliff reads as past it: depth resolves to within 0.2% below the cliff.
  cliff = lambda tin, x: x if x <= 400_000 * 10**6 else 400_000 * 10**6  # noqa: E731
  assert 400_000 / 1.002 - 1 <= depth_at(cliff, P.EURC) <= 400_000, depth_at(cliff, P.EURC)

  # LP concentration: two LPs staked, one out of range; checked against the pool's own staked liquidity.
  staked = {"1": "0xaaa", "2": "0xaaa", "3": "0xbbb", "4": "0xccc"}
  positions = {"1": (-100, 100, 60), "2": (200, 300, 40), "3": (-50, 50, 30), "4": (-10, 10, 0)}
  ok = P.concentration(staked, positions, 0, pool_liquidity=100, pool_staked=90)
  assert ok == {"lp_check": "ok", "main_pool_staked_lps": 2, "main_pool_staked_lps_in_range": 2, "main_pool_largest_lp": "0xaaa",
                "main_pool_largest_lp_share": 0.6, "main_pool_unattributed_share": 0.1}, ok
  missed = P.concentration(staked, positions, 0, pool_liquidity=100, pool_staked=95)
  assert missed["lp_check"].startswith("staked in range 90 != pool stakedLiquidity 95"), missed
  assert "main_pool_largest_lp_share" not in missed, "a reading that missed an event must not report a share"

  # The gauge scan: a fake endpoint that refuses ranges over 3,000 blocks and serves three logs. Deposit 7 then 8,
  # withdraw 7: only 8 stays staked. A rate limit mid-scan keeps the span, and the saved state resumes.
  def log(topic, user, token_id, block):
    return {"topics": [topic, "0x" + user.removeprefix("0x").rjust(64, "0"), hex(token_id), hex(1)],
            "blockNumber": hex(block), "logIndex": "0x0"}
  logs = [log(P.DEPOSIT_TOPIC, "0xaa", 7, 1_200), log(P.DEPOSIT_TOPIC, "0xbb", 8, 5_000),
          log(P.WITHDRAW_TOPIC, "0xaa", 7, 9_000)]

  class FakeRpc:
    def __init__(self, limit_after=None, no_history=False):
      self.calls, self.limit_after, self.no_history = 0, limit_after, no_history

    def code_at(self, address, block):
      if self.no_history:
        raise P.RpcError("eth_getCode", {"message": "HTTP 403"})
      return block >= 1_000

    def request(self, method, params):
      assert method == "eth_getLogs" and params[0]["topics"] == [[P.DEPOSIT_TOPIC, P.WITHDRAW_TOPIC]]
      self.calls += 1
      if self.limit_after is not None and self.calls > self.limit_after:
        raise P.RateLimited(method, {"message": "429"})
      lo, hi = int(params[0]["fromBlock"], 16), int(params[0]["toBlock"], 16)
      if hi - lo + 1 > 3_000:
        raise P.RpcError(method, {"message": "range too large"})
      return [x for x in logs if lo <= int(x["blockNumber"], 16) <= hi]

  created, P.MAIN_POOL_CREATED_BLOCK = P.MAIN_POOL_CREATED_BLOCK, 0  # the fake chain starts at 0
  saves = []
  state = P.scan_gauge(FakeRpc(), "0xgauge", 10_000, {}, save=lambda s: saves.append(s["scanned_to"]))
  assert state["from_block"] == 1_000 and state["scanned_to"] == 10_000, state
  assert state["staked"] == {"8": "0x" + "bb".rjust(40, "0")}, state["staked"]
  assert saves == sorted(saves) and saves[-1] == 10_000 and len(saves) > 1, "saved after every chunk"
  partial: dict = {}
  try:
    # calls: 10k refused, 5k refused, 2.5k served twice (to 5,999; never 5k again), then the endpoint rate-limits
    P.scan_gauge(FakeRpc(limit_after=4), "0xgauge", 10_000, partial, save=lambda s: None)
  except P.RateLimited:
    pass
  else:
    raise AssertionError("a rate limit must stop the scan, not shrink it")
  stopped_at, span = partial["scanned_to"], partial["span"]
  assert stopped_at == 5_999 and span == 2_500, (stopped_at, span)  # kept its progress, and the span it had found
  P.scan_gauge(FakeRpc(), "0xgauge", 10_000, partial)
  assert partial["staked"] == state["staked"] and partial["scanned_to"] == 10_000, "resumed to the same state"
  counting = FakeRpc()
  P.scan_gauge(counting, "0xgauge", 30_000, {})
  assert counting.calls <= 3 + 11, f"{counting.calls} calls: a refused span must not be retried after each success"
  # An endpoint without historical state cannot find the gauge's first block: the scan starts at the pool's instead.
  P.MAIN_POOL_CREATED_BLOCK = 500
  fallback = P.scan_gauge(FakeRpc(no_history=True), "0xgauge", 10_000, {})
  assert fallback["from_block"] == 500 and fallback["staked"] == state["staked"], fallback
  P.MAIN_POOL_CREATED_BLOCK = created

  # The window and the CSV.
  with tempfile.TemporaryDirectory() as d:
    path = Path(d) / "depth.csv"
    row = {c: "" for c in COLUMNS} | {"timestamp_utc": "2026-10-21T12:00:00Z", "total_sell_eurc": "519000"}
    append(path, row)
    append(path, row | {"timestamp_utc": "2026-10-22T00:00:00Z", "total_sell_eurc": "480000"})
    rows = read_rows(path)
    start = datetime(2026, 10, 21, 12, tzinfo=timezone.utc).timestamp()
    assert not window_closed(rows, start + 7 * 86400 - 1) and window_closed(rows, start + 7 * 86400)
    assert summary(rows)["median_sell_eurc"] == 499500 and summary(rows)["cap_at_50pct_of_median_eurc"] == 249750
    assert summary(rows)["latest_sell_eurc"] == 480000 and summary(rows)["cap_at_50pct_of_latest_eurc"] == 240000
    other = Path(d) / "other.csv"
    other.write_text("timestamp_utc,block\n")
    try:
      read_rows(other)
    except SystemExit as refused:
      assert "other columns" in str(refused)
    else:
      raise AssertionError("mixed columns accepted")
  # The local swap. TickMath's bounds and centre; selling EURC is zeroForOne only while EURC is token0.
  assert P.sqrt_ratio_at_tick(0) == P.Q96
  assert P.sqrt_ratio_at_tick(P.MIN_TICK) == 4295128739
  assert P.sqrt_ratio_at_tick(P.MAX_TICK) == 1461446703485210103287273052203988822378723970342
  assert int(P.EURC, 16) < int(P.USDC, 16), "EURC is token0: cl_swap_out(state, True, ...) sells EURC"
  # One full-range-ish position of L between ticks -500 and 500, at tick 0, no fee: selling x token0 inside the range
  # gives L*(sqrtP - sqrtP') / Q96 with sqrtP' = L*sqrtP*Q96 / (L*Q96 + x*sqrtP), rounded down.
  L = 10**18
  state = {"sqrt_price": P.Q96, "tick": 0, "fee": 0, "liquidity": L, "liquidity_net": {-500: L, 500: -L},
           "window": (-1000, 1000)}
  nxt = -(-(L << 96) * P.Q96 // ((L << 96) + 10**12 * P.Q96))
  assert P.cl_swap_out(state, True, 10**12) == L * (P.Q96 - nxt) // P.Q96
  edge = P.cl_swap_out(state, True, 10**30)
  assert edge == P.cl_swap_out(state, True, 10**31) > 0, "past the last tick the output stays flat"
  # Withdrawing the only position empties the pool; withdrawing half halves what a small trade moves.
  net, liq = P.without_positions(state, [(-500, 500, L)])
  assert liq == 0 and P.cl_swap_out(state, True, 10**12, net, liq) == 0
  net, liq = P.without_positions(state, [(-500, 500, L // 2)])
  assert liq == L // 2 and net == {-500: L // 2, 500: -L // 2}
  assert P.cl_swap_out(state, True, 10**12, net, liq) < P.cl_swap_out(state, True, 10**12)
  try:
    P.without_positions(state, [(-500, 500, 2 * L)])
  except ValueError:
    pass
  else:
    raise AssertionError("withdrawing more than the pool holds must refuse")

  # The stress check: 50% of the depth without the largest LP against the cap; nothing computed holds.
  assert stress({"total_sell_eurc_ex_largest_lp": "100000"}, 50_000)[0] == "pass"
  assert stress({"total_sell_eurc_ex_largest_lp": "99998"}, 50_000)[0] == "hold"
  assert stress({"total_sell_eurc_ex_largest_lp": "", "sim_check": "local swap 1 != quoter 2"}, 50_000) == (
    "unknown", "no depth without the largest LP (local swap 1 != quoter 2)")
  # Its alert: the first evaluation alerts, an unchanged state does not, a flip either way does, and an undelivered
  # alert leaves the last delivered state in place so the next reading retries it.
  sent: list[str] = []
  post = lambda text: sent.append(text) or True  # noqa: E731
  history: list[dict] = [{"stress_alerted": ""}]
  def take(ex, deliver=post):
    row = {"block": 1, "total_sell_eurc_ex_largest_lp": ex, "main_pool_largest_lp_share": "0.5042"}
    ok = judge(history, row, 50_000, post=deliver)
    history.append(row)
    return ok, row
  assert take("81600") == (True, history[-1]) and history[-1]["stress_alerted"] == "hold"
  assert "first evaluation -> HOLD" in sent[-1] and "50.4% of the main pool" in sent[-1] and "held" in sent[-1]
  assert take("82000")[0] and len(sent) == 1, "no change, no alert"
  assert take("120000")[0] and "hold -> PASS" in sent[-1] and "may proceed" in sent[-1]
  ok, row = take("90000", deliver=lambda text: False)
  assert not ok and row["stress"] == "hold" and row["stress_alerted"] == "pass", "undelivered: still pass delivered"
  assert take("90000")[0] and "pass -> HOLD" in sent[-1] and len(sent) == 3, "retried at the next reading"
  assert take("")[0] and "hold -> UNKNOWN" in sent[-1]

  # A CSV from before the stress columns is read with them empty and rewritten with them on the next append.
  with tempfile.TemporaryDirectory() as d:
    old_cols = COLUMNS[:COLUMNS.index("lp_check") + 1]
    path = Path(d) / "old.csv"
    with path.open("w", newline="") as f:
      w = csv.DictWriter(f, fieldnames=old_cols)
      w.writeheader()
      w.writerow({c: "" for c in old_cols} | {"timestamp_utc": "2026-10-21T12:06:00Z", "total_sell_eurc": "590051"})
    assert read_rows(path)[0]["stress_alerted"] == "" and read_rows(path)[0]["total_sell_eurc"] == "590051"
    append(path, {"timestamp_utc": "2026-10-24T12:00:00Z", "total_sell_eurc": "112052", "stress": "hold"})
    assert path.read_text().splitlines()[0] == ",".join(COLUMNS)
    rows = read_rows(path)
    assert [r["total_sell_eurc"] for r in rows] == ["590051", "112052"] and rows[1]["stress"] == "hold"

  print("self-test ok: selectors, ABI, the 2% search (curve and cliff), the gauge scan (refused ranges, rate limits, "
        "resume), LP concentration and its stakedLiquidity check, the local swap and withdrawing an LP, the stress "
        "check and its alert (first, flips both ways, retry), the 7-day window and the CSV (and its migration)")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="EURC/USDC depth within 2% on Base, one CSV row per reading")
  ap.add_argument("--once", action="store_true", help="take one reading and append it")
  ap.add_argument("--summary", action="store_true", help="median / min / max over the readings")
  ap.add_argument("--self-test", action="store_true")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  if args.summary:
    for k, v in summary(read_rows(CSV_PATH)).items():
      print(f"{k:32} {v:,}" if isinstance(v, (int, float)) else f"{k:32} {v}")
    return 0
  if args.once:
    return once()
  ap.print_help()
  return 2


if __name__ == "__main__":
  sys.exit(main())
