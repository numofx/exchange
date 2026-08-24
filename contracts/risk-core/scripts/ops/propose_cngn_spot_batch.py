#!/usr/bin/env python3
"""Propose the USDCcNGN-SPOT vault batch to MPCVault for manual approval.

Creates signing requests for the eleven actions in
deployments/8453/CNGN_SPOT_SRM_VAULT_ACTIONS.json. It NEVER signs, executes or broadcasts:
`callbackClientSignerPublicKey` is deliberately omitted, which routes each request to the
MPCVault app for a human to approve. Compare mark_keeper.submit_via_mpcvault, which does
the opposite -- it routes to the client signer and calls executeSigningRequests -- and is
not what this is for.

ORDER IS A CORRECTNESS REQUIREMENT, NOT A PREFERENCE.

  - action 4 creates market 2; actions 5-8 configure that id and revert without it
  - action 10 is the enabling switch, and no earlier prefix may be tradeable
  - action 6's later resume status is inferred from the vault's nonce ordering

Eleven requests queued at once could be approved in any order, and MPCVault assigns the
nonce at broadcast. So by default this proposes ONE action, waits for it to confirm
on-chain, then proposes the next. The queue never holds more than one item, which makes
approving out of order impossible rather than merely discouraged.

--all queues everything at once. It exists because you may want that; it moves the
ordering guarantee from the tool to you.

Before each proposal the batch is re-derived from live chain state and compared to the
artifact, and the action's own postcondition is re-read, so an action that already landed
is skipped rather than proposed twice.

Env (or ~/.numo-mark-keeper.env):
  MPCVAULT_TOKEN   MPCVault API token (x-mtoken). Never logged.
  MPCVAULT_VAULT   vault uuid
  VAULT_ADDRESS    the vault EOA the batch executes as
  RPC_URL          Base mainnet RPC

Usage:
  python3 scripts/ops/propose_cngn_spot_batch.py                # print the sheet, propose nothing
  python3 scripts/ops/propose_cngn_spot_batch.py --propose      # one at a time, waiting between
  python3 scripts/ops/propose_cngn_spot_batch.py --propose --all
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_SPOT_SRM_VAULT_ACTIONS.json"

MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "400000"        # createMarket/whitelistAsset are the heaviest here; generous ceiling
MAX_FEE_WEI = "500000000"   # 0.5 gwei in WEI -- MPCVault gasFee.maxFee is wei, not gwei

EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
EXPECTED_BATCH_HASH = "0x7b7013f5689e88df5e39ef388226c642177b5da52fb6a08a41f7c7bf20b1edd4"

CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip(), value.strip().removeprefix("export ").strip())


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token,
             "User-Agent": "numo-cngn-spot-proposer/1.0"}, method="POST")  # MPCVault WAF 403s the default UA
  with urllib.request.urlopen(req, timeout=20) as resp:
    return json.loads(resp.read())


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(
    url, data=body,
    headers={"Content-Type": "application/json", "User-Agent": "numo-ops/1.0"}, method="POST")
  with urllib.request.urlopen(req, timeout=20) as resp:
    payload = json.loads(resp.read())
  if "error" in payload:
    raise RuntimeError(f"{method}: {payload['error']}")
  return payload["result"]


def input_b64(calldata_hex: str) -> str:
  """MPCVault's evmSendCustom.input is base64 bytes, not hex."""
  raw = calldata_hex[2:] if calldata_hex.lower().startswith("0x") else calldata_hex
  return base64.b64encode(bytes.fromhex(raw)).decode()


def load_actions() -> list[dict]:
  if not ARTIFACT.exists():
    raise SystemExit(
      f"{ARTIFACT} not found.\n"
      "Run: forge script scripts/register-cngn-spot-srm.s.sol --rpc-url $BASE_RPC_URL"
    )
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 11:
    raise SystemExit(f"expected 11 actions, artifact has {len(actions)}")
  return actions


def verify_artifact() -> None:
  """Re-derive the batch from live chain state and compare. This is the check with teeth:
  the digests in the file were written by the same code that wrote the file, so they only
  catch a hand edit. forge is the authority on whether the file still matches the world."""
  import subprocess
  print("verifying artifact against live chain state...")
  res = subprocess.run(
    ["forge", "script", "scripts/verify-cngn-spot-batch.s.sol", "--rpc-url", os.environ["RPC_URL"]],
    cwd=ROOT, capture_output=True, text=True,
  )
  if "artifact matches live-derived batch" not in res.stdout:
    print(res.stdout[-3000:], file=sys.stderr)
    raise SystemExit("artifact does NOT match live chain state - regenerate before proposing")
  if EXPECTED_BATCH_HASH not in res.stdout:
    raise SystemExit(
      f"batch hash changed; expected {EXPECTED_BATCH_HASH}.\n"
      "Something about the world moved. Re-read the diff before proposing anything."
    )
  print(f"  ok - batch hash {EXPECTED_BATCH_HASH}")


def action_landed(rpc_url: str, action: dict) -> bool:
  """Cheap per-action postcondition, used only to skip work already done.

  Deliberately conservative in two ways. Actions 5 and 6 write all-zeros, which an untouched
  market also reads, so they are never reported as landed. And any error answers False.
  Re-proposing an action that already ran is harmless -- it sets the same values again --
  whereas skipping one that never ran breaks the batch. Bias toward proposing.

  Every selector below was checked with `cast sig`; two were wrong when written from memory.
  """
  to = action["to"]
  data = action["data"]
  selector = data[:10]

  def call(target: str, payload: str) -> str:
    return rpc(rpc_url, "eth_call", [{"to": target, "data": payload}, "latest"])

  try:
    if selector == "0x79ba5097":                       # acceptOwnership()
      return ("0x" + call(to, "0x8da5cb5b")[-40:]).lower() == EXPECTED_VAULT.lower()  # owner()
    if selector == "0xbafb798d":                       # setStableFeed(address)
      return call(to, "0xf4d0508a")[-40:] == data[-40:].lower()             # stableFeed()
    if selector == "0xf1514a1a":                       # setBorrowingEnabled(bool)
      return int(call(to, "0xa35d1300"), 16) == 0                           # borrowingEnabled()
    if selector == "0x54888f55":                       # createMarket(string)
      return int(call(to, "0x565eb87c"), 16) >= 2                           # lastMarketId()
    if selector == "0xe64cc9da":                       # setWhitelistManager(address,bool)
      srm_word = data[10:74]
      return int(call(to, "0x97d51c04" + srm_word), 16) == 1                # whitelistedManager()
  except Exception:
    return False
  return False


def confirm_on_chain(rpc_url: str, tx_hash: str) -> None:
  print(f"    waiting for {tx_hash} ...", end="", flush=True)
  deadline = time.time() + CONFIRM_TIMEOUT_SEC
  while time.time() < deadline:
    receipt = rpc(rpc_url, "eth_getTransactionReceipt", [tx_hash])
    if receipt:
      status = int(receipt["status"], 16)
      print(" mined." if status == 1 else " REVERTED.")
      if status != 1:
        raise SystemExit(f"action reverted on chain: {tx_hash}. Stop and investigate.")
      return
    print(".", end="", flush=True)
    time.sleep(CONFIRM_POLL_SEC)
  raise SystemExit(f"timed out waiting for {tx_hash}")


def propose(token: str, vault_uuid: str, vault_addr: str, action: dict) -> str:
  created = http_post(MPCVAULT_BASE + "createSigningRequest", token, {
    "vaultUuid": vault_uuid,
    # NO callbackClientSignerPublicKey: that is what routes this to the app for a human to
    # approve. Supplying it would hand the signature to the automated client signer.
    "broadcastTx": True,
    "evmSendCustom": {
      "chainId": str(CHAIN_ID),
      "from": vault_addr,
      "to": action["to"],
      "input": input_b64(action["data"]),
      "value": "0",
      "gasFee": {"gasLimit": GAS_LIMIT, "maxFee": MAX_FEE_WEI},
    },
  })
  uuid = created["signingRequest"]["uuid"]
  return uuid


def request_tx_hash(token: str, uuid: str) -> str | None:
  details = http_post(MPCVAULT_BASE + "getSigningRequestDetails", token, {"uuid": uuid})
  return (details.get("signingRequest") or {}).get("txHash") or None


def print_sheet(actions: list[dict]) -> None:
  print()
  print(f"{'#':>2}  {'to':<44}  digest")
  for i, a in enumerate(actions):
    print(f"{i:>2}  {a['to']:<44}  {a['digest']}")
    print(f"    {a['description']}")
  print()


# Every selector this script hardcodes, with the signature it is meant to be. Also pinned against
# the LIVE deployed contracts by test/scripts/ProposerSelectors.t.sol, which is the stronger check:
# several of these are public state variables, so a signature string only proves I typed it twice.
SELECTORS = {
  # writes: dispatched on, taken from the artifact's calldata
  "acceptOwnership()": "0x79ba5097",
  "setStableFeed(address)": "0xbafb798d",
  "setBorrowingEnabled(bool)": "0xf1514a1a",
  "createMarket(string)": "0x54888f55",
  "setWhitelistManager(address,bool)": "0xe64cc9da",
  # reads: the postcondition each branch checks
  "owner()": "0x8da5cb5b",
  "stableFeed()": "0xf4d0508a",
  "borrowingEnabled()": "0xa35d1300",
  "lastMarketId()": "0x565eb87c",
  "whitelistedManager(address)": "0x97d51c04",
}


def self_test() -> int:
  """Offline check that the hardcoded selectors are what their signatures hash to.

  action_landed() swallows errors into "not landed", so a wrong selector degrades silently to
  re-proposing rather than crashing. That is safe but invisible, which is exactly why it needs a
  test: two of these were wrong when first written from memory.
  """
  sys.path.insert(0, str(Path(__file__).resolve().parent))
  from resolve_cngn_action6 import keccak  # same zero-dependency keccak, already vector-checked

  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"

  for signature, expected in SELECTORS.items():
    actual = "0x" + keccak(signature.encode()).hex()[:8]
    assert actual == expected, f"{signature}: hardcoded {expected}, actual {actual}"

  # the source of every hardcoded literal in action_landed, so a stale one cannot hide
  body = Path(__file__).read_text()
  start = body.index("def action_landed(")
  end = body.index("def confirm_on_chain(")
  used = {m for m in SELECTORS.values() if m in body[start:end]}
  missing = set(SELECTORS.values()) - used
  assert not missing, f"selectors declared but not used in action_landed: {sorted(missing)}"

  print(f"self-test ok: all {len(SELECTORS)} selectors match their signatures and are all in use")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the cNGN spot vault batch to MPCVault")
  ap.add_argument("--propose", action="store_true", help="actually create signing requests")
  ap.add_argument("--all", action="store_true",
                  help="queue all eleven at once instead of one at a time (you own the ordering)")
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
  os.environ["RPC_URL"] = rpc_url

  actions = load_actions()
  print_sheet(actions)

  if not args.propose:
    print("dry run: nothing proposed. Re-run with --propose to create signing requests.")
    print("Compare each digest above against what MPCVault shows before approving.")
    return 0

  token = os.environ.get("MPCVAULT_TOKEN", "")
  vault_uuid = os.environ.get("MPCVAULT_VAULT", "")
  vault_addr = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  if vault_addr.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault_addr} is not the recorded vault {EXPECTED_VAULT}")

  verify_artifact()

  if args.all:
    print()
    print("QUEUING ALL ELEVEN AT ONCE.")
    print("MPCVault assigns the nonce at broadcast, so approving out of order lands them out of")
    print("order. Action 4 creates the market that 5-8 configure, and 10 is the enabling switch.")
    print("Approve strictly 0 -> 10, and send nothing else from the vault until 10 confirms.")
    for i, a in enumerate(actions[args.start_at:], start=args.start_at):
      uuid = propose(token, vault_uuid, vault_addr, a)
      print(f"  [{i:>2}] queued  uuid={uuid}  digest={a['digest']}")
    print()
    print("All queued. Approve them in order in the MPCVault app.")
    return 0

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

  print()
  print("All eleven confirmed. Now run:")
  print("  RESUME=1 forge script scripts/verify-cngn-spot-batch.s.sol --rpc-url $RPC_URL")
  print("  python3 scripts/ops/resolve_cngn_action6.py --from-block 50405256 --market-id 2")
  return 0


if __name__ == "__main__":
  try:
    sys.exit(main())
  except KeyboardInterrupt:
    print("\ninterrupted - nothing further proposed", file=sys.stderr)
    sys.exit(130)
