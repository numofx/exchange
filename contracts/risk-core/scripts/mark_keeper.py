#!/usr/bin/env python3
"""Mark keeper for the Base deliverable FX future.

Tracks the on-chain cNGN spot feed and sets the future's mark via setMarkPrice,
signed unattended by the MPCVault Client Signer (see docs/mark-keeper-design.md).

Mark policy (launch): MARK_MODE=spot — mark = the same on-chain LyraSpotFeed the
manager uses for margin, so mark and margin-spot never diverge. (forward/book modes
are in the design doc; not built — spot only.)

Safety, in order:
- on-chain: setMarkPrice is onlyOwner + <=5%/step deviation + 600s staleness + monotonic
  markTime. This keeper stays well inside those (SAFETY step cap).
- MPCVault: an address-allowlist policy lets the Client Signer alone approve txs to the
  future contract; everything else keeps full human quorum.
- callback (mark_callback.py): the Client Signer only signs after our callback confirms
  the tx is setMarkPrice to the future with bounded params. Fail-closed.

Env (or ~/.numo-mark-keeper.env):
  RPC_URL            Base RPC endpoint
  MPCVAULT_TOKEN     MPCVault API token (x-mtoken)     [not needed for --dry-run]
  MPCVAULT_VAULT     vault uuid
  VAULT_ADDRESS      the vault EOA that owns the future (tx `from`)

Usage:
  python3 scripts/mark_keeper.py --once --dry-run   # read+decide, submit nothing
  python3 scripts/mark_keeper.py                     # run forever
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parent

CHAIN_ID = 8453
MPCVAULT_BASE = "https://api.mpcvault.com/v1/"

# on-chain guardrail is 5% (maxMarkDeviation=5e16); stay inside it with a safety margin.
DEVIATION_CAP_BPS = 500     # 5.00% hard wall on-chain
STEP_CAP_BPS = 450          # 4.50% self-imposed step cap (never grazes the wall)
TRIGGER_BPS = 30            # submit when |target-last|/last >= 0.30%
HEARTBEAT_SEC = 30 * 60     # ...or at least this often
POLL_SEC = 60               # loop cadence
GAS_LIMIT = "300000"        # setMarkPrice is ~50-80k; generous ceiling
MAX_FEE_WEI = "500000000"   # 0.5 gwei expressed in WEI — MPCVault gasFee.maxFee is wei, not gwei


def run(cmd: list[str]) -> str:
  res = subprocess.run(cmd, capture_output=True, text=True)
  if res.returncode != 0:
    raise RuntimeError(f"{' '.join(cmd[:3])}... failed: {res.stderr.strip()}")
  return res.stdout.strip()


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip(), value.strip().removeprefix("export ").strip())


def artifact(name: str) -> dict:
  return json.loads((ROOT_DIR / "deployments" / str(CHAIN_ID) / name).read_text())


def get_spot(rpc: str, feed: str) -> int:
  """cNGN per USDC, 1e18. Reverts (raises) if the feed is stale — in which case we must
  NOT mark, rather than mark to a frozen value."""
  out = run(["cast", "call", feed, "getSpot()(uint256,uint256)", "--rpc-url", rpc])
  return int(out.split()[0].replace(",", ""))


def get_series(rpc: str, future: str, sub_id: str) -> dict:
  """Decode getSeries(subId) -> the fields the keeper needs."""
  sig = ("getSeries(uint96)((bool,uint64,uint64,address,address,uint128,uint128,uint128,"
         "uint96,uint64,uint96,bool,int256,uint8))")
  out = run(["cast", "call", future, sig, sub_id, "--rpc-url", rpc])
  # cast prints e.g. "(true, 1789567201 [1.789e9], 0x36..., 1379640000000000000000 [1.379e21], ...)";
  # split members, then drop cast's " [x.ye z]" annotation by taking the first token.
  vals = [f.strip().split()[0] for f in out.strip().strip("()").split(",")]
  return {
    "listed": vals[0] == "true",
    "expiry": int(vals[1]),
    "markPrice": int(vals[8]),
    "lastMarkTime": int(vals[9]),
    "settlementPriceSet": vals[11] == "true",
  }


def clamp(target: int, last: int) -> int:
  step = last * STEP_CAP_BPS // 10_000
  return max(last - step, min(target, last + step))


def should_submit(target: int, last: int, last_submit_ts: float) -> bool:
  moved_bps = abs(target - last) * 10_000 // last if last else 10_000
  return moved_bps >= TRIGGER_BPS or (time.time() - last_submit_ts) >= HEARTBEAT_SEC


def build_calldata(sub_id: str, mark_time: int, mark: int) -> str:
  return run(["cast", "calldata", "setMarkPrice(uint96,uint64,uint256)", sub_id, str(mark_time), str(mark)])


def input_b64(calldata_hex: str) -> str:
  """MPCVault's evmSendCustom.input is a base64 bytes field, NOT hex. Encode the raw
  calldata bytes so the request stores/executes the correct data (and round-trips cleanly
  through getSigningRequestDetails for the callback to verify)."""
  return base64.b64encode(bytes.fromhex(calldata_hex[2:] if calldata_hex.startswith(("0x", "0X")) else calldata_hex)).decode()


def http_post(url: str, token: str, body: dict) -> dict:
  req = urllib.request.Request(
    url, data=json.dumps(body).encode(),
    headers={"Content-Type": "application/json", "x-mtoken": token,
             "User-Agent": "numo-mark-keeper/1.0"}, method="POST")  # MPCVault WAF 403s default python-urllib UA
  with urllib.request.urlopen(req, timeout=20) as resp:
    return json.loads(resp.read())


def submit_via_mpcvault(token: str, vault_uuid: str, from_addr: str, future: str, calldata: str) -> str:
  """CreateSigningRequest (custom payload) -> ExecuteSigningRequests -> txHash.
  NOTE: `input` hex encoding + gasFee units + execute response shape are confirmed
  against MPCVault during the pre-launch rehearsal; this fails loudly if a status
  isn't SUCCEEDED."""
  created = http_post(MPCVAULT_BASE + "createSigningRequest", token, {
    "vaultUuid": vault_uuid,
    "evmSendCustom": {
      "chainId": str(CHAIN_ID), "from": from_addr, "to": future,
      "input": input_b64(calldata), "value": "0",
      "gasFee": {"gasLimit": GAS_LIMIT, "maxFee": MAX_FEE_WEI},
    },
  })
  uuid = created["signingRequest"]["uuid"]
  executed = http_post(MPCVAULT_BASE + "executeSigningRequests", token, {"uuid": uuid})
  status = executed.get("status") or executed.get("signingRequest", {}).get("status")
  if status not in ("STATUS_SUCCEEDED", "SUCCEEDED"):
    raise RuntimeError(f"signing not succeeded: status={status} resp={executed}")
  return executed.get("txHash") or executed.get("signingRequest", {}).get("txHash", "")


def rehearse(token, vault_uuid, from_addr, rpc, future, feed, sub_id) -> int:
  """Create a real setMarkPrice signing request, fetch its details, show the callback verdict,
  then REJECT it — never executes/signs. Confirms the live getSigningRequestDetails response
  shape + input encoding + the callback validation end-to-end without setting a mark. Safe to run
  against the live subId (rejected, so no mark lands). See scripts/ops/REHEARSAL.md."""
  import mark_callback as cb  # lazy: avoids a circular import at module load
  series = get_series(rpc, future, sub_id)
  target = clamp(get_spot(rpc, feed), series["markPrice"])
  mt = int(time.time())
  calldata = build_calldata(sub_id, mt, target)
  print(f"[rehearse] setMarkPrice({sub_id}, {mt}, {target})  calldata={calldata[:20]}…")
  created = http_post(MPCVAULT_BASE + "createSigningRequest", token, {
    "vaultUuid": vault_uuid,
    "evmSendCustom": {"chainId": str(CHAIN_ID), "from": from_addr, "to": future,
                      "input": input_b64(calldata), "value": "0",
                      "gasFee": {"gasLimit": GAS_LIMIT, "maxFee": MAX_FEE_WEI}},
  })
  uuid = (created.get("signingRequest") or {}).get("uuid") or created.get("uuid")
  print(f"[rehearse] created signing request: {uuid}")
  if not uuid:
    print(f"[rehearse] ❌ no uuid in createSigningRequest response: {json.dumps(created)[:400]}")
    return 1
  details = http_post(MPCVAULT_BASE + "getSigningRequestDetails", token, {"uuid": uuid})
  print(f"[rehearse] getSigningRequestDetails -> {json.dumps(details)[:600]}")
  tx = cb.resolve_tx(token, [uuid], vault_uuid)
  print(f"[rehearse] resolved tx: {tx}")
  if tx:
    ok, reason = cb.check(tx, rpc, future, feed, sub_id)
    print(f"[rehearse] CALLBACK VERDICT: {'✅ APPROVE' if ok else '❌ REJECT'} — {reason}")
  else:
    print("[rehearse] ❌ could not resolve tx from getSigningRequestDetails — adjust resolve_tx to the real shape above")
  try:
    http_post(MPCVAULT_BASE + "rejectSigningRequest", token, {"uuid": uuid})
    print("[rehearse] rejected the request — never executed/signed ✅")
  except Exception as exc:
    print(f"[rehearse] reject failed (harmless — it was never executed): {exc}")
  return 0


def main() -> int:
  parser = argparse.ArgumentParser()
  parser.add_argument("--once", action="store_true", help="one cycle then exit")
  parser.add_argument("--dry-run", action="store_true", help="read+decide, submit nothing")
  parser.add_argument("--rehearse", action="store_true", help="create+inspect+reject a request (no sign)")
  parser.add_argument("--rpc-url", default=None)
  args = parser.parse_args()

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc = args.rpc_url or os.environ.get("RPC_URL") or "https://mainnet.base.org"
  token = os.environ.get("MPCVAULT_TOKEN")
  vault_uuid = os.environ.get("MPCVAULT_VAULT")
  vault_addr = os.environ.get("VAULT_ADDRESS")
  if not args.dry_run and not (token and vault_uuid and vault_addr):
    print("MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS required (env or ~/.numo-mark-keeper.env)", file=sys.stderr)
    return 1

  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  future, feed, sub_id = fut["future"], fut["spotFeed"], str(fut["subId"])

  if args.rehearse:
    if not (token and vault_uuid and vault_addr):
      print("--rehearse needs MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS", file=sys.stderr)
      return 1
    return rehearse(token, vault_uuid, vault_addr, rpc, future, feed, sub_id)

  print(f"future {future} | feed {feed} | subId {sub_id} | mode spot | dry_run={args.dry_run}")

  last_submit_ts = 0.0
  while True:
    started = time.time()
    try:
      series = get_series(rpc, future, sub_id)
      if series["settlementPriceSet"]:
        print("series is settled; nothing to mark. exiting.")
        return 0
      last = series["markPrice"]
      spot = get_spot(rpc, feed)                    # raises if stale -> skip this cycle
      target = clamp(spot, last)                    # MARK_MODE=spot
      mark_time = int(time.time())

      if not should_submit(target, last, last_submit_ts):
        if args.once:
          print(f"no-op: last={last} spot={spot} target={target} (< {TRIGGER_BPS}bps, within heartbeat)")
          return 0
      else:
        calldata = build_calldata(sub_id, mark_time, target)
        moved = abs(target - last) * 10_000 // last if last else 0
        if args.dry_run:
          print(f"[dry-run] would setMarkPrice: last={last} spot={spot} -> {target} "
                f"({moved}bps, markTime={mark_time}) calldata={calldata}")
        else:
          tx = submit_via_mpcvault(token, vault_uuid, vault_addr, future, calldata)
          print(f"{time.strftime('%H:%M:%S')} setMarkPrice {last}->{target} ({moved}bps) tx={tx}")
          last_submit_ts = time.time()
    except Exception as exc:  # keep the loop alive; staleness alerting is external
      print(f"ERROR: {exc}", file=sys.stderr)

    if args.once:
      return 0
    time.sleep(max(1.0, POLL_SEC - (time.time() - started)))


if __name__ == "__main__":
  sys.exit(main())
