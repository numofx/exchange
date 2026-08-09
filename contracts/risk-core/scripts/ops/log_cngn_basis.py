#!/usr/bin/env python3
"""cNGN reference-price basis logger for the SEP-16-2026 deliverable FX future.

The mark — and, by default, the Sep-16 settlement price (`delivery_keeper.py --fix`
defaults to on-chain spot) — both trace back to a single free FX API that refreshes
ONCE PER DAY (open.er-api.com). Because the future settles by PHYSICAL delivery of
cNGN, the economically correct fixing is what cNGN actually exchanges for, not a
generic NGN/USD reference. This logger accumulates the evidence needed to decide the
fixing (physical-delivery-runbook.md checklist item 5) before anyone holds a position.
Basis data only accrues with wall-clock time, so it must start early to be useful.

Per tick it appends one CSV row sampling, independently:
  er_api     the rate the live feed publishes from (daily refresh)
  alt_fx     an independent free NGN reference, to size source-choice disagreement
  feed_spot  what the on-chain LyraSpotFeed returns (blank while stale/reverting)
  mark       the on-chain mark on the future, plus its age
  pool       cNGN/USDC AMM depth and price on Base

NOTE ON POOLS: as of 2026-08-02 all three known cNGN/USDC pools on Base hold dust
(<$0.001 combined), so there is NO on-chain market rate to measure a true basis
against — cNGN moves on Base as payments, not swaps. The pool columns exist to catch
the day that changes: if real depth appears it becomes the best available settlement
reference, and `--summary` will surface it. Price is only recorded once depth clears
MIN_DEPTH_USDC, since a rate read off a dust pool is noise.

Every source fails soft — one that errors leaves an empty cell rather than losing the
whole row. This is a data collector, not a monitor: it never alerts and never exits
non-zero on a source outage.

Env (or ~/.numo-mark-keeper.env / ~/.numo-feeds.env):
  RPC_URL     Base RPC (default https://mainnet.base.org)
  BASIS_CSV   output path (default ~/.numo-cngn-basis.csv)

Usage:
  python3 scripts/ops/log_cngn_basis.py --once       # one sample, for cron/timer
  python3 scripts/ops/log_cngn_basis.py              # loop every INTERVAL_SEC
  python3 scripts/ops/log_cngn_basis.py --summary    # divergence report from the CSV
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from mark_keeper import artifact, get_series, get_spot, load_env_file, run  # noqa: E402

INTERVAL_SEC = 30 * 60
HTTP_TIMEOUT = 20
USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
CNGN = "0x46C85152bFe9f96829aA94755D9f915F9B10EF5F"

ER_API_URL = "https://open.er-api.com/v6/latest/USD"
ALT_FX_URL = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/usd.json"

# cNGN/USDC venues found on Base. Uniswap V3 prices come from slot0 (concentrated
# liquidity means balances are depth, NOT price); Aerodrome is a constant-product pool
# where the reserve ratio IS the price.
POOLS = [
  ("univ3-100", "0x90b443C9D27629a170c11B04f90b15B99331EE97", "v3"),
  ("univ3-500", "0x633059aa17C751D6328149ba3fc7c63d528218Bc", "v3"),
  ("aero-vol", "0xdf23B29110Db8Afb0BCDab82dC5eE820c7F35AdC", "cp"),
]
MIN_DEPTH_USDC = 100.0  # below this a quoted rate is noise, not a market

COLUMNS = [
  "ts_unix", "ts_utc", "er_api", "er_api_age_s", "alt_fx", "feed_spot", "mark",
  "mark_age_s", "er_vs_alt_bps", "feed_vs_er_bps", "mark_vs_feed_bps",
  "pool_depth_usdc", "pool_rate", "pool_vs_er_bps",
]


def fetch_json(url: str) -> dict:
  req = urllib.request.Request(url, headers={"User-Agent": "numo-basis-logger/1.0"})
  return json.loads(urllib.request.urlopen(req, timeout=HTTP_TIMEOUT).read())


def bps(a: float | None, b: float | None) -> float | None:
  """Signed deviation of a from b, in basis points."""
  if a is None or b is None or not b:
    return None
  return round((a - b) / b * 10_000, 1)


def er_api_rate() -> tuple[float | None, int | None]:
  """The live feed's own source. Returns (rate, seconds since it last refreshed)."""
  d = fetch_json(ER_API_URL)
  age = int(time.time()) - int(d["time_last_update_unix"])
  return float(d["rates"]["NGN"]), age


def alt_fx_rate() -> float:
  """Independent free NGN reference — sizes how much the source choice alone matters."""
  return float(fetch_json(ALT_FX_URL)["usd"]["ngn"])


def feed_spot(rpc: str, feed: str) -> float | None:
  """On-chain spot, or None while the feed is stale (getSpot reverts BLF_DataTooOld)."""
  try:
    return get_spot(rpc, feed) / 1e18
  except Exception:
    return None


def erc20_balance(rpc: str, token: str, holder: str) -> float:
  out = run(["cast", "call", token, "balanceOf(address)(uint256)", holder, "--rpc-url", rpc])
  return int(out.split()[0].replace(",", "")) / 1e6  # cNGN and USDC are both 6dp


def pool_price(rpc: str, addr: str, kind: str, cngn: float, usdc: float) -> float | None:
  """cNGN per USDC for one venue, or None if the venue is too thin to quote."""
  if usdc < MIN_DEPTH_USDC:
    return None
  if kind == "cp":
    return cngn / usdc
  # Uniswap V3: token0 is cNGN (0x46C8... < 0x8335...), so slot0 gives USDC per cNGN.
  out = run(["cast", "call", addr, "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)",
             "--rpc-url", rpc])
  sqrt_price = int(out.split()[0].replace(",", ""))
  usdc_per_cngn = (sqrt_price / (2 ** 96)) ** 2
  return 1 / usdc_per_cngn if usdc_per_cngn else None


def deepest_pool(rpc: str) -> tuple[float, float | None]:
  """Depth and price of the deepest cNGN/USDC venue. Depth is what makes a rate real."""
  best_depth, best_rate = 0.0, None
  for _, addr, kind in POOLS:
    try:
      usdc = erc20_balance(rpc, USDC, addr)
      cngn = erc20_balance(rpc, CNGN, addr)
      if usdc > best_depth:
        best_depth, best_rate = usdc, pool_price(rpc, addr, kind, cngn, usdc)
    except Exception:
      continue
  return round(best_depth, 4), best_rate


def sample(rpc: str) -> dict:
  now = int(time.time())
  row = {c: "" for c in COLUMNS}
  row["ts_unix"] = now
  row["ts_utc"] = datetime.fromtimestamp(now, timezone.utc).isoformat()

  er, alt = None, None
  try:
    er, age = er_api_rate()
    row["er_api"], row["er_api_age_s"] = round(er, 6), age
  except Exception as exc:
    print(f"er_api failed: {exc}", file=sys.stderr)
  try:
    alt = alt_fx_rate()
    row["alt_fx"] = round(alt, 6)
  except Exception as exc:
    print(f"alt_fx failed: {exc}", file=sys.stderr)

  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  spot = feed_spot(rpc, fut["spotFeed"])
  if spot is not None:
    row["feed_spot"] = round(spot, 6)

  mark = None
  try:
    series = get_series(rpc, fut["future"], str(fut["subId"]))
    mark = series["markPrice"] / 1e18
    row["mark"], row["mark_age_s"] = round(mark, 6), now - series["lastMarkTime"]
  except Exception as exc:
    print(f"mark read failed: {exc}", file=sys.stderr)

  depth, pool_rate = deepest_pool(rpc)
  row["pool_depth_usdc"] = depth
  if pool_rate is not None:
    row["pool_rate"] = round(pool_rate, 6)
    row["pool_vs_er_bps"] = bps(pool_rate, er)

  row["er_vs_alt_bps"] = bps(er, alt)
  row["feed_vs_er_bps"] = bps(spot, er)
  row["mark_vs_feed_bps"] = bps(mark, spot)
  return {k: ("" if v is None else v) for k, v in row.items()}


def append_row(path: Path, row: dict) -> None:
  new = not path.exists()
  path.parent.mkdir(parents=True, exist_ok=True)
  with path.open("a", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=COLUMNS)
    if new:
      w.writeheader()
    w.writerow(row)


def summarize(path: Path) -> int:
  if not path.exists():
    print(f"no samples yet at {path}", file=sys.stderr)
    return 1
  rows = list(csv.DictReader(path.open()))
  if not rows:
    print("csv is empty", file=sys.stderr)
    return 1
  span_h = (int(rows[-1]["ts_unix"]) - int(rows[0]["ts_unix"])) / 3600
  print(f"{len(rows)} samples over {span_h:.1f}h ({rows[0]['ts_utc']} -> {rows[-1]['ts_utc']})\n")

  for col, label in [("er_vs_alt_bps", "er_api vs alt_fx  (source choice)"),
                     ("feed_vs_er_bps", "on-chain feed vs er_api"),
                     ("mark_vs_feed_bps", "mark vs feed"),
                     ("pool_vs_er_bps", "DEX pool vs er_api  (TRUE BASIS)")]:
    vals = [float(r[col]) for r in rows if r.get(col)]
    if not vals:
      print(f"  {label:38s} no data")
      continue
    mean = sum(vals) / len(vals)
    print(f"  {label:38s} n={len(vals):4d}  mean {mean:+7.1f}bps  "
          f"min {min(vals):+7.1f}  max {max(vals):+7.1f}")

  depths = [float(r["pool_depth_usdc"]) for r in rows if r.get("pool_depth_usdc")]
  if depths:
    print(f"\n  deepest cNGN/USDC pool seen: ${max(depths):,.2f} "
          f"(need >${MIN_DEPTH_USDC:,.0f} before a pool rate is quotable)")
  if not any(r.get("pool_vs_er_bps") for r in rows):
    print("\n  NO on-chain cNGN market yet -> the Sep-16 fixing cannot be sourced from a\n"
          "  DEX. Decide between er_api, alt_fx, or an off-chain/OTC reference.")
  return 0


def main() -> int:
  load_env_file(Path.home() / ".numo-mark-keeper.env")
  load_env_file(Path.home() / ".numo-feeds.env")
  ap = argparse.ArgumentParser()
  ap.add_argument("--once", action="store_true", help="sample once and exit (cron/timer)")
  ap.add_argument("--summary", action="store_true", help="report divergence from the CSV")
  args = ap.parse_args()

  path = Path(os.environ.get("BASIS_CSV", Path.home() / ".numo-cngn-basis.csv"))
  if args.summary:
    return summarize(path)

  rpc = os.environ.get("RPC_URL", "https://mainnet.base.org")
  while True:
    started = time.time()
    try:
      row = sample(rpc)
      append_row(path, row)
      print(f"{row['ts_utc']} er_api={row['er_api']} alt_fx={row['alt_fx']} "
            f"feed={row['feed_spot'] or 'STALE'} mark={row['mark']} "
            f"er_vs_alt={row['er_vs_alt_bps']}bps pool_depth=${row['pool_depth_usdc']}")
    except Exception as exc:  # never let one bad tick kill a long-running collector
      print(f"sample failed: {exc}", file=sys.stderr)
    if args.once:
      return 0
    time.sleep(max(1.0, INTERVAL_SEC - (time.time() - started)))


if __name__ == "__main__":
  sys.exit(main())
