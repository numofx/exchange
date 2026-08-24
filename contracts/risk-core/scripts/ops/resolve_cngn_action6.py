#!/usr/bin/env python3
"""Resolve action 6 of the USDCcNGN-SPOT vault batch to a positive read.

Action 6 is `srm.setOracleContingencyParams(marketId, zeroed)`. Its postcondition is
all-zeros, which is exactly what an untouched market reads, so on-chain state alone
cannot tell "we set it" from "nobody touched it". The resume mode therefore reports it
as `done*` — inferred from nonce ordering rather than observed.

The event does not help on its own:

    OracleContingencySet(uint prepThreshold, uint optionThreshold,
                         uint baseThreshold, uint OCFactor)

carries no market id, indexed or otherwise. But the *transaction* that emitted it does:
the call is `setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))` and
the market id is the first calldata word after the selector.

So: scan for zero-valued OracleContingencySet logs on the SRM, fetch the transaction
behind each one, decode the market id from its input, and check whether any of them
targeted our market. That turns the last `done*` into a positive read.

This lives here rather than in the Solidity verifier because `vm.rpc` returns the
transaction object ABI-encoded in alphabetical key order, whose layout differs between
providers and between transaction types (a Base deposit tx carries extra fields), and
because ffi is not enabled in foundry.toml -- enabling it repo-wide so one check can
shell out would be a bad trade.

Env:
  RPC_URL         Base mainnet RPC (or pass --rpc)
  SRM_ADDRESS     defaults to the address in deployments/8453/core.json
  CNGN_MARKET_ID  defaults to srm.lastMarketId()

Usage:
  python3 scripts/ops/resolve_cngn_action6.py --from-block 12345678
  python3 scripts/ops/resolve_cngn_action6.py --from-block 12345678 --market-id 2

Exit codes:
  0  action 6 confirmed for the market: a transaction zeroed its contingency params
  1  no such transaction found in the scanned range (NOT proof it did not happen --
     widen the range before concluding anything)
  2  usage or RPC error
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.request
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent.parent

# keccak256("OracleContingencySet(uint256,uint256,uint256,uint256)")
ORACLE_CONTINGENCY_SET_TOPIC = "0x" + "".rjust(64, "0")  # filled in at runtime

# selector of setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))
SET_CONTINGENCY_SELECTOR = ""  # filled in at runtime

RPC_ID = [0]


def keccak(data: bytes) -> bytes:
  """Minimal keccak-256 so this has no third-party dependency, matching the other ops scripts."""
  RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
  ]
  ROT = [
    [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
  ]
  MASK = (1 << 64) - 1
  rate = 136

  def rol(x, n):
    return ((x << n) | (x >> (64 - n))) & MASK

  padded = bytearray(data)
  padded.append(0x01)
  while len(padded) % rate != 0:
    padded.append(0x00)
  padded[-1] |= 0x80

  state = [[0] * 5 for _ in range(5)]
  for off in range(0, len(padded), rate):
    block = padded[off:off + rate]
    for i in range(rate // 8):
      lane = int.from_bytes(block[i * 8:(i + 1) * 8], "little")
      state[i % 5][i // 5] ^= lane

    for rnd in range(24):
      c = [state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4] for x in range(5)]
      d = [c[(x - 1) % 5] ^ rol(c[(x + 1) % 5], 1) for x in range(5)]
      for x in range(5):
        for y in range(5):
          state[x][y] ^= d[x]

      b = [[0] * 5 for _ in range(5)]
      for x in range(5):
        for y in range(5):
          b[y][(2 * x + 3 * y) % 5] = rol(state[x][y], ROT[x][y])

      for x in range(5):
        for y in range(5):
          state[x][y] = b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y] & MASK)

      state[0][0] ^= RC[rnd]

  out = bytearray()
  for i in range(4):
    out += (state[i % 5][i // 5]).to_bytes(8, "little")
  return bytes(out)


def rpc(url: str, method: str, params: list):
  RPC_ID[0] += 1
  payload = json.dumps({"jsonrpc": "2.0", "id": RPC_ID[0], "method": method, "params": params})
  req = urllib.request.Request(
    url,
    data=payload.encode(),
    # some public RPCs reject urllib's default user-agent outright with a 403
    headers={"Content-Type": "application/json", "User-Agent": "numo-ops/1.0"},
  )
  with urllib.request.urlopen(req, timeout=30) as resp:
    body = json.loads(resp.read())
  if "error" in body:
    raise RuntimeError(f"{method}: {body['error']}")
  return body["result"]


def load_srm() -> str:
  core = json.loads((ROOT_DIR / "deployments" / "8453" / "core.json").read_text())
  return core["srm"]


def self_test() -> int:
  """Guard the two assumptions this resolver rests on, without needing a network.

  The same two are pinned on the Solidity side by
  test/scripts/CNGNSpotBatchShape.t.sol::testActionSixCalldataShapeMatchesTheOpsResolver.
  """
  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"

  selector = "0x" + keccak(
    b"setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))"
  ).hex()[:8]
  assert selector == "0xeab6bca1", f"selector drifted: {selector}"

  topic = "0x" + keccak(b"OracleContingencySet(uint256,uint256,uint256,uint256)").hex()
  assert topic == "0x1d062a3f808d5f043e2ea62f5b4f1b9b3f3d0a1d4b352d2a756c1cf875ff3bb1", "topic drifted"

  # setOracleContingencyParams(2, (0,0,0,0)) as produced by the Solidity batch
  calldata = selector + "".join(w.rjust(64, "0") for w in ["2", "0", "0", "0", "0"])
  assert calldata.startswith(selector)
  assert int(calldata[10:74], 16) == 2, "marketId decode broken"
  assert len(calldata) == 2 + 8 + 5 * 64, "calldata length changed - struct may no longer be static"

  print("self-test ok: keccak, selector, topic and marketId decode all match")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Resolve action 6 of the cNGN spot vault batch")
  ap.add_argument("--rpc", default=os.environ.get("RPC_URL", "https://mainnet.base.org"))
  ap.add_argument("--srm", default=os.environ.get("SRM_ADDRESS"))
  ap.add_argument("--market-id", type=int, default=int(os.environ.get("CNGN_MARKET_ID", "0")) or None)
  ap.add_argument("--from-block", type=int, help="start of the scan range")
  ap.add_argument("--self-test", action="store_true",
                  help="check the derived selector and decode against a known-good encoding")
  ap.add_argument("--to-block", default="latest")
  args = ap.parse_args()

  if args.self_test:
    return self_test()
  if args.from_block is None:
    ap.error("--from-block is required unless --self-test is given")

  topic = "0x" + keccak(b"OracleContingencySet(uint256,uint256,uint256,uint256)").hex()
  selector = "0x" + keccak(
    b"setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))"
  ).hex()[:8]

  srm = args.srm or load_srm()

  market_id = args.market_id
  if market_id is None:
    last = rpc(args.rpc, "eth_call", [{"to": srm, "data": "0x" + keccak(b"lastMarketId()").hex()[:8]}, "latest"])
    market_id = int(last, 16)
    print(f"market id not given; using srm.lastMarketId() = {market_id}")

  to_block = args.to_block if args.to_block == "latest" else hex(int(args.to_block))
  logs = rpc(args.rpc, "eth_getLogs", [{
    "address": srm,
    "topics": [topic],
    "fromBlock": hex(args.from_block),
    "toBlock": to_block,
  }])

  print(f"scanning {srm} blocks {args.from_block}..{args.to_block}")
  print(f"found {len(logs)} OracleContingencySet log(s)")

  candidates = 0
  for log in logs:
    data = log["data"][2:]
    words = [data[i:i + 64] for i in range(0, len(data), 64)]
    # our action zeroes all four thresholds; anything else is not the call we are looking for
    if len(words) != 4 or any(int(w, 16) != 0 for w in words):
      continue
    candidates += 1

    tx = rpc(args.rpc, "eth_getTransactionByHash", [log["transactionHash"]])
    calldata = tx["input"]
    if not calldata.startswith(selector):
      print(f"  {log['transactionHash']}  emitted the event but is not a direct "
            f"setOracleContingencyParams call (selector {calldata[:10]}) -- inspect manually")
      continue

    # setOracleContingencyParams(uint256 marketId, OracleContingencyParams params)
    # the struct is static (four uints), so marketId is simply the first word after the selector
    logged_market = int(calldata[10:74], 16)
    mark = "MATCH" if logged_market == market_id else "other market"
    print(f"  {log['transactionHash']}  block {int(log['blockNumber'], 16)}  "
          f"marketId={logged_market}  [{mark}]")

    if logged_market == market_id:
      print()
      print(f"ACTION 6 CONFIRMED for market {market_id}: contingency params were explicitly zeroed by")
      print(f"  {log['transactionHash']}")
      print("This is a positive read -- it does not rest on nonce ordering.")
      return 0

  print()
  if candidates == 0:
    print("no zero-valued OracleContingencySet logs in this range.")
  else:
    print(f"{candidates} zero-valued log(s), none for market {market_id}.")
  print("NOT a proof action 6 did not run -- widen --from-block before concluding anything.")
  return 1


if __name__ == "__main__":
  try:
    sys.exit(main())
  except Exception as exc:  # noqa: BLE001
    print(f"error: {exc}", file=sys.stderr)
    sys.exit(2)
