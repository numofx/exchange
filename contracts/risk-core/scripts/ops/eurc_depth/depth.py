#!/usr/bin/env python3
"""EURC/USDC depth on Base within 2%, sampled into a CSV to size the EURC deposit cap on evidence.

The cap was set on 2026-10-24 at 50% of the LATEST 2% sell depth (50,000 EURC from 112,052), not 50% of the median the
first plan used: over the first 7 readings depth fell 590k -> 112k, and a falling market makes the median overstate
today. The engine keeper's MAX_EURC_INVENTORY stays at or below the cap. Sell depth is what a liquidator unwinding EURC
meets. --summary prints both, so a later change to the cap can be read off the same data.

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
import os
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pools as P  # noqa: E402

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
              "main_pool_largest_lp_share", "main_pool_unattributed_share", "lp_check"])


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
  return row


# --- the CSV and the window ---------------------------------------------------------------------

def read_rows(path: Path) -> list[dict]:
  if not path.exists():
    return []
  with path.open() as f:
    reader = csv.DictReader(f)
    if reader.fieldnames != COLUMNS:
      raise SystemExit(f"REFUSED: {path} has other columns; start a new file rather than mix readings")
    return list(reader)


def window_closed(rows: list[dict], now: float, days: float = WINDOW_DAYS) -> bool:
  if not rows:
    return False
  first = datetime.strptime(rows[0]["timestamp_utc"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
  return now - first >= days * 86400


def append(path: Path, row: dict) -> None:
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
  return {"readings": len(sells), "first": rows[0]["timestamp_utc"], "last": rows[-1]["timestamp_utc"],
          "median_sell_eurc": round(median), "min_sell_eurc": round(min(sells)), "max_sell_eurc": round(max(sells)),
          "latest_sell_eurc": round(sells[-1]),
          "cap_at_50pct_of_median_eurc": round(median * CAP_FRACTION),
          "cap_at_50pct_of_latest_eurc": round(sells[-1] * CAP_FRACTION)}


def once() -> int:
  rows = read_rows(CSV_PATH)
  if window_closed(rows, time.time()):
    print(f"window complete: {len(rows)} readings since {rows[0]['timestamp_utc']} ({WINDOW_DAYS:g} days); nothing "
          "sampled. Disable the timer (systemctl disable --now numo-eurc-depth.timer) and run --summary.")
    return 0
  rpc = P.rpc_from_env()
  block = rpc.head() - 2  # a couple behind the head, so every node behind the RPC has it
  row = reading(rpc, block)
  append(CSV_PATH, row)
  print(f"block {block}: sell {row['total_sell_eurc']:,} EURC, buy {row['total_buy_usdc']:,} USDC within 2%; "
        f"main pool LPs {row.get('main_pool_staked_lps', '-')} staked, largest {row.get('main_pool_largest_lp_share', '-')}, "
        f"unattributed {row.get('main_pool_unattributed_share', '-')} ({row['lp_check']}) -> {CSV_PATH}")
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
                    ("positions(uint256)", "99fbab88"), ("stakedLiquidity()", "3ab04b20")]:
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
  print("self-test ok: selectors, ABI, the 2% search (curve and cliff), the gauge scan (refused ranges, rate limits, "
        "resume), LP concentration and its stakedLiquidity check, the 7-day window and the CSV")
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
