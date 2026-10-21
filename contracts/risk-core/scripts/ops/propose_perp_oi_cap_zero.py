#!/usr/bin/env python3
"""
Lock the delisted perp on chain: propose PerpAsset.setTotalPositionCap(perp SRM, 0) to MPCVault for a human to
approve. One action, from deployments/8453/PERP_OI_CAP_ZERO_VAULT_ACTIONS.json. It NEVER signs, executes or
broadcasts itself: the signing request is created without a callback client signer, which routes it to the MPCVault
app.

Why: the perp is delisted from the venue (exchange #251), but the venue is not the only way to open a position.
Matching takes trades from the trade executor only, yet SubAccounts.submitTransfer lets the owner of two accounts
under the perp SRM move a perp position between them directly, limited by margin and by this cap (50M). A position
opened that way would need the perp's keeper, feeds and auction to stay up for a market nobody lists. With the cap at
zero no transfer can raise open interest; closing (lowering it) is unaffected.

Side effect: propose_collateral_cap.py refuses a cNGN collateral cap above this one, so the perp SRM's cNGN cap can no
longer be raised. Nothing live needs it: spot and the future are margined under the MarginEngine, whose caps are
separate (escrow.totalPositionCap(engine)).

The dry run refuses unless the vault owns the perp, the cap is above zero, open interest under the SRM is zero, and the
vault's call simulates.

  python3 scripts/ops/propose_perp_oi_cap_zero.py --render     write the artifact and print its sheet
  python3 scripts/ops/propose_perp_oi_cap_zero.py              dry run: the artifact and the chain
  python3 scripts/ops/propose_perp_oi_cap_zero.py --propose --expect-digest 0x...
                                                               the above, then one signing request for that digest
  python3 scripts/ops/propose_perp_oi_cap_zero.py --confirm <uuid>
                                                               wait for the request's tx, then confirm the cap is 0
  python3 scripts/ops/propose_perp_oi_cap_zero.py --self-test

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
ARTIFACT = ROOT / "deployments" / "8453" / "PERP_OI_CAP_ZERO_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "120000"        # one storage write plus an event
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
PERP = "0xC74EfC8B4808803dBCF439E76Fde076d56625b8E"     # CNGN_PERP_STACK.json .perp
SRM = "0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4"      # CNGN_PERP_STACK.json .srm
SIGNATURE = "setTotalPositionCap(address,uint256)"
SELECTORS = {  # pinned by --self-test against `cast sig`
  SIGNATURE: "0x40a557bd",
  "totalPositionCap(address)": "0x745ab570",
  "totalPosition(address)": "0xa9578774",
  "owner()": "0x8da5cb5b",
}
E18 = 10**18
CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60


def selector(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def digest(to: str, data: str) -> str:
  """keccak(to || keccak(data)), as propose_collateral_cap.py."""
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def build_action() -> dict:
  data = SELECTORS[SIGNATURE] + word_address(SRM) + "0" * 64
  return {
    "description": "PerpAsset.setTotalPositionCap(perp SRM, 0) [the perp is delisted: no new open interest on chain, "
                   "closing unaffected]",
    "to": PERP,
    "value": "0",
    "data": data,
    "digest": digest(PERP, data),
  }


EXPECTED_DIGEST = build_action()["digest"]


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-perp-oi-cap-proposer/1.0"},
    method="POST")
  with urllib.request.urlopen(req, timeout=20) as resp:
    return json.loads(resp.read())


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-ops/1.0"}, method="POST")
  with urllib.request.urlopen(req, timeout=60) as resp:
    payload = json.loads(resp.read())
  if "error" in payload:
    raise RuntimeError(f"{method}: {payload['error']}")
  return payload["result"]


def call(rpc_url: str, to: str, data: str, sender: str | None = None) -> str:
  tx = {"to": to, "data": data}
  if sender:
    tx["from"] = sender
  return rpc(rpc_url, "eth_call", [tx, "latest"])


def read_uint(rpc_url: str, sig: str) -> int:
  return int(call(rpc_url, PERP, SELECTORS[sig] + word_address(SRM)), 16)


def load_action() -> dict:
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: write it with --render")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 1:
    raise SystemExit(f"REFUSED: expected exactly one action, artifact has {len(actions)}")
  return actions[0]


def verify_artifact(action: dict) -> None:
  """The artifact must be the one reviewed: the PerpAsset, setTotalPositionCap(perp SRM, 0), this digest, no value."""
  expected = build_action()
  if action["to"].lower() != PERP.lower():
    raise SystemExit(f"REFUSED: target {action['to']} is not the PerpAsset {PERP}")
  data = action["data"].lower()
  if data[:10] != SELECTORS[SIGNATURE]:
    raise SystemExit(f"REFUSED: calldata is not {SIGNATURE}")
  if data[10:74] != word_address(SRM):
    raise SystemExit("REFUSED: the manager is not the perp SRM")
  if data != expected["data"].lower():
    raise SystemExit("REFUSED: the cap is not zero")
  if str(action.get("value", "0")) != "0":
    raise SystemExit("REFUSED: the action sends value")
  computed = digest(action["to"], action["data"])
  if computed != action["digest"].lower() or computed != EXPECTED_DIGEST:
    raise SystemExit(f"REFUSED: digest {action['digest']} / computed {computed} / expected {EXPECTED_DIGEST}")
  print(f"artifact ok: to {action['to']}, setTotalPositionCap(perp SRM, 0), digest {computed}")


def verify_chain(rpc_url: str, vault: str) -> None:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  owner = "0x" + call(rpc_url, PERP, SELECTORS["owner()"])[-40:]
  if owner.lower() != vault.lower() or owner.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: PerpAsset.owner() is {owner}, vault {vault}, expected {EXPECTED_VAULT}")
  cap = read_uint(rpc_url, "totalPositionCap(address)")
  if cap == 0:
    raise SystemExit("REFUSED: the cap already reads 0; nothing to lock")
  open_interest = read_uint(rpc_url, "totalPosition(address)")
  if open_interest != 0:
    raise SystemExit(f"REFUSED: open interest under the perp SRM is {open_interest / E18:,} cNGN, not zero; "
                     "the perp is not empty")
  try:
    call(rpc_url, PERP, build_action()["data"], vault)
  except RuntimeError as error:
    raise SystemExit(f"REFUSED: the vault's call does not simulate: {error}")
  print(f"chain ok: PerpAsset owned by the vault {owner}; cap {cap // E18:,} -> 0; open interest 0; "
        f"the vault's call simulates; chain {chain}")


def propose(token: str, vault_uuid: str, vault_addr: str, action: dict) -> str:
  created = http_post(MPCVAULT_BASE + "createSigningRequest", token, {
    "vaultUuid": vault_uuid,
    # No callbackClientSignerPublicKey: this routes the request to the app for a human to approve.
    "broadcastTx": True,
    "evmSendCustom": {
      "chainId": str(CHAIN_ID),
      "from": vault_addr,
      "to": action["to"],
      "input": base64.b64encode(bytes.fromhex(action["data"].removeprefix("0x"))).decode(),
      "value": "0",
      "gasFee": {"gasLimit": GAS_LIMIT, "maxFee": MAX_FEE_WEI},
    },
  })
  return created["signingRequest"]["uuid"]


def confirm(token: str, rpc_url: str, uuid: str) -> int:
  deadline = time.time() + CONFIRM_TIMEOUT_SEC
  while time.time() < deadline:
    details = http_post(MPCVAULT_BASE + "getSigningRequestDetails", token, {"uuid": uuid})
    tx = (details.get("signingRequest") or {}).get("txHash")
    if tx:
      receipt = rpc(rpc_url, "eth_getTransactionReceipt", [tx])
      if receipt:
        print(f"tx {tx} status {receipt.get('status')} block {int(receipt['blockNumber'], 16)}")
        break
    time.sleep(CONFIRM_POLL_SEC)
  else:
    print(f"no transaction for request {uuid} after {CONFIRM_TIMEOUT_SEC // 60} min (not yet approved?)")
    return 1
  for _ in range(6):  # the receipt can come from a node ahead of the one answering eth_call
    if read_uint(rpc_url, "totalPositionCap(address)") == 0:
      break
    time.sleep(CONFIRM_POLL_SEC)
  else:
    print("FAILED: totalPositionCap(perp SRM) still reads above 0 30s after the receipt")
    return 1
  print(f"confirmed: PerpAsset.totalPositionCap({SRM}) = 0. The perp is locked on chain.")
  return 0


def render() -> int:
  action = build_action()
  ARTIFACT.write_text(json.dumps([action], indent=2) + "\n")
  print(f"wrote {ARTIFACT.relative_to(ROOT)}")
  print(f"  {action['description']}")
  print(f"  calldata {action['data']}")
  print(f"  digest   {action['digest']}")
  return 0


def self_test() -> int:
  # every selector and signature this script pins must name a compiled function, not just match `cast sig`
  from abi_selectors import assert_script
  assert_script(__file__)
  for sig, want in SELECTORS.items():
    assert selector(sig) == want, (sig, selector(sig), want)
  # the committed artifact is the one this script builds
  verify_artifact(load_action())
  action = build_action()
  for broken, why in [
    ({**action, "to": SRM}, "not the PerpAsset"),
    ({**action, "data": action["data"][:10] + word_address(EXPECTED_VAULT) + "0" * 64}, "not the perp SRM"),
    ({**action, "data": action["data"][:-1] + "1"}, "cap is not zero"),
    ({**action, "data": SELECTORS["owner()"] + action["data"][10:]}, "calldata is not"),
    ({**action, "digest": "0x" + "00" * 32}, "digest"),
    ({**action, "value": "1"}, "sends value"),
  ]:
    try:
      verify_artifact(broken)
    except SystemExit as refused:
      assert why in str(refused), (why, str(refused))
    else:
      raise AssertionError(f"accepted an artifact that is wrong: {why}")
  print("self-test ok: selectors match their signatures and compiled functions; the artifact is the one built here; "
        "a wrong target, manager, cap, function, digest or value is refused")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the delisted perp's open-interest cap to zero")
  ap.add_argument("--render", action="store_true", help="write the artifact and print its sheet")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing request")
  ap.add_argument("--expect-digest", help="the reviewed digest; --propose refuses any other artifact")
  ap.add_argument("--confirm", metavar="UUID", help="wait for this request's tx and confirm on chain")
  ap.add_argument("--self-test", action="store_true")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  if args.render:
    return render()
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
  if not args.expect_digest or args.expect_digest.lower() != action["digest"].lower():
    raise SystemExit("REFUSED: --propose needs --expect-digest equal to the reviewed artifact's digest")
  if not (token and vault_uuid):
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  uuid = propose(token, vault_uuid, vault_addr, action)
  print(f"proposed: signing request {uuid} (approve in the MPCVault app; then --confirm {uuid})")
  return 0


if __name__ == "__main__":
  sys.exit(main())
