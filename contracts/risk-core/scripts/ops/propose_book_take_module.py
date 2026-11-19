#!/usr/bin/env python3
"""
Turn on BookTakeModule (contracts/execution/src/modules/BookTakeModule.sol, deployed 2026-11-19): propose its vault
batch to MPCVault for a human to approve, ONE action at a time and in order. It NEVER signs, executes or broadcasts
itself: the signing request carries no callback client signer, which routes it to the MPCVault app.

The batch (contracts/execution/deployments/8453/BOOK_TAKE_MODULE_VAULT_ACTIONS.json, written by
deploy-book-take-module.s.sol):
  0. bookTake.acceptOwnership()             custody: the owner allows books, and an allowed book moves positions and
                                            cash in the accounts the module holds during a take
  1. Matching.setAllowedModule(bookTake, true)   the switch: Matching then runs signed book takes

Which one is proposed is read from chain, so the switch can never be approved ahead of custody: action 0 while the
vault is only the pending owner, action 1 once it owns the module, nothing once Matching allows it.

  python3 scripts/ops/propose_book_take_module.py               dry run: the artifact against the calldata built
                                                                here and its digests (keccak(to || data), the
                                                                deploy script's), the chain, and the next action
                                                                simulated from the vault
  python3 scripts/ops/propose_book_take_module.py --propose     the above, then one signing request for that action
  python3 scripts/ops/propose_book_take_module.py --confirm <uuid>
                                                                wait for the request's tx, then read the chain back
  python3 scripts/ops/propose_book_take_module.py --self-test

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

REPO = Path(__file__).resolve().parent.parent.parent.parent
ARTIFACT = REPO / "execution" / "deployments" / "8453" / "BOOK_TAKE_MODULE_VAULT_ACTIONS.json"
DEPLOYMENT = REPO / "execution" / "deployments" / "8453" / "BOOK_TAKE_MODULE.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "120000"        # one storage write (or two, for acceptOwnership) plus an event
MAX_FEE_WEI = "500000000"   # 0.5 gwei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
MATCHING = "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"      # contracts/execution/deployments/8453/matching.json
BOOK_TAKE = "0x1D1FcAa8C1677dF51dda4F26bc391B91b98dEBE3"     # BOOK_TAKE_MODULE.json .bookTake
DEPLOYER = "0x4FECe4c226b5eF0C235aEA97216e61b69FE5263f"      # BOOK_TAKE_MODULE.json .deployer
BOOKS = (
  "0x83C5741a24d57189379E1215F7A22d9f048E89d5",  # EURC-30NOV26 (risk-core ONCHAIN_BOOK_V2.json)
  "0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4",  # cNGN-30NOV26 (risk-core ONCHAIN_BOOK_CNGN.json)
)
SELECTORS = {  # pinned by --self-test against keccak, and by assert_script against the compiled ABIs
  "acceptOwnership()": "0x79ba5097",
  "setAllowedModule(address,bool)": "0xb1b62825",
  "allowedModules(address)": "0x8ba5a0c2",
  "owner()": "0x8da5cb5b",
  "pendingOwner()": "0xe30c3978",
  "matching()": "0xae5ec2e9",
  "allowedBooks(address)": "0x5e341ac4",
}
CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60


def selector(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def digest(to: str, data: str) -> str:
  """keccak(to || data), as deploy-book-take-module.s.sol (and deploy-wrapped-quote-trade-module.s.sol) writes it."""
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + bytes.fromhex(data.removeprefix("0x"))).hex()


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def build_actions() -> list[dict]:
  accept = SELECTORS["acceptOwnership()"]
  switch = SELECTORS["setAllowedModule(address,bool)"] + word_address(BOOK_TAKE) + "0" * 63 + "1"
  return [
    {"name": "acceptOwnership", "to": BOOK_TAKE, "data": accept, "digest": digest(BOOK_TAKE, accept)},
    {"name": "setAllowedModule(bookTake, true)", "to": MATCHING, "data": switch, "digest": digest(MATCHING, switch)},
  ]


def verify_artifact(actions: list[dict]) -> None:
  """The artifact must be exactly the two actions built here, in order, with matching digests and no value."""
  expected = build_actions()
  if len(actions) != len(expected):
    raise SystemExit(f"REFUSED: expected {len(expected)} actions, artifact has {len(actions)}")
  for i, (got, want) in enumerate(zip(actions, expected)):
    if got["to"].lower() != want["to"].lower():
      raise SystemExit(f"REFUSED: action {i} targets {got['to']}, not {want['to']}")
    if got["data"].lower() != want["data"].lower():
      raise SystemExit(f"REFUSED: action {i} calldata is not {want['name']}")
    if str(got.get("value", "0")) != "0":
      raise SystemExit(f"REFUSED: action {i} sends value")
    computed = digest(got["to"], got["data"])
    if computed != got["digest"].lower() or computed != want["digest"]:
      raise SystemExit(f"REFUSED: action {i} digest {got['digest']} / computed {computed} / expected {want['digest']}")
  print("artifact ok: " + "; ".join(f"{a['name']} -> {a['to']} digest {a['digest']}" for a in expected))


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-book-take-proposer/1.0"},
    method="POST")
  with urllib.request.urlopen(req, timeout=20) as resp:
    return json.loads(resp.read())


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-ops/1.0"},
                               method="POST")
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


def read_address(rpc_url: str, to: str, sig: str) -> str:
  return "0x" + call(rpc_url, to, SELECTORS[sig])[-40:]


def read_bool(rpc_url: str, to: str, sig: str, arg: str) -> bool:
  return int(call(rpc_url, to, SELECTORS[sig] + word_address(arg)), 16) == 1


def state(rpc_url: str) -> dict:
  return {
    "owner": read_address(rpc_url, BOOK_TAKE, "owner()").lower(),
    "pending": read_address(rpc_url, BOOK_TAKE, "pendingOwner()").lower(),
    "allowed": read_bool(rpc_url, MATCHING, "allowedModules(address)", BOOK_TAKE),
  }


def next_action(s: dict) -> int | None:
  """0 while the vault is only pending owner, 1 once it owns the module, None once Matching allows it. Anything else
  (an unexpected owner, the switch on without custody) refuses."""
  vault = EXPECTED_VAULT.lower()
  if s["allowed"]:
    if s["owner"] != vault:
      raise SystemExit(f"REFUSED: Matching allows the module but its owner is {s['owner']}, not the vault")
    return None
  if s["owner"] == DEPLOYER.lower() and s["pending"] == vault:
    return 0
  if s["owner"] == vault:
    return 1
  raise SystemExit(f"REFUSED: unexpected ownership (owner {s['owner']}, pending {s['pending']})")


def verify_chain(rpc_url: str, vault: str) -> int | None:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: VAULT_ADDRESS {vault} is not the recorded vault {EXPECTED_VAULT}")
  if read_address(rpc_url, MATCHING, "owner()").lower() != vault.lower():
    raise SystemExit("REFUSED: Matching is not owned by the vault")
  if read_address(rpc_url, BOOK_TAKE, "matching()").lower() != MATCHING.lower():
    raise SystemExit("REFUSED: the module is not wired to Matching")
  for book in BOOKS:
    if not read_bool(rpc_url, BOOK_TAKE, "allowedBooks(address)", book):
      raise SystemExit(f"REFUSED: book {book} is not allowed on the module")
  s = state(rpc_url)
  index = next_action(s)
  if index is None:
    print("chain ok: Matching already allows the module and the vault owns it; nothing to propose")
    return None
  action = build_actions()[index]
  try:
    call(rpc_url, action["to"], action["data"], vault)
  except RuntimeError as error:
    raise SystemExit(f"REFUSED: action {index} ({action['name']}) does not simulate from the vault: {error}")
  print(f"chain ok: owner {s['owner']}, pending {s['pending']}, Matching allows it: {s['allowed']}; next is action "
        f"{index} ({action['name']}), which simulates from the vault")
  return index


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
  time.sleep(CONFIRM_POLL_SEC)  # the receipt can come from a node ahead of the one answering eth_call
  s = state(rpc_url)
  print(f"after: owner {s['owner']}, pending {s['pending']}, Matching allows it: {s['allowed']}")
  return 0


def self_test() -> int:
  from abi_selectors import assert_script
  for sig, want in SELECTORS.items():
    assert selector(sig) == want, (sig, selector(sig), want)
  assert_script(__file__)
  actions = build_actions()
  # the deploy script's committed artifact is the one built here
  verify_artifact(json.loads(ARTIFACT.read_text()))
  deployed = json.loads(DEPLOYMENT.read_text())
  assert deployed["bookTake"].lower() == BOOK_TAKE.lower() and deployed["deployer"].lower() == DEPLOYER.lower()
  assert [b.lower() for b in deployed["books"]] == [b.lower() for b in BOOKS]
  # wrong artifacts are refused
  switch_off = actions[1]["data"][:-1] + "0"
  for broken, why in [
    (actions[:1], "expected 2"),
    ([actions[1], actions[0]], "targets"),
    ([actions[0], {**actions[1], "data": switch_off, "digest": digest(MATCHING, switch_off)}], "calldata"),
    ([actions[0], {**actions[1], "digest": "0x" + "00" * 32}], "digest"),
    ([{**actions[0], "value": "1"}, actions[1]], "sends value"),
  ]:
    try:
      verify_artifact(broken)
    except SystemExit as refused:
      assert why in str(refused), (why, str(refused))
    else:
      raise AssertionError(f"accepted a wrong artifact: {why}")
  # the order is read from chain: custody first, the switch only after it, never the switch without custody
  v, d, o = EXPECTED_VAULT.lower(), DEPLOYER.lower(), "0x" + "ab" * 20
  assert next_action({"owner": d, "pending": v, "allowed": False}) == 0
  assert next_action({"owner": v, "pending": "0x" + "00" * 20, "allowed": False}) == 1
  assert next_action({"owner": v, "pending": "0x" + "00" * 20, "allowed": True}) is None
  for bad in ({"owner": d, "pending": v, "allowed": True}, {"owner": o, "pending": v, "allowed": False},
              {"owner": d, "pending": o, "allowed": False}):
    try:
      next_action(bad)
    except SystemExit:
      pass
    else:
      raise AssertionError(f"accepted {bad}")
  print("self-test ok: selectors match keccak and the compiled ABIs; the artifact is the one built here; a wrong count, "
        "order, calldata, digest or value is refused; custody is always proposed before the switch")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose BookTakeModule's vault batch, one action at a time")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing request for the next action")
  ap.add_argument("--confirm", metavar="UUID", help="wait for this request's tx and read the chain back")
  ap.add_argument("--self-test", action="store_true")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
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
  verify_artifact(json.loads(ARTIFACT.read_text()))
  index = verify_chain(rpc_url, vault_addr)
  if index is None or not args.propose:
    print("dry run: nothing proposed")
    return 0
  if not (token and vault_uuid):
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  uuid = propose(token, vault_uuid, vault_addr, build_actions()[index])
  print(f"proposed action {index}: signing request {uuid} (approve in the MPCVault app; then --confirm {uuid})")
  return 0


if __name__ == "__main__":
  sys.exit(main())
