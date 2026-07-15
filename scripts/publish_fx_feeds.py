#!/usr/bin/env python3
"""USDC/cNGN price publisher for the Base deliverable FX market.

Signs LyraSpotFeed EIP-712 payloads with the feed-signer key and submits them
with a relayer key. Two feeds are served:

- cNGN spot feed  (heartbeat 3 min)  -> price = cNGN per USDC, 1e18 scale
- stable feed     (heartbeat 60 min) -> price = USDC/USD, 1e18 scale

Env (or ~/.numo-feeds.env):
  RPC_URL            Base RPC endpoint
  FEED_SIGNER_KEY    private key of the whitelisted feed signer (never needs ETH)
  RELAYER_KEY        private key of a funded wallet that submits the txs

Price source: open.er-api.com USD->NGN, overridable with --cngn-price.
Stable price defaults to 1.0, overridable with --stable-price.

Usage:
  python3 scripts/publish_fx_feeds.py --once --dry-run   # smoke test, no txs
  python3 scripts/publish_fx_feeds.py                    # run forever
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent

CHAIN_ID = 8453
CONFIDENCE = 10**18
DEADLINE_SEC = 60
TIMESTAMP_SAFETY_SEC = 15  # feed rejects timestamps newer than block.timestamp
CNGN_INTERVAL_SEC = 60          # heartbeat 180s
STABLE_INTERVAL_SEC = 20 * 60   # heartbeat 3600s
FX_API_URL = "https://open.er-api.com/v6/latest/USD"


def run(cmd: list[str]) -> str:
  res = subprocess.run(cmd, capture_output=True, text=True)
  if res.returncode != 0:
    raise RuntimeError(f"{' '.join(cmd[:3])}... failed: {res.stderr.strip()}")
  return res.stdout.strip()


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip(), value.strip().removeprefix("export ").strip())


def artifact(name: str) -> dict:
  return json.loads((ROOT_DIR / "deployments" / str(CHAIN_ID) / name).read_text())


def fetch_usd_ngn() -> float:
  with urllib.request.urlopen(FX_API_URL, timeout=10) as resp:
    data = json.loads(resp.read())
  rate = data["rates"]["NGN"]
  if not (100 < rate < 100_000):
    raise RuntimeError(f"implausible USD/NGN rate: {rate}")
  return float(rate)


def sign_feed_data(feed: str, key: str, inner: str, deadline: int, timestamp: int) -> str:
  typed = {
    "types": {
      "EIP712Domain": [
        {"name": "name", "type": "string"},
        {"name": "version", "type": "string"},
        {"name": "chainId", "type": "uint256"},
        {"name": "verifyingContract", "type": "address"},
      ],
      "FeedData": [
        {"name": "data", "type": "bytes"},
        {"name": "deadline", "type": "uint256"},
        {"name": "timestamp", "type": "uint64"},
      ],
    },
    "primaryType": "FeedData",
    "domain": {"name": "LyraSpotFeed", "version": "1", "chainId": CHAIN_ID, "verifyingContract": feed},
    "message": {"data": inner, "deadline": deadline, "timestamp": timestamp},
  }
  return run(["cast", "wallet", "sign", "--data", json.dumps(typed, separators=(",", ":")), "--private-key", key])


def build_payload(feed: str, price_1e18: int, signer_key: str, signer_addr: str) -> str:
  timestamp = int(time.time()) - TIMESTAMP_SAFETY_SEC
  deadline = timestamp + TIMESTAMP_SAFETY_SEC + DEADLINE_SEC
  inner = run(["cast", "abi-encode", "f(uint96,uint64)", str(price_1e18), str(CONFIDENCE)])
  sig = sign_feed_data(feed, signer_key, inner, deadline, timestamp)
  return run([
    "cast", "abi-encode", "f((bytes,uint256,uint64,address[],bytes[]))",
    f"({inner},{deadline},{timestamp},[{signer_addr}],[{sig}])",
  ])


def submit(rpc: str, relayer_key: str, feed: str, payload: str) -> str:
  out = run(["cast", "send", feed, "acceptData(bytes)", payload, "--rpc-url", rpc, "--private-key", relayer_key, "--json"])
  return json.loads(out)["transactionHash"]


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--once", action="store_true", help="publish one round and exit")
  parser.add_argument("--dry-run", action="store_true", help="build+sign but do not submit")
  parser.add_argument("--cngn-price", type=float, help="static cNGN-per-USDC override")
  parser.add_argument("--stable-price", type=float, default=1.0, help="USDC/USD price (default 1.0)")
  parser.add_argument("--rpc-url", default=None)
  args = parser.parse_args()

  load_env_file(Path.home() / ".numo-feeds.env")
  rpc = args.rpc_url or os.environ.get("RPC_URL") or "https://mainnet.base.org"
  signer_key = os.environ.get("FEED_SIGNER_KEY")
  relayer_key = os.environ.get("RELAYER_KEY")
  if not signer_key or (not args.dry_run and not relayer_key):
    print("FEED_SIGNER_KEY and RELAYER_KEY are required (env or ~/.numo-feeds.env)", file=sys.stderr)
    return 1
  signer_addr = run(["cast", "wallet", "address", "--private-key", signer_key]).splitlines()[-1]

  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  core = artifact("core.json")
  cngn_feed = fut["spotFeed"]
  stable_feed = core["stableFeed"]
  print(f"signer {signer_addr} | cngn feed {cngn_feed} | stable feed {stable_feed}")

  last_stable = 0.0
  while True:
    started = time.time()
    try:
      cngn_price = args.cngn_price if args.cngn_price else fetch_usd_ngn()
      rounds = [(cngn_feed, int(cngn_price * 10**18), "cngn")]
      if started - last_stable >= STABLE_INTERVAL_SEC or args.once:
        rounds.append((stable_feed, int(args.stable_price * 10**18), "stable"))

      for feed, price, label in rounds:
        for attempt in (1, 2):  # one retry per round; transient RPC nodes happen
          try:
            payload = build_payload(feed, price, signer_key, signer_addr)
            if args.dry_run:
              print(f"[dry-run] {label}: price={price} payload={payload[:42]}...")
            else:
              tx = submit(rpc, relayer_key, feed, payload)
              print(f"{time.strftime('%H:%M:%S')} {label}: price={price} tx={tx}")
              if label == "stable":
                last_stable = started
            break
          except Exception as exc:
            print(f"ERROR ({label}, attempt {attempt}): {exc}", file=sys.stderr)
            time.sleep(2)
    except Exception as exc:  # keep the loop alive; staleness alerting is external
      print(f"ERROR: {exc}", file=sys.stderr)

    if args.once:
      return 0
    time.sleep(max(1.0, CNGN_INTERVAL_SEC - (time.time() - started)))


if __name__ == "__main__":
  sys.exit(main())
