#!/usr/bin/env python3
"""Propose the two-action market-1 batch to MPCVault for manual approval.

Makes wrapped USDC (market 1) as inert as wrapped cNGN (market 2):

  0. srm.setOraclesForMarket(1, staticStableFeed, 0, 0)
  1. srm.setBaseAssetMarginFactor(1, 0, 0)

It NEVER signs, executes or broadcasts. `callbackClientSignerPublicKey` is deliberately
omitted, which routes each request to the MPCVault app for a human to approve. All the
transport, proposal and confirmation logic is imported from propose_cngn_spot_batch so
there is exactly one implementation of "talk to MPCVault" in the tree.

ORDER IS A CORRECTNESS REQUIREMENT.

Action 0 repoints the feed; action 1 zeroes the margin factor. After action 0 alone the
market is on a static feed at the current 0.98 factor -- strictly safer than the state we
start from. The reverse order leaves a window where market 1 is still halted by a stale
feed. So this proposes ONE action, waits for it to confirm on-chain, then proposes the
next. The queue never holds more than one item, which makes approving out of order
impossible rather than merely discouraged. There is deliberately no --all.

Env (or ~/.numo-mark-keeper.env), normally supplied by run-with-ssm-mark.sh:
  MPCVAULT_TOKEN   MPCVault API token (x-mtoken). Never logged.
  MPCVAULT_VAULT   vault uuid
  VAULT_ADDRESS    the vault EOA the batch executes as
  RPC_URL          Base mainnet RPC

Usage:
  python3 scripts/ops/propose_market1_inert_batch.py             # print the sheet, propose nothing
  python3 scripts/ops/propose_market1_inert_batch.py --propose   # one at a time, waiting between
  python3 scripts/ops/propose_market1_inert_batch.py --self-test # offline selector check
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from propose_cngn_spot_batch import (  # noqa: E402  single implementation of the MPCVault transport
  CONFIRM_POLL_SEC,
  CONFIRM_TIMEOUT_SEC,
  EXPECTED_VAULT,
  confirm_on_chain,
  load_env_file,
  propose,
  request_tx_hash,
  rpc,
)

ROOT = Path(__file__).resolve().parent.parent.parent
ARTIFACT = ROOT / "deployments" / "8453" / "MARKET1_INERT_VAULT_ACTIONS.json"

SRM = "0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b"
STATIC_STABLE_FEED = "0x507D645682737C6640dc73b5aC858654BcB9854f"
MARKET_ID = 1

# Digests recorded in the artifact, pinned here too so a hand edit to either file is caught.
EXPECTED_DIGESTS = [
  "0x3863b489a5db9eb51fc1af7f34155eca792a20e4aab25ddbac91c5ad6454127c",
  "0xf0034314ac71658f48dd55f19c6abd5d252943c06342e2117202a4f6cf2876e6",
]

SELECTORS = {
  # writes: dispatched on, taken from the artifact's calldata
  "setOraclesForMarket(uint256,address,address,address)": "0x675b0ebb",
  "setBaseAssetMarginFactor(uint256,uint256,uint256)": "0xc27009e2",
  # reads: the postcondition each branch checks
  "getMarketFeeds(uint256)": "0xa95371a4",
  "baseMarginParams(uint256)": "0xcd27955d",
}

MARKET_ID_WORD = f"{MARKET_ID:064x}"


def load_actions() -> list[dict]:
  if not ARTIFACT.exists():
    raise SystemExit(f"{ARTIFACT} not found")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 2:
    raise SystemExit(f"expected 2 actions, artifact has {len(actions)}")
  return actions


def verify_artifact(actions: list[dict]) -> None:
  """Recompute each digest from the entry's own bytes, and check the pinned values.

  keccak256(abi.encodePacked(to, keccak256(data))) -- the same actionHash the forge
  scripts use, reproduced here so the two files cannot drift apart silently.
  """
  from resolve_cngn_action6 import keccak  # zero-dependency, already vector-checked

  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"

  for i, a in enumerate(actions):
    if a["to"].lower() != SRM.lower():
      raise SystemExit(f"action {i} targets {a['to']}, not the SRM {SRM}")
    if a["value"] != "0":
      raise SystemExit(f"action {i} sends value {a['value']}; every action here must be value 0")
    inner = keccak(bytes.fromhex(a["data"][2:]))
    packed = bytes.fromhex(a["to"][2:]) + inner
    got = "0x" + keccak(packed).hex()
    if got != a["digest"]:
      raise SystemExit(f"action {i} digest mismatch: recorded {a['digest']}, recomputed {got}")
    if got != EXPECTED_DIGESTS[i]:
      raise SystemExit(
        f"action {i} digest {got} is not the pinned {EXPECTED_DIGESTS[i]}.\n"
        "Something about the batch moved. Re-read the diff before proposing anything."
      )
  print(f"  ok - both digests recomputed from calldata and match the pinned values")


def action_landed(rpc_url: str, action: dict) -> bool:
  """Per-action postcondition, used only to skip work already done.

  Any error answers False. Re-proposing an action that already ran is harmless -- it sets
  the same values again -- whereas skipping one that never ran breaks the ordering. Bias
  toward proposing.

  Unlike the cNGN batch, both postconditions here are unambiguous: market 1 currently reads
  a live feed and (0.98e18, 0.98e18), so neither target value is what an untouched market
  already shows.
  """
  data = action["data"]
  selector = data[:10]

  def call(payload: str) -> str:
    return rpc(rpc_url, "eth_call", [{"to": SRM, "data": payload}, "latest"])

  try:
    if selector == "0x675b0ebb":                                    # setOraclesForMarket
      feeds = call("0xa95371a4" + MARKET_ID_WORD)[2:]               # getMarketFeeds(1)
      spot = "0x" + feeds[24:64]
      return spot.lower() == STATIC_STABLE_FEED.lower()
    if selector == "0xc27009e2":                                    # setBaseAssetMarginFactor
      params = call("0xcd27955d" + MARKET_ID_WORD)[2:]              # baseMarginParams(1)
      return int(params[0:64], 16) == 0 and int(params[64:128], 16) == 0
  except Exception:
    return False
  return False


def print_sheet(actions: list[dict]) -> None:
  print()
  print(f"{'#':>2}  {'to':<44}  digest")
  for i, a in enumerate(actions):
    print(f"{i:>2}  {a['to']:<44}  {a['digest']}")
    print(f"    {a['description']}")
  print()


def self_test() -> int:
  """Offline check that the hardcoded selectors are what their signatures hash to.

  action_landed() swallows errors into "not landed", so a wrong selector degrades silently
  to re-proposing rather than crashing. Safe, but invisible -- which is why it needs a test.
  """
  from resolve_cngn_action6 import keccak

  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"

  for signature, expected in SELECTORS.items():
    actual = "0x" + keccak(signature.encode()).hex()[:8]
    assert actual == expected, f"{signature}: hardcoded {expected}, actual {actual}"

  # every hardcoded literal must actually be reached by action_landed, so a stale one cannot hide
  body = Path(__file__).read_text()
  start = body.index("def action_landed(")
  end = body.index("def print_sheet(")
  used = {m for m in SELECTORS.values() if m in body[start:end]}
  missing = set(SELECTORS.values()) - used
  assert not missing, f"selectors declared but not used in action_landed: {sorted(missing)}"

  verify_artifact(load_actions())
  print(f"self-test ok: all {len(SELECTORS)} selectors match their signatures and are all in use")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the market-1 inert batch to MPCVault")
  ap.add_argument("--propose", action="store_true", help="actually create signing requests")
  ap.add_argument("--start-at", type=int, default=0, help="resume from this action index")
  ap.add_argument("--self-test", action="store_true",
                  help="check the hardcoded selectors offline; no network, proposes nothing")
  args = ap.parse_args()

  if args.self_test:
    return self_test()

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc_url = os.environ.get("RPC_URL") or os.environ.get("BASE_RPC_URL", "")
  if not rpc_url:
    raise SystemExit("RPC_URL (or BASE_RPC_URL) is required")

  actions = load_actions()
  print_sheet(actions)

  if not args.propose:
    print("dry run: nothing proposed. Re-run with --propose to create signing requests.")
    print("Compare each digest above against what MPCVault shows before approving.")
    for i, a in enumerate(actions):
      print(f"  [{i:>2}] already landed on chain: {action_landed(rpc_url, a)}")
    return 0

  token = os.environ.get("MPCVAULT_TOKEN", "")
  vault_uuid = os.environ.get("MPCVAULT_VAULT", "")
  vault_addr = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  if vault_addr.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault_addr} is not the recorded vault {EXPECTED_VAULT}")

  verify_artifact(actions)

  print()
  print("Proposing one at a time. Each waits for the previous to confirm on-chain, so the")
  print("queue never holds more than one item and out-of-order approval is not possible.")
  for i, a in enumerate(actions[args.start_at:], start=args.start_at):
    if action_landed(rpc_url, a):
      print(f"  [{i:>2}] already landed, skipping")
      continue

    uuid = propose(token, vault_uuid, vault_addr, a)
    print(f"  [{i:>2}] proposed  uuid={uuid}")
    print(f"       to     {a['to']}")
    print(f"       digest {a['digest']}")
    print(f"       {a['description']}")
    print("       -> approve this one in MPCVault now")

    deadline = time.time() + CONFIRM_TIMEOUT_SEC
    tx_hash = None
    while time.time() < deadline and not tx_hash:
      time.sleep(CONFIRM_POLL_SEC)
      tx_hash = request_tx_hash(token, uuid)
    if not tx_hash:
      raise SystemExit(f"action {i} was not approved within the timeout; re-run with --start-at {i}")
    confirm_on_chain(rpc_url, tx_hash)

    if not action_landed(rpc_url, a):
      raise SystemExit(f"action {i} confirmed but its postcondition still does not read true. Stop.")
    print(f"       postcondition verified on chain")

  print()
  print("Both confirmed. Market 1 now reads the static feed and contributes no collateral.")
  print("Verify with:")
  print("  forge test --match-contract SRMMarket1InertFork --fork-url $RPC_URL")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
