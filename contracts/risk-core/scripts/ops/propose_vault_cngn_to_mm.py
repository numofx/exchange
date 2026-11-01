#!/usr/bin/env python3
"""
Deposit the vault's 6,229.150178 cNGN (recovered from the v1 pool #31 on 2026-11-01) into the v2 cNGN-USDC spot maker's
account #42: propose to MPCVault, one request at a time, for a human to approve each in the app. It NEVER signs,
executes or broadcasts itself: every request is created without a callback client signer, which routes it to the
MPCVault app.

  1. cNGN.approve(cNGN escrow, 6,229.150178)
  2. cNGN escrow.deposit(42, 6,229.150178)

Each step is skipped once it reads as done, so a re-run continues where the last stopped. The dry run refuses unless
#42 sits under MarginEngine v2, the escrow wraps cNGN, the vault holds the cNGN, and each step that can be simulated now
simulates (the deposit only once the approval is on chain).

  python3 scripts/ops/propose_vault_cngn_to_mm.py --render     write the artifact and print its sheet
  python3 scripts/ops/propose_vault_cngn_to_mm.py              dry run: the artifact and the chain
  python3 scripts/ops/propose_vault_cngn_to_mm.py --propose    the above, then each step: request, wait, confirm
  python3 scripts/ops/propose_vault_cngn_to_mm.py --self-test

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
ARTIFACT = ROOT / "deployments" / "8453" / "VAULT_CNGN_TO_MM_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
ENGINE_V2 = "0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950"      # MarginEngine v2
SUB_ACCOUNTS = "0x7019244E25FA416e6Ca2ed2F3cA25277aef72843"
CNGN_ESCROW = "0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98"    # cNGN-USDC's asset
CNGN = "0x46C85152bFe9f96829aA94755D9f915F9B10EF5F"
MM_ACCOUNT = 42                   # the v2 cNGN-USDC spot maker
AMOUNT_CNGN = 6_229_150_178       # 6 dp; all the vault holds, from propose_v1_pool_close.py step 3
SELECTORS = {  # pinned by --self-test against `cast sig`
  "approve(address,uint256)": "0x095ea7b3",
  "deposit(uint256,uint256)": "0xe2bbb158",
  "getBalance(uint256,address,uint256)": "0x0806e640",
  "balanceOf(address)": "0x70a08231",
  "allowance(address,address)": "0xdd62ed3e",
  "manager(uint256)": "0x52981457",
  "wrappedAsset()": "0xd9a1836a",
}
GAS_LIMITS = ["80000", "300000"]  # fork 2026-11-01: approve 55,629, deposit 218,972
E12 = 10**12
CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60


def selector(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def digest(to: str, data: str) -> str:
  """keccak(to || keccak(data)), as propose_collateral_cap.py."""
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def word_uint(value: int) -> str:
  return format(value, "064x")


def build_actions() -> list[dict]:
  steps = [
    ("cNGN.approve(cNGN escrow, 6,229.150178 cNGN) [step 1 of 2: the deposit's allowance]", CNGN,
     SELECTORS["approve(address,uint256)"] + word_address(CNGN_ESCROW) + word_uint(AMOUNT_CNGN)),
    ("cNGN escrow.deposit(#42, 6,229.150178 cNGN) [step 2 of 2: into the v2 cNGN-USDC spot maker]", CNGN_ESCROW,
     SELECTORS["deposit(uint256,uint256)"] + word_uint(MM_ACCOUNT) + word_uint(AMOUNT_CNGN)),
  ]
  return [{"description": d, "to": to, "value": "0", "data": data, "digest": digest(to, data)} for d, to, data in steps]


EXPECTED_DIGESTS = [a["digest"] for a in build_actions()]


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-vault-cngn-to-mm-proposer/1.0"},
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


def signed(word: str) -> int:
  value = int(word, 16)
  return value - (1 << 256) if value >= 1 << 255 else value


def mm_cngn(rpc_url: str) -> int:
  """#42's ledger balance of cNGN, 18 dp, signed."""
  data = SELECTORS["getBalance(uint256,address,uint256)"] + word_uint(MM_ACCOUNT) + word_address(CNGN_ESCROW) + word_uint(0)
  return signed(call(rpc_url, SUB_ACCOUNTS, data))


def token_balance(rpc_url: str, token: str, holder: str) -> int:
  return int(call(rpc_url, token, SELECTORS["balanceOf(address)"] + word_address(holder)), 16)


def allowance(rpc_url: str, vault: str) -> int:
  return int(call(rpc_url, CNGN, SELECTORS["allowance(address,address)"] + word_address(vault) + word_address(CNGN_ESCROW)), 16)


def done(rpc_url: str, vault: str, step: int) -> bool:
  """Whether a step reads as landed: a re-run skips it. The vault held exactly the amount, so a deposit empties it."""
  deposited = token_balance(rpc_url, CNGN, vault) < AMOUNT_CNGN
  if step == 0:
    return deposited or allowance(rpc_url, vault) >= AMOUNT_CNGN
  return deposited


def load_actions() -> list[dict]:
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: write it with --render")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 2:
    raise SystemExit(f"REFUSED: expected exactly two actions, artifact has {len(actions)}")
  return actions


def verify_artifact(actions: list[dict]) -> None:
  """The artifact must be the one reviewed: these two calls, in this order, these digests, no value."""
  for i, (action, expected) in enumerate(zip(actions, build_actions())):
    if action["to"].lower() != expected["to"].lower():
      raise SystemExit(f"REFUSED: step {i + 1} targets {action['to']}, not {expected['to']}")
    if action["data"].lower()[:10] != expected["data"][:10]:
      raise SystemExit(f"REFUSED: step {i + 1} calldata is not the expected function")
    if action["data"].lower() != expected["data"].lower():
      raise SystemExit(f"REFUSED: step {i + 1} arguments differ from the reviewed amounts and addresses")
    if str(action.get("value", "0")) != "0":
      raise SystemExit(f"REFUSED: step {i + 1} sends value")
    computed = digest(action["to"], action["data"])
    if computed != action["digest"].lower() or computed != EXPECTED_DIGESTS[i]:
      raise SystemExit(f"REFUSED: step {i + 1} digest {action['digest']} / computed {computed} / expected {EXPECTED_DIGESTS[i]}")
  print("artifact ok: approve, deposit(#42) with digests " + ", ".join(EXPECTED_DIGESTS))


def verify_chain(rpc_url: str, vault: str, actions: list[dict]) -> None:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: vault {vault}, expected {EXPECTED_VAULT}")
  manager = "0x" + call(rpc_url, SUB_ACCOUNTS, SELECTORS["manager(uint256)"] + word_uint(MM_ACCOUNT))[-40:]
  if manager.lower() != ENGINE_V2.lower():
    raise SystemExit(f"REFUSED: #{MM_ACCOUNT} is under {manager}, not MarginEngine v2 {ENGINE_V2}")
  wrapped = "0x" + call(rpc_url, CNGN_ESCROW, SELECTORS["wrappedAsset()"])[-40:]
  if wrapped.lower() != CNGN.lower():
    raise SystemExit(f"REFUSED: the escrow wraps {wrapped}, not cNGN {CNGN}")
  held = token_balance(rpc_url, CNGN, vault)
  print(f"vault {held / 1e6:,.6f} cNGN; #{MM_ACCOUNT} {mm_cngn(rpc_url) / 1e18:,.6f} cNGN")
  if not done(rpc_url, vault, 1) and held < AMOUNT_CNGN:
    raise SystemExit(f"REFUSED: the vault holds {held / 1e6} cNGN, under the {AMOUNT_CNGN / 1e6} to deposit")
  for i, action in enumerate(actions):
    if done(rpc_url, vault, i):
      print(f"step {i + 1}: done")
      continue
    if i == 1 and allowance(rpc_url, vault) < AMOUNT_CNGN:
      print("step 2: simulated once step 1 lands (it needs the allowance)")
      continue
    try:
      call(rpc_url, action["to"], action["data"], vault)
    except RuntimeError as error:
      raise SystemExit(f"REFUSED: step {i + 1} does not simulate from the vault: {error}")
    print(f"step {i + 1}: simulates from the vault")
  print(f"chain ok: #{MM_ACCOUNT} under MarginEngine v2; escrow wraps cNGN; chain {chain}")


def propose(token: str, vault_uuid: str, vault_addr: str, action: dict, gas_limit: str) -> str:
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
      "gasFee": {"gasLimit": gas_limit, "maxFee": MAX_FEE_WEI},
    },
  })
  return created["signingRequest"]["uuid"]


def wait_for(token: str, rpc_url: str, uuid: str) -> None:
  deadline = time.time() + CONFIRM_TIMEOUT_SEC
  while time.time() < deadline:
    details = http_post(MPCVAULT_BASE + "getSigningRequestDetails", token, {"uuid": uuid})
    tx = (details.get("signingRequest") or {}).get("txHash")
    if tx:
      receipt = rpc(rpc_url, "eth_getTransactionReceipt", [tx])
      if receipt:
        print(f"  tx {tx} status {receipt.get('status')} block {int(receipt['blockNumber'], 16)}")
        if receipt.get("status") != "0x1":
          raise SystemExit("FAILED: the transaction reverted; nothing further is proposed")
        return
    time.sleep(CONFIRM_POLL_SEC)
  raise SystemExit(f"no transaction for request {uuid} after {CONFIRM_TIMEOUT_SEC // 60} min (not yet approved?)")


def run(token: str, vault_uuid: str, rpc_url: str, vault: str, actions: list[dict]) -> int:
  for i, action in enumerate(actions):
    if done(rpc_url, vault, i):
      print(f"step {i + 1}: done, skipped")
      continue
    if i == 1:
      try:
        call(rpc_url, action["to"], action["data"], vault)
      except RuntimeError as error:
        raise SystemExit(f"REFUSED: step 2 does not simulate from the vault: {error}")
    uuid = propose(token, vault_uuid, vault, action, GAS_LIMITS[i])
    print(f"step {i + 1}: proposed signing request {uuid}: {action['description']} (approve it in the MPCVault app)")
    wait_for(token, rpc_url, uuid)
    for _ in range(6):  # the receipt can come from a node ahead of the one answering eth_call
      if done(rpc_url, vault, i):
        break
      time.sleep(CONFIRM_POLL_SEC)
    else:
      raise SystemExit(f"FAILED: step {i + 1} landed but does not read as done 30s after the receipt")
  print(f"confirmed: #{MM_ACCOUNT} {mm_cngn(rpc_url) / 1e18:,.6f} cNGN; vault cNGN {token_balance(rpc_url, CNGN, vault) / 1e6:,.6f}")
  return 0


def render() -> int:
  actions = build_actions()
  ARTIFACT.write_text(json.dumps(actions, indent=2) + "\n")
  print(f"wrote {ARTIFACT.relative_to(ROOT)}")
  for action in actions:
    print(f"  {action['description']}")
    print(f"    to {action['to']} calldata {action['data']}")
    print(f"    digest {action['digest']}")
  return 0


def self_test() -> int:
  # every selector and signature this script pins must name a compiled function, not just match `cast sig`
  from abi_selectors import assert_script
  assert_script(__file__)
  for sig, want in SELECTORS.items():
    assert selector(sig) == want, (sig, selector(sig), want)
  assert signed("f" * 64) == -1 and signed(word_uint(5)) == 5
  # the committed artifact is the one this script builds
  verify_artifact(load_actions())
  actions = build_actions()
  approve, deposit = actions
  for broken, why in [
    ([{**approve, "to": CNGN_ESCROW}, deposit], "step 1 targets"),
    ([{**approve, "data": approve["data"][:10] + word_address(EXPECTED_VAULT) + word_uint(AMOUNT_CNGN)}, deposit], "step 1 arguments"),
    ([approve, {**deposit, "data": deposit["data"][:10] + word_uint(43) + word_uint(AMOUNT_CNGN)}], "step 2 arguments"),
    ([approve, {**deposit, "data": SELECTORS["approve(address,uint256)"] + deposit["data"][10:]}], "step 2 calldata"),
    ([approve, {**deposit, "digest": "0x" + "00" * 32}], "step 2 digest"),
    ([approve, {**deposit, "value": "1"}], "step 2 sends value"),
  ]:
    try:
      verify_artifact(broken)
    except SystemExit as refused:
      assert why in str(refused), (why, str(refused))
    else:
      raise AssertionError(f"accepted an artifact that is wrong: {why}")
  print("self-test ok: selectors match their signatures and compiled functions; the artifact is the one built here; "
        "a wrong target, spender, account, function, digest or value is refused")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose depositing the vault's cNGN into the v2 spot maker #42")
  ap.add_argument("--render", action="store_true", help="write the artifact and print its sheet")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing requests, one at a time")
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
  actions = load_actions()
  verify_artifact(actions)
  verify_chain(rpc_url, vault_addr, actions)
  if not args.propose:
    print("dry run: nothing proposed")
    return 0
  if not (token and vault_uuid):
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  return run(token, vault_uuid, rpc_url, vault_addr, actions)


if __name__ == "__main__":
  sys.exit(main())
