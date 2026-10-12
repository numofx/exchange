#!/usr/bin/env python3
"""
Retire the RfqModule: propose Matching.setAllowedModule(RfqModule, false) to MPCVault for a human to approve. One
action, from deployments/8453/RFQ_MODULE_RETIRE_VAULT_ACTIONS.json. It NEVER signs, executes or broadcasts itself: the
signing request is created without a callback client signer, which routes it to the MPCVault app.

Why: RFQ is not supported. The module has been allowed on Matching since the deployment and has never been used, but
it is a live path into every account deposited in Matching:
  - it settles its quote leg in the frozen DFXM-era cash (0x6B23...), not the perp cash, so no fill on the live perp
    SRM or the MarginEngine can succeed through it;
  - it knows neither the perp nor any future (isPerpAsset / isDatedFutureAsset are unset), so a fill it did make
    would price every leg as an option premium, and pass no fill price to a future's index-band check.
Nothing watches it. The MarginEngine enable batch (propose_margin_engine_batch.py, gate `rfq`) refuses to run while it
is allowed, so it cannot quietly come back.

Before proposing, the dry run proves the module is unused: every log it has emitted since its deployment block is an
ownership event (the deploy and the hand-over to the vault). A fill emits RFQTradeCompleted and NonceUsed, a fee
FeeCharged; any of those, or anything unrecognised, refuses.

  python3 scripts/ops/propose_retire_rfq_module.py              dry run: the artifact (target, calldata, digest), the
                                                                chain (the vault owns Matching, the module is allowed,
                                                                the vault's call simulates), and the usage scan
  python3 scripts/ops/propose_retire_rfq_module.py --propose    the above, then one signing request
  python3 scripts/ops/propose_retire_rfq_module.py --confirm <uuid>
                                                                wait for the request's tx, then confirm
                                                                allowedModules(RfqModule) reads false
  python3 scripts/ops/propose_retire_rfq_module.py --self-test

Env (via run-with-ssm-mark.sh on the ops box): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL. The usage scan
needs an RPC that serves eth_getLogs over the module's life; on a range limit it splits the range and retries.
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
ARTIFACT = ROOT / "deployments" / "8453" / "RFQ_MODULE_RETIRE_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "120000"        # setAllowedModule is one storage write plus an event
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
MATCHING = "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"      # contracts/execution/deployments/8453/matching.json
RFQ_MODULE = "0x8399328AC53a279A3564E49c2cbC82Ce95ee62D3"    # .rfq in the same file
RFQ_DEPLOY_BLOCK = 48833365  # the first block with the module's code (binary search on eth_getCode)
SELECTORS = {  # pinned by --self-test against `cast sig`
  "setAllowedModule(address,bool)": "0xb1b62825",
  "allowedModules(address)": "0x8ba5a0c2",
  "owner()": "0x8da5cb5b",
}
# Ownership events are the only ones an unused module emits: the deploy (OwnershipTransferred to the deployer), the
# nomination of the vault, and its acceptance.
OWNERSHIP_EVENTS = ("OwnershipTransferred(address,address)", "OwnershipTransferStarted(address,address)")
# What use looks like, named in the refusal.
USE_EVENTS = (
  "RFQTradeCompleted(uint256,uint256,(address,uint256,int256,int256)[])",
  "NonceUsed(address,uint256)",
  "FeeCharged(uint256,uint256,uint256)",
)
CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60


def selector(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def topic(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()


def digest(to: str, data: str) -> str:
  """keccak(to || keccak(data)), as propose_step8_retire_module.py."""
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def build_action() -> dict:
  data = SELECTORS["setAllowedModule(address,bool)"] + word_address(RFQ_MODULE) + "0" * 64
  return {
    "description": f"Matching.setAllowedModule(RfqModule {RFQ_MODULE[:10]}…, false) [RFQ is not supported: never used "
                   "since deployment, it settles in the frozen DFXM-era cash and knows neither the perp nor the future]",
    "to": MATCHING,
    "value": "0",
    "data": data,
    "digest": digest(MATCHING, data),
  }


EXPECTED_DIGEST = build_action()["digest"]


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-rfq-retire-proposer/1.0"},
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


def load_action() -> dict:
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: write it with --render")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 1:
    raise SystemExit(f"REFUSED: expected exactly one action, artifact has {len(actions)}")
  return actions[0]


def verify_artifact(action: dict) -> None:
  """The artifact must be the one reviewed: Matching, setAllowedModule(RfqModule, false), this digest, no value."""
  expected = build_action()
  if action["to"].lower() != MATCHING.lower():
    raise SystemExit(f"REFUSED: target {action['to']} is not Matching {MATCHING}")
  if action["data"].lower() != expected["data"].lower():
    raise SystemExit("REFUSED: calldata is not setAllowedModule(RfqModule, false)")
  if str(action.get("value", "0")) != "0":
    raise SystemExit("REFUSED: the action sends value")
  computed = digest(action["to"], action["data"])
  if computed != action["digest"].lower() or computed != EXPECTED_DIGEST:
    raise SystemExit(f"REFUSED: digest {action['digest']} / computed {computed} / expected {EXPECTED_DIGEST}")
  print(f"artifact ok: to {action['to']}, setAllowedModule(RfqModule, false), digest {computed}")


def module_allowed(rpc_url: str) -> bool:
  return int(call(rpc_url, MATCHING, SELECTORS["allowedModules(address)"] + word_address(RFQ_MODULE)), 16) == 1


def module_logs(rpc_url: str, start: int, end: int) -> list[dict]:
  """Every log the module emitted in [start, end], splitting the range when the RPC refuses it as too large."""
  try:
    return rpc(rpc_url, "eth_getLogs", [{"address": RFQ_MODULE, "fromBlock": hex(start), "toBlock": hex(end)}])
  except RuntimeError as error:
    if end <= start:
      raise
    print(f"  eth_getLogs [{start}, {end}] refused ({str(error)[:80]}); splitting")
    mid = (start + end) // 2
    return module_logs(rpc_url, start, mid) + module_logs(rpc_url, mid + 1, end)


def classify_usage(logs: list[dict]) -> tuple[int, list[str]]:
  """(ownership events, refusals): any log that is not an ownership event is use, or unrecognised."""
  ownership = {topic(s) for s in OWNERSHIP_EVENTS}
  named = {topic(s): s.split("(")[0] for s in USE_EVENTS}
  refusals = []
  for log in logs:
    t0 = (log.get("topics") or ["0x"])[0].lower()
    if t0 in ownership:
      continue
    what = named.get(t0, f"an unrecognised event {t0[:10]}")
    refusals.append(f"{what} at block {int(log['blockNumber'], 16)} (tx {log.get('transactionHash')})")
  return len(logs) - len(refusals), refusals


def verify_unused(rpc_url: str) -> None:
  head = int(rpc(rpc_url, "eth_blockNumber", []), 16)
  logs = module_logs(rpc_url, RFQ_DEPLOY_BLOCK, head)
  ownership, refusals = classify_usage(logs)
  if refusals:
    raise SystemExit(f"REFUSED: the RfqModule has been used ({len(refusals)} log(s)); find who sends through it first: "
                     + "; ".join(refusals[:3]))
  if ownership == 0:
    raise SystemExit("REFUSED: the scan found no logs at all, not even the deploy's ownership event: the scan is broken")
  print(f"usage ok: blocks {RFQ_DEPLOY_BLOCK}-{head}, {ownership} log(s), all ownership; no fill, nonce or fee, ever")


def verify_chain(rpc_url: str, vault: str) -> None:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  owner = "0x" + call(rpc_url, MATCHING, SELECTORS["owner()"])[-40:]
  if owner.lower() != vault.lower() or owner.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: Matching.owner() is {owner}, vault {vault}, expected {EXPECTED_VAULT}")
  if not module_allowed(rpc_url):
    raise SystemExit("REFUSED: the RfqModule is already not allowed; nothing to retire")
  try:
    call(rpc_url, MATCHING, build_action()["data"], vault)
  except RuntimeError as error:
    raise SystemExit(f"REFUSED: the vault's call does not simulate: {error}")
  print(f"chain ok: Matching owned by the vault {owner}; allowedModules(RfqModule) = true; the vault's call simulates; "
        f"chain {chain}")


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
    if not module_allowed(rpc_url):
      break
    time.sleep(CONFIRM_POLL_SEC)
  else:
    print("FAILED: allowedModules(RfqModule) still reads true 30s after the receipt")
    return 1
  print(f"confirmed: Matching.allowedModules({RFQ_MODULE}) = false. RFQ is retired.")
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
  for sig, want in SELECTORS.items():
    assert selector(sig) == want, (sig, selector(sig), want)
  # the committed artifact is the one this script builds
  verify_artifact(load_action())
  action = build_action()
  for broken, why in [
    ({**action, "to": RFQ_MODULE}, "not Matching"),
    ({**action, "data": action["data"][:-1] + "1"}, "calldata"),  # setAllowedModule(rfq, true)
    ({**action, "data": action["data"][:10] + word_address(EXPECTED_VAULT) + "0" * 64}, "calldata"),
    ({**action, "digest": "0x" + "00" * 32}, "digest"),
    ({**action, "value": "1"}, "sends value"),
  ]:
    try:
      verify_artifact(broken)
    except SystemExit as refused:
      assert why in str(refused), (why, str(refused))
    else:
      raise AssertionError(f"accepted an artifact that is wrong: {why}")
  # the usage scan: ownership events pass; a fill, a nonce, a fee or anything unknown refuses
  log = lambda sig_or_topic, block=1: {  # noqa: E731
    "topics": [sig_or_topic if sig_or_topic.startswith("0x") else topic(sig_or_topic)], "blockNumber": hex(block),
    "transactionHash": "0xabc"}
  assert classify_usage([log(OWNERSHIP_EVENTS[0]), log(OWNERSHIP_EVENTS[1])]) == (2, [])
  for event in USE_EVENTS:
    count, refusals = classify_usage([log(OWNERSHIP_EVENTS[0]), log(event, 7)])
    assert count == 1 and len(refusals) == 1 and event.split("(")[0] in refusals[0] and "block 7" in refusals[0], refusals
  assert "unrecognised" in classify_usage([log("0x" + "11" * 32)])[1][0]
  # the RFQ events named here are the module's own (forge inspect RfqModule events)
  assert topic(USE_EVENTS[0]) == "0xb1228604b5fbea31b1d103e2e7b495d2b99f8f1cc6445c21c2e11846cf5b4d68", "RFQTradeCompleted"
  assert topic(USE_EVENTS[1]) == "0x2af71f10069c28afc67c3752e87e0e4616a97948d33c8f404a856c0c334b3e01", "NonceUsed"
  assert topic(USE_EVENTS[2]) == "0xaad61a9664bc6be1128f98485df350d149d1d8f3dce21e21c1741501960b8809", "FeeCharged"
  print("self-test ok: selectors and event topics match; the artifact is the one built here; a wrong target, "
        "calldata, digest or value is refused; any use of the module refuses the proposal")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose retiring the RfqModule on Matching")
  ap.add_argument("--render", action="store_true", help="write the artifact and print its sheet")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing request")
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
  verify_unused(rpc_url)
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
