#!/usr/bin/env python3
"""
Correct the sign of the perp's static funding leg: propose PerpAsset.setStaticInterestRate(rate) to
MPCVault for a human to approve. One action, from deployments/8453/CNGN_PERP_FUNDING_RATE_VAULT_ACTIONS.json.
It NEVER signs, executes or broadcasts itself: the signing request is created without a callback
client signer, which routes it to the MPCVault app.

Why: the deployed constant is Lyra's generic +0.0000125e18 per hour ("borrow the base asset"), about
+10.95% APR, paid by on-chain longs (long cNGN). On a cNGN perp quoted in USDC the carry longs should
pay is r_USD - r_NGN, which is negative: long cNGN should RECEIVE the rate differential. The rate is
set here as -(spread APR) / 8760 per hour, with the spread the operator chooses.

  python3 scripts/ops/propose_perp_funding_rate.py --render --spread-apr 0.20
                                                      write the artifact for a 20% NGN-over-USD spread
                                                      and print its sheet (value, calldata, digest)
  python3 scripts/ops/propose_perp_funding_rate.py    dry run: verify the artifact (calldata, digest,
                                                      bound) and the chain (owner is the vault, the
                                                      rate still reads the inverted constant)
  python3 scripts/ops/propose_perp_funding_rate.py --propose --expect-digest 0x...
                                                      the above, then one signing request; the digest
                                                      must be the one reviewed
  python3 scripts/ops/propose_perp_funding_rate.py --confirm <uuid>
                                                      wait for the request's tx, then confirm
                                                      staticInterestRate() reads the new value

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
from decimal import Decimal, ROUND_HALF_EVEN
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from resolve_cngn_action6 import keccak  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
ARTIFACT = ROOT / "deployments" / "8453" / "CNGN_PERP_FUNDING_RATE_VAULT_ACTIONS.json"
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"
CHAIN_ID = 8453
GAS_LIMIT = "120000"        # one storage write plus an event
MAX_FEE_WEI = "500000000"   # 0.5 gwei, in wei
EXPECTED_VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"
PERP = "0xC74EfC8B4808803dBCF439E76Fde076d56625b8E"
SIGNATURE = "setStaticInterestRate(int256)"
# PerpAsset reverts PA_InvalidStaticInterestRate outside [-0.001e18, 0.001e18] per hour.
RATE_BOUND = 10**15
DEPLOYED_RATE = 12_500_000_000_000  # +0.0000125e18: the constant being corrected
HOURS_PER_YEAR = 8760
CONFIRM_POLL_SEC = 5
CONFIRM_TIMEOUT_SEC = 30 * 60
TWO_256 = 1 << 256


def selector(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def digest(to: str, data: str) -> str:
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def encode_int256(value: int) -> str:
  if not -(1 << 255) <= value < (1 << 255):
    raise SystemExit(f"REFUSED: {value} does not fit int256")
  return f"{value % TWO_256:064x}"


def decode_int256(word: str) -> int:
  raw = int(word, 16)
  return raw - TWO_256 if raw >= (1 << 255) else raw


def hourly_rate_e18(spread_apr: Decimal) -> int:
  """-(spread / 8760) scaled to 18 decimals, rounded half-even to the integer wei."""
  return int((-(spread_apr / Decimal(HOURS_PER_YEAR)) * Decimal(10) ** 18).quantize(Decimal(1), rounding=ROUND_HALF_EVEN))


def describe(value: int) -> str:
  hourly_pct = Decimal(value) / Decimal(10) ** 18 * 100
  apr_pct = hourly_pct * HOURS_PER_YEAR
  return f"{hourly_pct:.6f}%/h ({apr_pct:+.2f}% APR), paid by longs when positive, received by longs when negative"


def build_action(spread_apr: Decimal) -> dict:
  value = hourly_rate_e18(spread_apr)
  data = selector(SIGNATURE) + encode_int256(value)
  return {
    "description": f"perp.setStaticInterestRate(rate) [NGN-over-USD spread {spread_apr:.2%} APR -> {describe(value)}]",
    "to": PERP,
    "value": "0",
    "data": data,
    "digest": digest(PERP, data),
    "rate_e18": str(value),
    "spread_apr": str(spread_apr),
  }


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token, "User-Agent": "numo-funding-rate-proposer/1.0"},
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
  if not ARTIFACT.exists():
    raise SystemExit(f"no artifact at {ARTIFACT}: render one with --render --spread-apr <fraction>")
  actions = json.loads(ARTIFACT.read_text())
  if len(actions) != 1:
    raise SystemExit(f"REFUSED: expected exactly one action, artifact has {len(actions)}")
  return actions[0]


def verify_artifact(action: dict) -> int:
  """The artifact must be the one reviewed: this target, this function, a negative in-bound rate, this digest."""
  data = action["data"].lower()
  if action["to"].lower() != PERP.lower():
    raise SystemExit(f"REFUSED: target {action['to']} is not the perp {PERP}")
  if not data.startswith(selector(SIGNATURE)) or len(data) != 2 + 8 + 64:
    raise SystemExit(f"REFUSED: calldata is not {SIGNATURE}")
  value = decode_int256(data[10:])
  if value >= 0:
    raise SystemExit(f"REFUSED: rate {value} is not negative; the whole point is that long cNGN receives the carry")
  if abs(value) > RATE_BOUND:
    raise SystemExit(f"REFUSED: |rate| {abs(value)} exceeds the contract's bound {RATE_BOUND}")
  if str(action.get("value", "0")) != "0":
    raise SystemExit("REFUSED: the action sends value")
  if str(value) != str(action.get("rate_e18")):
    raise SystemExit(f"REFUSED: calldata rate {value} differs from the artifact's rate_e18 {action.get('rate_e18')}")
  computed = digest(action["to"], action["data"])
  if computed != action["digest"].lower():
    raise SystemExit(f"REFUSED: digest {action['digest']} / computed {computed}")
  print(f"artifact ok: to {action['to']}, {SIGNATURE} rate {value} = {describe(value)}, digest {computed}")
  return value


def read_rate(rpc_url: str) -> int:
  return decode_int256(call(rpc_url, PERP, selector("staticInterestRate()"))[2:])


def verify_chain(rpc_url: str, vault: str, new_rate: int) -> None:
  owner = "0x" + call(rpc_url, PERP, selector("owner()"))[-40:]
  if owner.lower() != vault.lower() or owner.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"REFUSED: perp.owner() is {owner}, vault {vault}, expected {EXPECTED_VAULT}")
  current = read_rate(rpc_url)
  if current == new_rate:
    raise SystemExit(f"REFUSED: staticInterestRate already reads {new_rate}; nothing to change")
  if current != DEPLOYED_RATE:
    print(f"note: staticInterestRate reads {current}, not the deployed {DEPLOYED_RATE}; someone changed it already")
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  if chain != CHAIN_ID:
    raise SystemExit(f"REFUSED: RPC is chain {chain}, not {CHAIN_ID}")
  print(f"chain ok: perp.owner() is the vault {owner}; staticInterestRate = {current} ({describe(current)}); chain {chain}")


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


def confirm(token: str, rpc_url: str, uuid: str, new_rate: int) -> int:
  deadline = time.time() + CONFIRM_TIMEOUT_SEC
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
  # The receipt can come from a node a block ahead of the one answering eth_call; give the state
  # read a few blocks before calling the result wrong.
  for _ in range(6):
    if read_rate(rpc_url) == new_rate:
      break
    time.sleep(CONFIRM_POLL_SEC)
  else:
    print(f"FAILED: staticInterestRate still does not read {new_rate} 30s after the receipt")
    return 1
  print(f"confirmed: perp.staticInterestRate() = {new_rate} ({describe(new_rate)}). markets-service serves it as "
        "ui_long_funding_rate_1h on its next refresh; the app's header and ticket flip sign on their own.")
  return 0


def render(spread_apr: Decimal) -> int:
  if not Decimal("0") < spread_apr <= Decimal("1"):
    raise SystemExit("REFUSED: --spread-apr is a fraction of a year's carry, e.g. 0.20 for 20%")
  action = build_action(spread_apr)
  ARTIFACT.write_text(json.dumps([action], indent=2) + "\n")
  print(f"wrote {ARTIFACT.relative_to(ROOT)}")
  print(f"  spread   {spread_apr:.2%} APR NGN over USD")
  print(f"  rate     {action['rate_e18']}  ({describe(int(action['rate_e18']))})")
  print(f"  calldata {action['data']}")
  print(f"  digest   {action['digest']}")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Propose the perp's static funding leg with the carry sign corrected")
  ap.add_argument("--render", action="store_true", help="write the artifact for --spread-apr and print its sheet")
  ap.add_argument("--spread-apr", type=Decimal, help="NGN-over-USD carry as a fraction per year, e.g. 0.20")
  ap.add_argument("--propose", action="store_true", help="create the MPCVault signing request")
  ap.add_argument("--expect-digest", help="the reviewed digest; --propose refuses any other artifact")
  ap.add_argument("--confirm", metavar="UUID", help="wait for this request's tx and confirm on chain")
  args = ap.parse_args()
  if args.render:
    if args.spread_apr is None:
      raise SystemExit("--render needs --spread-apr")
    return render(args.spread_apr)
  rpc_url = os.environ.get("RPC_URL", "")
  token = os.environ.get("MPCVAULT_TOKEN", "")
  vault_uuid = os.environ.get("MPCVAULT_VAULT", "")
  vault_addr = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not rpc_url:
    raise SystemExit("RPC_URL is required")
  action = load_action()
  new_rate = verify_artifact(action)
  if args.confirm:
    if not token:
      raise SystemExit("MPCVAULT_TOKEN is required (run via run-with-ssm-mark.sh)")
    return confirm(token, rpc_url, args.confirm, new_rate)
  verify_chain(rpc_url, vault_addr, new_rate)
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
