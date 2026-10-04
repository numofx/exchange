#!/usr/bin/env python3
"""
Step 8 of the unified-account cutover: propose Matching.setAllowedModule(old spot TradeModule, false)
to MPCVault for a human to approve. One action, from
deployments/8453/CNGN_SPOT_OLD_MODULE_RETIRE_VAULT_ACTIONS.json. It NEVER signs, executes or
broadcasts itself: the signing request is created without a callback client signer, which routes it
to the MPCVault app.

  python3 scripts/ops/propose_step8_retire_module.py              dry run: verify the artifact
                                                                 (digest, calldata) and the chain
                                                                 (module allowed, owner is the vault)
  python3 scripts/ops/propose_step8_retire_module.py --propose    the above, then one signing request
  python3 scripts/ops/propose_step8_retire_module.py --confirm <uuid>
                                                                 wait for the request's tx, then
                                                                 confirm allowedModules is false

Env (via run-with-ssm-mark.sh on the ops box): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from resolve_cngn_action6 import keccak  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_SPOT_OLD_MODULE_RETIRE_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "120000"        # setAllowedModule is one storage write plus an event
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
MATCHING = "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"
OLD_SPOT_MODULE = "0x12423B366F6F07130961900bE00d05Ea63Acd071"
EXPECTED_DIGEST = "0x87e6b9f680cf9fc94dc1d8c1bc0a264def8a2823638706c8cef43bc7b482917f"
CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60


def selector(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def digest(to: str, data: str) -> str:
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-step8-proposer/1.0"},
    method="POST")
  with urllib.request.urlopen(req, timeout=20) as resp:
    return json.loads(resp.read())


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-ops/1.0"}, method="POST")
  with urllib.request.urlopen(req, timeout=20) as resp:
    payload = json.loads(resp.read())
  if "error" in payload:
    raise RuntimeError(f"{method}: {payload['error']}")
  return payload["result"]


def call(rpc_url: str, to: str, data: str) -> str:
  return rpc(rpc_url, "eth_call", [{"to": to, "data": data}, "latest"])


def input_b64(calldata_hex: str) -> str:
  return base64.b64encode(bytes.fromhex(calldata_hex.removeprefix("0x"))).decode()


def load_action() -> dict:
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 1:
    raise SystemExit(f"REFUSED: expected exactly one action, artifact has {len(actions)}")
  return actions[0]


def verify_artifact(action: dict) -> None:
  """The artifact must be the one reviewed: this target, this calldata, this digest."""
  expected_data = selector("setAllowedModule(address,bool)") + OLD_SPOT_MODULE[2:].lower().rjust(64, "0") + "0" * 64
  if action["to"].lower() != MATCHING.lower():
    raise SystemExit(f"REFUSED: target {action['to']} is not Matching {MATCHING}")
  if action["data"].lower() != expected_data.lower():
    raise SystemExit("REFUSED: calldata is not setAllowedModule(old spot module, false)")
  if str(action.get("value", "0")) != "0":
    raise SystemExit("REFUSED: the action sends value")
  computed = digest(action["to"], action["data"])
  if computed != action["digest"].lower() or computed != EXPECTED_DIGEST:
    raise SystemExit(f"REFUSED: digest {action['digest']} / computed {computed} / expected {EXPECTED_DIGEST}")
  print(f"artifact ok: to {action['to']}, selector {expected_data[:10]}, digest {computed}")


def module_allowed(rpc_url: str) -> bool:
  raw = call(rpc_url, MATCHING, selector("allowedModules(address)") + OLD_SPOT_MODULE[2:].lower().rjust(64, "0"))
  return int(raw, 16) == 1


def verify_chain(rpc_url: str, vault: str) -> None:
  owner = "0x" + call(rpc_url, MATCHING, selector("owner()"))[-40:]
  if owner.lower() != vault.lower() or owner.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: Matching.owner() is {owner}, vault {vault}, expected {EXPECTED_VAULT}")
  if not module_allowed(rpc_url):
    raise SystemExit("REFUSED: the old spot module is already not allowed; nothing to retire")
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  print(f"chain ok: Matching.owner() is the vault {owner}; allowedModules({OLD_SPOT_MODULE}) = true; chain {chain}")


def propose(token: str, vault_uuid: str, vault_addr: str, action: dict) -> str:
  created = http_post(MPCVAULT_BASE + "createSigningRequest", token, {
    "vaultUuid": vault_uuid,
    # No callbackClientSignerPublicKey: this routes the request to the app for a human to approve.
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
  return created["signingRequest"]["uuid"]


def request_tx_hash(token: str, uuid: str) -> str | None:
  details = http_post(MPCVAULT_BASE + "getSigningRequestDetails", token, {"uuid": uuid})
  return (details.get("signingRequest") or {}).get("txHash") or None


def confirm(token: str, rpc_url: str, uuid: str) -> int:
  deadline = time.time() + CONFIRM_TIMEOUT_SEC
  tx = None
  while time.time() < deadline:
    tx = request_tx_hash(token, uuid)
    if tx:
      receipt = rpc(rpc_url, "eth_getTransactionReceipt", [tx])
      if receipt:
        print(f"tx {tx} status {receipt.get('status')} block {int(receipt['blockNumber'], 16)}")
        break
    time.sleep(CONFIRM_POLL_SEC)
  else:
    print(f"no transaction for request {uuid} after {CONFIRM_TIMEOUT_SEC // 60} min (not yet approved?)")
    return 1
  if module_allowed(rpc_url):
    print("FAILED: allowedModules(old spot module) still reads true")
    return 1
  print(f"confirmed: Matching.allowedModules({OLD_SPOT_MODULE}) = false. Step 8 done.")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Step 8: propose retiring the old spot TradeModule on Matching")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing request")
  ap.add_argument("--confirm", metavar="UUID", help="wait for this request's tx and confirm on chain")
  args = ap.parse_args()
  rpc_url = os.environ.get("RPC_URL", "")
  token = os.environ.get("MPCVAULT_TOKEN", "")
  vault_uuid = os.environ.get("MPCVAULT_VAULT", "")
  vault_addr = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not rpc_url:
    raise SystemExit("RPC_URL is required")
  if args.confirm:
    if not token:
      raise SystemExit("MPCVAULT_TOKEN is required (run via run-with-ssm-mark.sh)")
    return confirm(token, rpc_url, args.confirm)
  action = load_action()
  verify_artifact(action)
  verify_chain(rpc_url, vault_addr)
  if not args.propose:
    print("dry run: nothing proposed")
    return 0
  if not (token and vault_uuid):
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  uuid = propose(token, vault_uuid, vault_addr, action)
  print(f"proposed: signing request {uuid} (approve in the MPCVault app; then --confirm {uuid})")
  return 0


if __name__ == "__main__":
  sys.exit(main())
