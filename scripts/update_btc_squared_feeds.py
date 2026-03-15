#!/usr/bin/env python3
"""Minimal BTC squared-perp feed updater for Base.

Uses:
- Chainlink-backed onchain BTC/USD spotFeed as anchor
- Binance BTCUSDT perp best bid/ask midpoint as mark source
- Fixed spread around mark for impact prices
- One or more whitelisted signer keys for EIP-712 feed updates
- A relayer key to submit transactions
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP, getcontext
from pathlib import Path


getcontext().prec = 80

DEFAULT_CHAIN_ID = 8453
DEFAULT_CONFIDENCE = 10**18
DEFAULT_DEADLINE_SEC = 30
DEFAULT_LOOP_INTERVAL_SEC = 60
DEFAULT_UPDATE_THRESHOLD_BPS = 10
DEFAULT_MAX_BASIS_BPS = 30
DEFAULT_IMPACT_SPREAD_BPS = 10
DEFAULT_TIMESTAMP_SAFETY_SEC = 15

DEFAULT_SPOT_FEED = "0x0812f224D7329C6166040E377fEb2c46a73AdaCd"
DEFAULT_PERP_FEED = "0x684b98Cf6467386AA3b73D8b6a50c034Ea034705"
DEFAULT_IAP_FEED = "0x8a4089B354532dF320073c8fAde89dcAD69971DF"
DEFAULT_IBP_FEED = "0x420c4838BFbbfFb061717434a0767adDd0b95C8B"
BINANCE_BOOK_TICKER_URL = "https://fapi.binance.com/fapi/v1/ticker/bookTicker?symbol=BTCUSDT"

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent


@dataclass
class Config:
  rpc_url: str
  relayer_private_key: str
  signer_private_keys: list[str]
  data_submitter: str
  spot_feed: str
  perp_feed: str
  iap_feed: str
  ibp_feed: str
  chain_id: int
  confidence: int
  deadline_sec: int
  max_basis_bps: int
  impact_spread_bps: int
  update_threshold_bps: int
  loop_interval_sec: int
  timestamp_safety_sec: int
  dry_run: bool
  once: bool


def load_env_file(env_path: Path) -> None:
  if not env_path.exists():
    return
  for raw_line in env_path.read_text().splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip(), value.strip())


def load_json(path: Path) -> dict:
  return json.loads(path.read_text())


def require_env(name: str) -> str:
  value = os.environ.get(name, "").strip()
  if not value:
    raise RuntimeError(f"missing env var: {name}")
  return value


def run(cmd: list[str], *, check: bool = True) -> str:
  proc = subprocess.run(cmd, capture_output=True, text=True)
  if check and proc.returncode != 0:
    stderr = proc.stderr.strip()
    stdout = proc.stdout.strip()
    detail = stderr or stdout or f"exit code {proc.returncode}"
    raise RuntimeError(f"command failed: {' '.join(cmd)}\n{detail}")
  return proc.stdout.strip()


def cast_wallet_address(private_key: str) -> str:
  return run(["cast", "wallet", "address", "--private-key", private_key]).strip()


def cast_call_uint_pair(rpc_url: str, address: str, signature: str) -> tuple[int, int]:
  out = run(["cast", "call", address, signature, "--rpc-url", rpc_url])
  lines = [line.strip() for line in out.splitlines() if line.strip()]
  if len(lines) != 2:
    raise RuntimeError(f"unexpected cast call output for {signature}: {out}")
  first = int(lines[0].split()[0])
  second = int(lines[1].split()[0])
  return first, second


def cast_block_timestamp(rpc_url: str) -> int:
  return int(run(["cast", "block", "latest", "--field", "timestamp", "--rpc-url", rpc_url]))


def cast_feed_domain(feed_address: str, chain_id: int) -> dict:
  return {
    "name": "LyraSpotDiffFeed",
    "version": "1",
    "chainId": chain_id,
    "verifyingContract": feed_address,
  }


def sign_typed_data(
  feed_address: str,
  private_key: str,
  inner_data: str,
  deadline: int,
  timestamp: int,
  chain_id: int,
) -> str:
  typed_data = {
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
    "domain": cast_feed_domain(feed_address, chain_id),
    "message": {
      "data": inner_data,
      "deadline": deadline,
      "timestamp": timestamp,
    },
  }

  return run(
    [
      "cast",
      "wallet",
      "sign",
      "--data",
      json.dumps(typed_data, separators=(",", ":")),
      "--private-key",
      private_key,
    ]
  ).strip()


def encode_inner_data(diff: int, confidence: int) -> str:
  return run(["cast", "abi-encode", "f(int96,uint64)", str(diff), str(confidence)]).strip()


def encode_feed_data(
  inner_data: str,
  deadline: int,
  timestamp: int,
  signer_addresses: list[str],
  signatures: list[str],
) -> str:
  if not signer_addresses:
    raise RuntimeError("expected at least one signer address")
  if len(signer_addresses) != len(signatures):
    raise RuntimeError("signer addresses and signatures length mismatch")

  encoded_signers = ",".join(signer_addresses)
  encoded_signatures = ",".join(signatures)
  tuple_arg = f"({inner_data},{deadline},{timestamp},[{encoded_signers}],[{encoded_signatures}])"
  return run(["cast", "abi-encode", "f((bytes,uint256,uint64,address[],bytes[]))", tuple_arg]).strip()


def encode_manager_data(receiver: str, data: str) -> str:
  return f"({receiver},{data})"


def encode_batch_submit_data(updates: list[tuple[str, str]]) -> str:
  if not updates:
    raise RuntimeError("expected at least one update")
  encoded_updates = ",".join(encode_manager_data(receiver, data) for receiver, data in updates)
  return run(["cast", "abi-encode", "f((address,bytes)[])", f"[{encoded_updates}]"]).strip()


def send_submit_data(rpc_url: str, data_submitter: str, encoded_batch_data: str, relayer_private_key: str) -> str:
  return run(
    [
      "cast",
      "send",
      data_submitter,
      "submitData(bytes)",
      encoded_batch_data,
      "--rpc-url",
      rpc_url,
      "--private-key",
      relayer_private_key,
    ]
  )


def fetch_binance_book_ticker() -> tuple[int, int]:
  with urllib.request.urlopen(BINANCE_BOOK_TICKER_URL, timeout=10) as response:
    payload = json.loads(response.read().decode("utf-8"))

  bid = decimal_to_wei(payload["bidPrice"])
  ask = decimal_to_wei(payload["askPrice"])
  if bid <= 0 or ask <= 0 or ask < bid:
    raise RuntimeError(f"invalid Binance book ticker: {payload}")
  return bid, ask


def decimal_to_wei(value: str) -> int:
  scaled = (Decimal(value) * Decimal(10**18)).quantize(Decimal("1"), rounding=ROUND_HALF_UP)
  return int(scaled)


def apply_bps(value: int, bps: int) -> int:
  return (value * (10_000 + bps)) // 10_000


def relative_bps_diff(a: int, b: int) -> int:
  reference = max(abs(a), 1)
  return (abs(a - b) * 10_000) // reference


def clamp_mark_to_spot(spot: int, mark: int, max_basis_bps: int) -> int:
  basis_cap = (spot * max_basis_bps) // 10_000
  upper = spot + basis_cap
  lower = spot - basis_cap
  return max(lower, min(upper, mark))


def compute_targets(spot: int, bid: int, ask: int, max_basis_bps: int, impact_spread_bps: int) -> tuple[int, int, int]:
  raw_mark = (bid + ask) // 2
  mark = clamp_mark_to_spot(spot, raw_mark, max_basis_bps)
  impact_ask = apply_bps(mark, impact_spread_bps)
  impact_bid = (mark * (10_000 - impact_spread_bps)) // 10_000
  if impact_bid >= impact_ask:
    raise RuntimeError("invalid impact prices: bid must be below ask")
  return mark, impact_ask, impact_bid


def int96_check(value: int) -> None:
  limit = 2**95
  if not (-limit <= value < limit):
    raise RuntimeError(f"value does not fit int96: {value}")


def get_feed_result_or_none(rpc_url: str, feed_address: str) -> int | None:
  proc = subprocess.run(
    ["cast", "call", feed_address, "getResult()(uint256,uint256)", "--rpc-url", rpc_url],
    capture_output=True,
    text=True,
  )
  if proc.returncode != 0:
    return None
  lines = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
  if not lines:
    return None
  return int(lines[0].split()[0])


def should_submit(current: int | None, target: int, threshold_bps: int) -> bool:
  if current is None:
    return True
  return relative_bps_diff(current, target) >= threshold_bps


def submit_feed_update(
  rpc_url: str,
  feed_address: str,
  target_price: int,
  spot_price: int,
  confidence: int,
  deadline_sec: int,
  timestamp_safety_sec: int,
  chain_id: int,
  signer_private_keys: list[str],
  signer_addresses: list[str],
) -> tuple[str, str, int, int]:
  diff = target_price - spot_price
  int96_check(diff)

  timestamp = cast_block_timestamp(rpc_url) - timestamp_safety_sec
  deadline = timestamp + deadline_sec

  inner_data = encode_inner_data(diff, confidence)
  signatures = [
    sign_typed_data(feed_address, signer_private_key, inner_data, deadline, timestamp, chain_id)
    for signer_private_key in signer_private_keys
  ]
  encoded_feed_data = encode_feed_data(inner_data, deadline, timestamp, signer_addresses, signatures)
  return feed_address, encoded_feed_data, target_price, diff


def build_config(args: argparse.Namespace) -> Config:
  load_env_file(ROOT_DIR / ".env")
  core_deployment = load_json(ROOT_DIR / "deployments" / str(DEFAULT_CHAIN_ID) / "core.json")

  signer_private_keys = [require_env("SIGNER1_PRIVATE_KEY")]
  signer2_private_key = os.environ.get("SIGNER2_PRIVATE_KEY", "").strip()
  if signer2_private_key:
    signer_private_keys.append(signer2_private_key)

  return Config(
    rpc_url=os.environ.get("BASE_RPC_URL", "").strip() or require_env("RPC_URL"),
    relayer_private_key=(
      os.environ.get("RELAYER_PRIVATE_KEY", "").strip()
      or os.environ.get("PRIVATE_KEY", "").strip()
      or signer_private_keys[0]
    ),
    data_submitter=os.environ.get("DATA_SUBMITTER", "").strip() or core_deployment["dataSubmitter"],
    signer_private_keys=signer_private_keys,
    spot_feed=os.environ.get("BTC_SQUARED_SPOT_FEED", DEFAULT_SPOT_FEED),
    perp_feed=os.environ.get("BTC_SQUARED_PERP_FEED", DEFAULT_PERP_FEED),
    iap_feed=os.environ.get("BTC_SQUARED_IAP_FEED", DEFAULT_IAP_FEED),
    ibp_feed=os.environ.get("BTC_SQUARED_IBP_FEED", DEFAULT_IBP_FEED),
    chain_id=int(os.environ.get("CHAIN_ID", str(DEFAULT_CHAIN_ID))),
    confidence=int(os.environ.get("BTC_SQUARED_CONFIDENCE", str(DEFAULT_CONFIDENCE))),
    deadline_sec=int(os.environ.get("BTC_SQUARED_DEADLINE_SEC", str(DEFAULT_DEADLINE_SEC))),
    max_basis_bps=int(os.environ.get("BTC_SQUARED_MAX_BASIS_BPS", str(DEFAULT_MAX_BASIS_BPS))),
    impact_spread_bps=int(os.environ.get("BTC_SQUARED_IMPACT_SPREAD_BPS", str(DEFAULT_IMPACT_SPREAD_BPS))),
    update_threshold_bps=int(os.environ.get("BTC_SQUARED_UPDATE_THRESHOLD_BPS", str(DEFAULT_UPDATE_THRESHOLD_BPS))),
    loop_interval_sec=int(os.environ.get("BTC_SQUARED_LOOP_INTERVAL_SEC", str(DEFAULT_LOOP_INTERVAL_SEC))),
    timestamp_safety_sec=int(os.environ.get("BTC_SQUARED_TIMESTAMP_SAFETY_SEC", str(DEFAULT_TIMESTAMP_SAFETY_SEC))),
    dry_run=args.dry_run,
    once=args.once,
  )


def run_once(config: Config, signer_addresses: list[str]) -> None:
  spot, spot_confidence = cast_call_uint_pair(config.rpc_url, config.spot_feed, "getSpot()(uint256,uint256)")
  bid, ask = fetch_binance_book_ticker()
  mark, impact_ask, impact_bid = compute_targets(
    spot,
    bid,
    ask,
    config.max_basis_bps,
    config.impact_spread_bps,
  )

  print(f"spot={spot} spot_confidence={spot_confidence}")
  print(f"binance_bid={bid} binance_ask={ask}")
  print(f"mark={mark} impact_ask={impact_ask} impact_bid={impact_bid}")

  pending_updates: list[tuple[str, str, int, int]] = []

  if should_submit(get_feed_result_or_none(config.rpc_url, config.perp_feed), mark, config.update_threshold_bps):
    pending_updates.append(submit_feed_update(
      config.rpc_url,
      config.perp_feed,
      mark,
      spot,
      config.confidence,
      config.deadline_sec,
      config.timestamp_safety_sec,
      config.chain_id,
      config.signer_private_keys,
      signer_addresses,
    ))
  else:
    print("skip perpFeed: below threshold")

  if should_submit(get_feed_result_or_none(config.rpc_url, config.iap_feed), impact_ask, config.update_threshold_bps):
    pending_updates.append(submit_feed_update(
      config.rpc_url,
      config.iap_feed,
      impact_ask,
      spot,
      config.confidence,
      config.deadline_sec,
      config.timestamp_safety_sec,
      config.chain_id,
      config.signer_private_keys,
      signer_addresses,
    ))
  else:
    print("skip iapFeed: below threshold")

  if should_submit(get_feed_result_or_none(config.rpc_url, config.ibp_feed), impact_bid, config.update_threshold_bps):
    pending_updates.append(submit_feed_update(
      config.rpc_url,
      config.ibp_feed,
      impact_bid,
      spot,
      config.confidence,
      config.deadline_sec,
      config.timestamp_safety_sec,
      config.chain_id,
      config.signer_private_keys,
      signer_addresses,
    ))
  else:
    print("skip ibpFeed: below threshold")

  if not pending_updates:
    print("skip batch: no feed exceeded threshold")
    return

  for feed_address, _, target_price, diff in pending_updates:
    action = "dry-run" if config.dry_run else "queue"
    print(f"{action} {feed_address} target={target_price} diff={diff}")

  batch_updates = [(feed_address, encoded_feed_data) for feed_address, encoded_feed_data, _, _ in pending_updates]
  encoded_batch_data = encode_batch_submit_data(batch_updates)

  if config.dry_run:
    print(f"dry-run batch submitter={config.data_submitter} updates={len(batch_updates)}")
    return

  tx = send_submit_data(config.rpc_url, config.data_submitter, encoded_batch_data, config.relayer_private_key)
  print(f"submitted batch via {config.data_submitter}: {tx}")


def parse_args() -> argparse.Namespace:
  parser = argparse.ArgumentParser(description="Update BTC squared-perp feeds on Base.")
  parser.add_argument("--dry-run", action="store_true", help="Compute and sign updates without sending transactions.")
  parser.add_argument("--once", action="store_true", help="Run one update cycle and exit.")
  return parser.parse_args()


def main() -> int:
  args = parse_args()
  try:
    config = build_config(args)
    signer_addresses = [cast_wallet_address(key) for key in config.signer_private_keys]

    for idx, signer_address in enumerate(signer_addresses, start=1):
      print(f"signer{idx}={signer_address}")

    while True:
      run_once(config, signer_addresses)
      if config.once:
        return 0
      time.sleep(config.loop_interval_sec)
  except KeyboardInterrupt:
    return 130
  except Exception as exc:
    print(f"error: {exc}", file=sys.stderr)
    return 1


if __name__ == "__main__":
  raise SystemExit(main())
