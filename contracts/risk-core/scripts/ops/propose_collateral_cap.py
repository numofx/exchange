#!/usr/bin/env python3
"""
Raise the cNGN collateral cap: propose escrow.setTotalPositionCap(srm, cap) to MPCVault for a human to approve. One
action, from deployments/8453/CNGN_COLLATERAL_CAP_VAULT_ACTIONS.json. It NEVER signs, executes or broadcasts itself:
the signing request is created without a callback client signer, which routes it to the MPCVault app.

Why it matters: the cap is summed over every account under the perp SRM, and since the 2026-10-04 unified cutover
that is spot inventory as well as perp margin; a deposit that would cross it reverts BM_AssetCapExceeded. It is also
the venue's maximum loan book (docs/cngn-perp-go-live.md): cNGN margins at 50%, so borrowing against it can reach
half its value. So the cap only goes up, and never past the perp's own open-interest cap.

  python3 scripts/ops/propose_collateral_cap.py --render --cap-cngn 50000000
                                                      write the artifact and print its sheet
  python3 scripts/ops/propose_collateral_cap.py      dry run: verify the artifact and the chain (the vault owns the
                                                      escrow, the cap rises, the vault's call simulates)
  python3 scripts/ops/propose_collateral_cap.py --propose --expect-digest 0x...
                                                      the above, then one signing request for the reviewed digest
  python3 scripts/ops/propose_collateral_cap.py --confirm <uuid>
                                                      wait for the request's tx, then confirm the cap reads the value
  python3 scripts/ops/propose_collateral_cap.py --self-test

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
ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_COLLATERAL_CAP_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "120000"        # one storage write plus an event
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
ESCROW = "0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98"   # CNGN_PERP_COLLATERAL.json .escrow
SRM = "0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4"      # CNGN_PERP_COLLATERAL.json .srm
PERP = "0xC74EfC8B4808803dBCF439E76Fde076d56625b8E"     # its totalPositionCap(srm) is the open-interest cap
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
  """keccak(to || keccak(data)), as propose_perp_funding_rate.py."""
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def build_action(cap_cngn: int) -> dict:
  cap = cap_cngn * E18
  data = selector(SIGNATURE) + word_address(SRM) + f"{cap:064x}"
  return {
    "description": f"cNGN escrow.setTotalPositionCap(perp SRM, {cap_cngn:,} cNGN)",
    "to": ESCROW,
    "value": "0",
    "data": data,
    "digest": digest(ESCROW, data),
    "cap_e18": str(cap),
  }


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-collateral-cap-proposer/1.0"},
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


def call(rpc_url: str, to: str, data: str, sender: str | None = None) -> str:
  tx = {"to": to, "data": data}
  if sender:
    tx["from"] = sender
  return rpc(rpc_url, "eth_call", [tx, "latest"])


def read_uint(rpc_url: str, to: str, sig: str, *address_args: str) -> int:
  return int(call(rpc_url, to, selector(sig) + "".join(word_address(a) for a in address_args)), 16)


def load_action() -> dict:
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: render one with --render --cap-cngn <whole cNGN>")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 1:
    raise SystemExit(f"REFUSED: expected exactly one action, artifact has {len(actions)}")
  return actions[0]


def verify_artifact(action: dict) -> int:
  """The artifact must be the one reviewed: this escrow, this function, the perp SRM, this digest."""
  data = action["data"].lower()
  if action["to"].lower() != ESCROW.lower():
    raise SystemExit(f"REFUSED: target {action['to']} is not the cNGN escrow {ESCROW}")
  if not data.startswith(SELECTORS[SIGNATURE]) or len(data) != 2 + 8 + 64 + 64:
    raise SystemExit(f"REFUSED: calldata is not {SIGNATURE}")
  if data[10:74] != word_address(SRM):
    raise SystemExit(f"REFUSED: the manager word is not the perp SRM {SRM}")
  cap = int(data[74:], 16)
  if str(cap) != str(action.get("cap_e18")):
    raise SystemExit(f"REFUSED: calldata cap {cap} differs from the artifact's cap_e18 {action.get('cap_e18')}")
  if str(action.get("value", "0")) != "0":
    raise SystemExit("REFUSED: the action sends value")
  computed = digest(action["to"], action["data"])
  if computed != action["digest"].lower():
    raise SystemExit(f"REFUSED: digest {action['digest']} / computed {computed}")
  print(f"artifact ok: {action['description']}, digest {computed}")
  return cap


def verify_chain(rpc_url: str, vault: str, new_cap: int) -> None:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  owner = "0x" + call(rpc_url, ESCROW, SELECTORS["owner()"])[-40:]
  if owner.lower() != vault.lower() or owner.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: escrow.owner() is {owner}, vault {vault}, expected {EXPECTED_VAULT}")
  current = read_uint(rpc_url, ESCROW, "totalPositionCap(address)", SRM)
  posted = read_uint(rpc_url, ESCROW, "totalPosition(address)", SRM)
  oi_cap = read_uint(rpc_url, PERP, "totalPositionCap(address)", SRM)
  if new_cap <= current:
    raise SystemExit(f"REFUSED: the cap only goes up here; it reads {current // E18:,} cNGN, the artifact sets {new_cap // E18:,}")
  if new_cap > oi_cap:
    raise SystemExit(f"REFUSED: {new_cap // E18:,} cNGN is past the perp's open-interest cap of {oi_cap // E18:,}; "
                     "raise that first, through its own review")
  try:
    call(rpc_url, ESCROW, load_action()["data"], vault)
  except RuntimeError as error:
    raise SystemExit(f"REFUSED: the vault's call does not simulate: {error}")
  print(f"chain ok: escrow owned by the vault; cap {current // E18:,} -> {new_cap // E18:,} cNGN "
        f"({posted // E18:,} posted); perp open-interest cap {oi_cap // E18:,}; the vault's call simulates; chain {chain}")


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


def confirm(token: str, rpc_url: str, uuid: str, new_cap: int) -> int:
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
    if read_uint(rpc_url, ESCROW, "totalPositionCap(address)", SRM) == new_cap:
      break
    time.sleep(CONFIRM_POLL_SEC)
  else:
    print(f"FAILED: totalPositionCap(srm) still does not read {new_cap // E18:,} cNGN 30s after the receipt")
    return 1
  print(f"confirmed: the cNGN escrow's cap under the perp SRM is {new_cap // E18:,} cNGN. GET /v1/perp/state serves it as "
        "collateral_assets[].cap, and the deposit API's room check reads it per request.")
  return 0


def render(cap_cngn: int) -> int:
  if cap_cngn <= 0:
    raise SystemExit("REFUSED: --cap-cngn is a positive number of whole cNGN")
  action = build_action(cap_cngn)
  ARTIFACT.write_text(json.dumps([action], indent=2) + "\n")
  print(f"wrote {ARTIFACT.relative_to(ROOT)}")
  print(f"  {action['description']}")
  print(f"  calldata {action['data']}")
  print(f"  digest   {action['digest']}")
  return 0


def self_test() -> int:
  for sig, want in SELECTORS.items():
    assert selector(sig) == want, (sig, selector(sig), want)
  action = build_action(50_000_000)
  assert verify_artifact(action) == 50_000_000 * E18
  for broken, why in [
    ({**action, "to": PERP}, "not the cNGN escrow"),
    ({**action, "data": action["data"][:10] + word_address(PERP) + action["data"][74:]}, "not the perp SRM"),
    ({**action, "cap_e18": "1"}, "differs from"),
    ({**action, "digest": "0x" + "00" * 32}, "digest"),
    ({**action, "value": "1"}, "sends value"),
  ]:
    try:
      verify_artifact(broken)
    except SystemExit as refused:
      assert why in str(refused), (why, str(refused))
    else:
      raise AssertionError(f"accepted an artifact that is {why}")
  print("self-test ok: selectors match their signatures, and a wrong target, manager, cap, digest or value is refused")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose raising the cNGN escrow's collateral cap under the perp SRM")
  ap.add_argument("--render", action="store_true", help="write the artifact for --cap-cngn and print its sheet")
  ap.add_argument("--cap-cngn", type=int, help="the new cap in whole cNGN, e.g. 50000000")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing request")
  ap.add_argument("--expect-digest", help="the reviewed digest; --propose refuses any other artifact")
  ap.add_argument("--confirm", metavar="UUID", help="wait for this request's tx and confirm on chain")
  ap.add_argument("--self-test", action="store_true")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  if args.render:
    if args.cap_cngn is None:
      raise SystemExit("--render needs --cap-cngn")
    return render(args.cap_cngn)
  rpc_url = os.environ.get("RPC_URL", "")
  token = os.environ.get("MPCVAULT_TOKEN", "")
  vault_uuid = os.environ.get("MPCVAULT_VAULT", "")
  vault_addr = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not rpc_url:
    raise SystemExit("RPC_URL is required")
  action = load_action()
  new_cap = verify_artifact(action)
  if args.confirm:
    if not token:
      raise SystemExit("MPCVAULT_TOKEN is required (run via run-with-ssm-mark.sh)")
    return confirm(token, rpc_url, args.confirm, new_cap)
  verify_chain(rpc_url, vault_addr, new_cap)
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
