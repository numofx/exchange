#!/usr/bin/env python3
"""
Close out the v1 MarginEngine's VM pool (#31, the engine's own account): propose to MPCVault, one request at a time,
for a human to approve each in the app. It NEVER signs, executes or broadcasts itself: every request is created
without a callback client signer, which routes it to the MPCVault app.

  1. USDC.approve(CashAsset, 4.85 USDC)
  2. CashAsset.deposit(31, 4.85 USDC)                                  repays the pool's -4.81 USDC borrow
  3. MarginEngine v1.withdrawFromPool(cNGN escrow, 6,229.150178, vault) recovers the pool's cNGN

Why: v1 has taken no position since 2026-10-31 (its future's total position is 0, its makers moved to v2), but its
pool was left at -4.81 USDC of cash, a borrow from the USDC CashAsset v2 shares that accrues interest and that nothing
can liquidate (the account is the engine's), beside 6,229 cNGN that only the owner's withdrawFromPool can move. The
deposit is a little over the debt so interest accrued before it lands is covered; what is left over stays in the pool.

The vault holds no USDC of its own: 4.85 USDC must be sent to it first. Each step is skipped once it reads as done, so a
re-run continues where the last stopped. The dry run refuses unless the vault owns the engine, the engine's pool is
#31, the pool is short at most the deposit and holds the cNGN, the vault holds the USDC, and each step that can be
simulated now simulates (the deposit only once the approval is on chain).

  python3 scripts/ops/propose_v1_pool_close.py --render     write the artifact and print its sheet
  python3 scripts/ops/propose_v1_pool_close.py              dry run: the artifact and the chain
  python3 scripts/ops/propose_v1_pool_close.py --propose    the above, then each step: request, wait, confirm
  python3 scripts/ops/propose_v1_pool_close.py --self-test

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
ARTIFACT = ROOT / "deployments" / "8453" / "V1_POOL_CLOSE_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
ENGINE = "0xA19E296021c9DF25b90D96C2A0793CC3D0800758"         # MarginEngine v1
SUB_ACCOUNTS = "0x7019244E25FA416e6Ca2ed2F3cA25277aef72843"
CASH = "0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272"           # the USDC CashAsset, shared with v2
CNGN_ESCROW = "0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98"    # cNGN-USDC's asset
USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
CNGN = "0x46C85152bFe9f96829aA94755D9f915F9B10EF5F"
POOL_ACCOUNT = 31
DEPOSIT_USDC = 4_850_000          # 6 dp; the pool read -4.813539 USDC on 2026-11-01
WITHDRAW_CNGN = 6_229_150_178     # 6 dp; the pool's whole 6,229.150178786 cNGN, the rest is dust
SELECTORS = {  # pinned by --self-test against `cast sig`
  "approve(address,uint256)": "0x095ea7b3",
  "deposit(uint256,uint256)": "0xe2bbb158",
  "withdrawFromPool(address,uint256,address)": "0xfac95a9e",
  "getBalance(uint256,address,uint256)": "0x0806e640",
  "balanceOf(address)": "0x70a08231",
  "allowance(address,address)": "0xdd62ed3e",
  "owner()": "0x8da5cb5b",
  "accId()": "0x96964a22",
}
GAS_LIMITS = ["80000", "300000", "300000"]  # fork 2026-11-01: deposit 181,337, withdrawFromPool 206,209
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
    ("USDC.approve(CashAsset, 4.85 USDC) [step 1 of 3: the deposit's allowance]", USDC,
     SELECTORS["approve(address,uint256)"] + word_address(CASH) + word_uint(DEPOSIT_USDC)),
    ("CashAsset.deposit(#31, 4.85 USDC) [step 2 of 3: repays the v1 pool's -4.81 USDC borrow]", CASH,
     SELECTORS["deposit(uint256,uint256)"] + word_uint(POOL_ACCOUNT) + word_uint(DEPOSIT_USDC)),
    ("MarginEngine v1.withdrawFromPool(cNGN escrow, 6,229.150178 cNGN, vault) [step 3 of 3: the pool's cNGN]", ENGINE,
     SELECTORS["withdrawFromPool(address,uint256,address)"] + word_address(CNGN_ESCROW) + word_uint(WITHDRAW_CNGN)
     + word_address(EXPECTED_VAULT)),
  ]
  return [{"description": d, "to": to, "value": "0", "data": data, "digest": digest(to, data)} for d, to, data in steps]


EXPECTED_DIGESTS = [a["digest"] for a in build_actions()]


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-v1-pool-close-proposer/1.0"},
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


def pool_balance(rpc_url: str, asset: str) -> int:
  """#31's ledger balance of an asset, 18 dp, signed."""
  data = SELECTORS["getBalance(uint256,address,uint256)"] + word_uint(POOL_ACCOUNT) + word_address(asset) + word_uint(0)
  return signed(call(rpc_url, SUB_ACCOUNTS, data))


def token_balance(rpc_url: str, token: str, holder: str) -> int:
  return int(call(rpc_url, token, SELECTORS["balanceOf(address)"] + word_address(holder)), 16)


def allowance(rpc_url: str, vault: str) -> int:
  return int(call(rpc_url, USDC, SELECTORS["allowance(address,address)"] + word_address(vault) + word_address(CASH)), 16)


def done(rpc_url: str, vault: str, step: int) -> bool:
  """Whether a step reads as landed: a re-run skips it."""
  repaid = pool_balance(rpc_url, CASH) >= 0
  if step == 0:
    return repaid or allowance(rpc_url, vault) >= DEPOSIT_USDC
  if step == 1:
    return repaid
  return pool_balance(rpc_url, CNGN_ESCROW) < WITHDRAW_CNGN * E12


def load_actions() -> list[dict]:
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: write it with --render")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 3:
    raise SystemExit(f"REFUSED: expected exactly three actions, artifact has {len(actions)}")
  return actions


def verify_artifact(actions: list[dict]) -> None:
  """The artifact must be the one reviewed: these three calls, in this order, these digests, no value."""
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
  print("artifact ok: approve, deposit(#31), withdrawFromPool(cNGN) with digests " + ", ".join(EXPECTED_DIGESTS))


def verify_chain(rpc_url: str, vault: str, actions: list[dict]) -> None:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  owner = "0x" + call(rpc_url, ENGINE, SELECTORS["owner()"])[-40:]
  if owner.lower() != vault.lower() or owner.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: MarginEngine v1 owner() is {owner}, vault {vault}, expected {EXPECTED_VAULT}")
  pool = int(call(rpc_url, ENGINE, SELECTORS["accId()"]), 16)
  if pool != POOL_ACCOUNT:
    raise SystemExit(f"REFUSED: the engine's pool is #{pool}, not #{POOL_ACCOUNT}")
  cash = pool_balance(rpc_url, CASH)
  cngn = pool_balance(rpc_url, CNGN_ESCROW)
  print(f"pool #{POOL_ACCOUNT}: cash {cash / 1e18:.6f} USDC, {cngn / 1e18:,.6f} cNGN")
  if cash < 0 and -cash >= DEPOSIT_USDC * E12:
    raise SystemExit(f"REFUSED: the pool is short {-cash / 1e18:.6f} USDC, more than the {DEPOSIT_USDC / 1e6} deposit")
  if not done(rpc_url, vault, 2) and cngn < WITHDRAW_CNGN * E12:
    raise SystemExit(f"REFUSED: the pool holds {cngn / 1e18} cNGN, under the {WITHDRAW_CNGN / 1e6} to withdraw")
  if not done(rpc_url, vault, 1):
    usdc = token_balance(rpc_url, USDC, vault)
    if usdc < DEPOSIT_USDC:
      raise SystemExit(f"REFUSED: the vault holds {usdc / 1e6} USDC, under the {DEPOSIT_USDC / 1e6} to deposit: send it USDC first")
  for i, action in enumerate(actions):
    if done(rpc_url, vault, i):
      print(f"step {i + 1}: done")
      continue
    if i == 1 and allowance(rpc_url, vault) < DEPOSIT_USDC:
      print("step 2: simulated once step 1 lands (it needs the allowance)")
      continue
    try:
      call(rpc_url, action["to"], action["data"], vault)
    except RuntimeError as error:
      raise SystemExit(f"REFUSED: step {i + 1} does not simulate from the vault: {error}")
    print(f"step {i + 1}: simulates from the vault")
  print(f"chain ok: v1 engine owned by the vault {owner}; pool #{pool}; chain {chain}")


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
  cash = pool_balance(rpc_url, CASH)
  cngn = pool_balance(rpc_url, CNGN_ESCROW)
  print(f"confirmed: pool #{POOL_ACCOUNT} cash {cash / 1e18:.6f} USDC, {cngn / 1e18:.12f} cNGN; "
        f"vault cNGN {token_balance(rpc_url, CNGN, vault) / 1e6:,.6f}")
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
  approve, deposit, withdraw = actions
  for broken, why in [
    ([{**approve, "to": CASH}, deposit, withdraw], "step 1 targets"),
    ([approve, {**deposit, "data": deposit["data"][:10] + word_uint(32) + word_uint(DEPOSIT_USDC)}, withdraw], "step 2 arguments"),
    ([approve, deposit, {**withdraw, "data": withdraw["data"][:-40] + "00" * 20}], "step 3 arguments"),
    ([approve, deposit, {**withdraw, "data": SELECTORS["owner()"] + withdraw["data"][10:]}], "step 3 calldata"),
    ([approve, {**deposit, "digest": "0x" + "00" * 32}, withdraw], "step 2 digest"),
    ([approve, deposit, {**withdraw, "value": "1"}], "step 3 sends value"),
  ]:
    try:
      verify_artifact(broken)
    except SystemExit as refused:
      assert why in str(refused), (why, str(refused))
    else:
      raise AssertionError(f"accepted an artifact that is wrong: {why}")
  print("self-test ok: selectors match their signatures and compiled functions; the artifact is the one built here; "
        "a wrong target, account, recipient, function, digest or value is refused")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose closing out the v1 MarginEngine's VM pool")
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
