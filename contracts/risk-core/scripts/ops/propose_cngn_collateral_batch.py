#!/usr/bin/env python3
"""Proposes the cNGN-as-margin vault batches for USDCcNGN-PERP to MPCVault, one action at a time.

Batch 4 (configure; deployments/8453/CNGN_PERP_COLLATERAL_VAULT_ACTIONS.json):
  0 escrow.acceptOwnership()                       custody
  1 srm.setBaseAssetMarginFactor(1, 0.5, 1.0)      the haircut
  2 srm.whitelistAsset(escrow, 1, Base)            the SRM side of the gate
  3 escrow.setTotalPositionCap(srm, 8M cNGN)       the collateral cap
  4 cash.setInterestRateModel(newModel)            the higher floor on borrowed cash
None of these lets cNGN in.

Batch 5 (enable; CNGN_PERP_COLLATERAL_ENABLE_VAULT_ACTIONS.json, `--batch enable`):
  0 escrow.setWhitelistManager(srm, true)          cNGN deposits open
Gated on the services that enforce the venue's cNGN rules being live: the keeper reporting the
escrow, markets-service listing it under collateral_assets, and an operator flag that the fork
rehearsal's cNGN scenario has run against this escrow.

Every action is checked against the artifact (selector allowlist, digest recomputed) and against the
chain before it is proposed (the state it assumes), and after it lands (the state it promised).
It NEVER signs, executes or broadcasts: each request goes to the MPCVault app for a human.
Without --propose it prints the gate report and the sheet.

Env (via run-with-ssm-mark.sh): MPCVAULT_TOKEN, MPCVAULT_VAULT, VAULT_ADDRESS, RPC_URL.

  scripts/ops/run-with-ssm-mark.sh python3 scripts/ops/propose_cngn_collateral_batch.py            # gates + sheet
  scripts/ops/run-with-ssm-mark.sh python3 scripts/ops/propose_cngn_collateral_batch.py --propose  # batch 4
  ... --batch enable --rehearsed --propose                                                          # batch 5, later
  python3 scripts/ops/propose_cngn_collateral_batch.py --self-test
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from propose_cngn_spot_batch import (  # noqa: E402  single implementation of the MPCVault transport
  CONFIRM_POLL_SEC,
  CONFIRM_TIMEOUT_SEC,
  EXPECTED_VAULT,
  confirm_on_chain,
  load_env_file,
  propose,
  request_tx_hash,
  rpc,
)
from resolve_cngn_action6 import keccak  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
DEPLOYMENTS = ROOT / "deployments" / "8453"
COLLATERAL = DEPLOYMENTS / "CNGN_PERP_COLLATERAL.json"
CONFIGURE_ACTIONS = DEPLOYMENTS / "CNGN_PERP_COLLATERAL_VAULT_ACTIONS.json"
ENABLE_ACTIONS = DEPLOYMENTS / "CNGN_PERP_COLLATERAL_ENABLE_VAULT_ACTIONS.json"
STACK = DEPLOYMENTS / "CNGN_PERP_STACK.json"
CHAIN_ID = 8453

# The only functions these batches may call. Pinned by --self-test against `cast sig`.
SELECTORS = {
  "acceptOwnership()": "0x79ba5097",
  "setBaseAssetMarginFactor(uint256,uint256,uint256)": "0xc27009e2",
  "whitelistAsset(address,uint256,uint8)": "0xbd798569",
  "setTotalPositionCap(address,uint256)": "0x40a557bd",
  "setInterestRateModel(address)": "0x8bcd4016",
  "setWhitelistManager(address,bool)": "0xe64cc9da",
}
SIZED_MARGIN_FACTOR = 5 * 10**17


def sel(sig: str) -> str:
  return "0x" + keccak(sig.encode()).hex()[:8]


def word_address(address: str) -> str:
  return address.lower().removeprefix("0x").rjust(64, "0")


def word_uint(value: int) -> str:
  return f"{value:064x}"


def call(rpc_url: str, to: str, data: str) -> str:
  return rpc(rpc_url, "eth_call", [{"to": to, "data": data}, "latest"])


def uint_at(raw: str, index: int = 0) -> int:
  return int(raw[2 + 64 * index: 2 + 64 * (index + 1)], 16)


def address_at(raw: str) -> str:
  return "0x" + raw[2 + 24: 2 + 64].lower()


def read_fn(rpc_url: str, to: str, sig: str, *args: str) -> str:
  return call(rpc_url, to, sel(sig) + "".join(args))


class Gate:
  def __init__(self, name: str, ok: bool, detail: str):
    self.name, self.ok, self.detail = name, ok, detail


def report(gates: list[Gate]) -> bool:
  for g in gates:
    print(f"  [{'PASS' if g.ok else 'FAIL'}] {g.name}: {g.detail}")
  return all(g.ok for g in gates)


# --- the artifact ------------------------------------------------------------------------------

def load_actions(path: Path, artifact: dict) -> list[dict]:
  actions = json.loads(path.read_text())
  escrow, srm, cash = artifact["escrow"].lower(), artifact["srm"].lower(), artifact["cash"].lower()
  for i, a in enumerate(actions):
    data = a["data"].lower()
    sig = next((s for s, x in SELECTORS.items() if data.startswith(x)), None)
    if sig is None:
      raise SystemExit(f"REFUSED: action {i} selector {data[:10]} is not one these batches may contain")
    digest = "0x" + keccak(bytes.fromhex(a["to"][2:]) + keccak(bytes.fromhex(a["data"][2:]))).hex()
    if digest != a["digest"].lower():
      raise SystemExit(f"REFUSED: action {i} digest {a['digest']} is not keccak(to, keccak(data)) = {digest}")
    if str(a.get("value", "0")) != "0":
      raise SystemExit(f"REFUSED: action {i} sends value")
    to = a["to"].lower()
    if to not in (escrow, srm, cash):
      raise SystemExit(f"REFUSED: action {i} targets {a['to']}, not the escrow, SRM or cash of the artifact")
    # The arguments the batch must carry, re-read from the calldata rather than trusted.
    if sig == "setBaseAssetMarginFactor(uint256,uint256,uint256)":
      market, factor, im_scale = (int(data[10 + 64 * k: 10 + 64 * (k + 1)], 16) for k in range(3))
      if market != int(artifact["marketId"]) or factor != int(artifact["marginFactor"]) or im_scale != int(artifact["imScale"]):
        raise SystemExit(f"REFUSED: action {i} arguments do not match the artifact")
      if factor > SIZED_MARGIN_FACTOR:
        raise SystemExit(f"REFUSED: margin factor {factor / 1e18:.2f} is above the sized 0.50")
    if sig == "whitelistAsset(address,uint256,uint8)":
      asset, market, kind = "0x" + data[10 + 24: 10 + 64], int(data[74:138], 16), int(data[138:202], 16)
      if asset != escrow or market != int(artifact["marketId"]) or kind != 3:
        raise SystemExit(f"REFUSED: action {i} must whitelist the escrow as Base (3) on market {artifact['marketId']}")
    if sig == "setTotalPositionCap(address,uint256)":
      manager, cap = "0x" + data[10 + 24: 10 + 64], int(data[74:138], 16)
      if manager != srm or cap != int(artifact["collateralCap"]):
        raise SystemExit(f"REFUSED: action {i} cap/manager do not match the artifact")
    if sig == "setInterestRateModel(address)":
      if "0x" + data[10 + 24: 10 + 64] != artifact["rateModel"].lower() or to != cash:
        raise SystemExit(f"REFUSED: action {i} must point the cash at the artifact's rate model")
    if sig == "setWhitelistManager(address,bool)":
      manager, on = "0x" + data[10 + 24: 10 + 64], int(data[74:138], 16)
      if manager != srm or on != 1 or to != escrow:
        raise SystemExit(f"REFUSED: action {i} must open the escrow to the SRM")
    a["sig"] = sig
  return actions


# --- gates, read live ---------------------------------------------------------------------------

def gate_chain(rpc_url: str) -> Gate:
  chain = int(rpc(rpc_url, "eth_chainId", []), 16)
  return Gate("chain", chain == CHAIN_ID, f"chain id {chain} (want {CHAIN_ID})")


def gate_custody(rpc_url: str, art: dict, vault: str) -> Gate:
  srm_owner = address_at(read_fn(rpc_url, art["srm"], "owner()"))
  cash_owner = address_at(read_fn(rpc_url, art["cash"], "owner()"))
  ok = srm_owner == vault.lower() and cash_owner == vault.lower()
  return Gate("custody", ok, f"srm owner {srm_owner}, cash owner {cash_owner} (vault {vault.lower()})")


def gate_escrow(rpc_url: str, art: dict, vault: str) -> Gate:
  escrow = art["escrow"]
  token = address_at(read_fn(rpc_url, escrow, "wrappedAsset()"))
  owner = address_at(read_fn(rpc_url, escrow, "owner()"))
  pending = address_at(read_fn(rpc_url, escrow, "pendingOwner()"))
  whitelisted = uint_at(read_fn(rpc_url, escrow, "whitelistedManager(address)", word_address(art["srm"]))) == 1
  ok = token == art["cngnToken"].lower() and (owner == vault.lower() or pending == vault.lower()) and not whitelisted
  return Gate("escrow", ok, f"wraps {token}, owner {owner}, pending {pending}, open to srm {whitelisted}")


def gate_market(rpc_url: str, art: dict) -> Gate:
  factor = uint_at(read_fn(rpc_url, art["srm"], "baseMarginParams(uint256)", word_uint(int(art["marketId"]))))
  borrowing = uint_at(read_fn(rpc_url, art["srm"], "borrowingEnabled()")) == 1
  spot = address_at(read_fn(rpc_url, art["srm"], "getMarketFeeds(uint256)", word_uint(int(art["marketId"]))))
  ok = borrowing and spot == art["indexFeed"].lower()
  return Gate("market", ok, f"base factor now {factor / 1e18:.2f}, borrowing {borrowing}, spot feed {spot} (index {art['indexFeed'].lower()})")


def gate_rate_model(rpc_url: str, art: dict) -> Gate:
  live = address_at(read_fn(rpc_url, art["cash"], "rateModel()"))
  live_floor = uint_at(read_fn(rpc_url, live, "minRate()"))
  new_floor = uint_at(read_fn(rpc_url, art["rateModel"], "minRate()"))
  ok = new_floor == int(art["rateFloor"]) and new_floor > live_floor or live == art["rateModel"].lower()
  return Gate("rate model", ok, f"cash on {live} (floor {live_floor / 1e16:.0f}%), new {art['rateModel'].lower()} (floor {new_floor / 1e16:.0f}%)")


def http_json(url: str) -> dict | list:
  req = urllib.request.Request(url, headers={"accept": "application/json", "User-Agent": "numo-ops/1.0"})
  with urllib.request.urlopen(req, timeout=15) as resp:
    return json.loads(resp.read())


def gate_services(art: dict, markets_url: str, keeper_health_url: str) -> list[Gate]:
  """Batch 5 only: the services that enforce the cNGN rules must be live with this escrow."""
  gates = []
  try:
    markets = http_json(markets_url.rstrip("/") + "/v1/markets")
    perp = next((m for m in markets if m.get("contract_type") == "perpetual"), {})
    assets = (perp.get("perp") or {}).get("collateral_assets") or []
    listed = any(a.get("asset_address", "").lower() == art["escrow"].lower() for a in assets)
    gates.append(Gate("markets-service", listed, f"collateral_assets {[a.get('asset_address') for a in assets]}"))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("markets-service", False, f"unreadable: {exc}"))
  try:
    health = http_json(keeper_health_url)
    escrow = str(health.get("cngnEscrow", "")).lower()
    ok = bool(health.get("lastPassOk")) and not health.get("dryRun") and escrow == art["escrow"].lower()
    gates.append(Gate("keeper", ok, f"lastPassOk {health.get('lastPassOk')}, dryRun {health.get('dryRun')}, cngnEscrow {escrow or '(unset)'}"))
  except Exception as exc:  # noqa: BLE001
    gates.append(Gate("keeper", False, f"unreadable: {exc}"))
  return gates


# --- post-state each action promises -----------------------------------------------------------

def landed(rpc_url: str, art: dict, action: dict, vault: str) -> bool:
  sig = action["sig"]
  if sig == "acceptOwnership()":
    return address_at(read_fn(rpc_url, art["escrow"], "owner()")) == vault.lower()
  if sig == "setBaseAssetMarginFactor(uint256,uint256,uint256)":
    raw = read_fn(rpc_url, art["srm"], "baseMarginParams(uint256)", word_uint(int(art["marketId"])))
    return uint_at(raw, 0) == int(art["marginFactor"]) and uint_at(raw, 1) == int(art["imScale"])
  if sig == "whitelistAsset(address,uint256,uint8)":
    raw = read_fn(rpc_url, art["srm"], "assetDetails(address)", word_address(art["escrow"]))
    return uint_at(raw, 0) == 1 and uint_at(raw, 1) == 3 and uint_at(raw, 2) == int(art["marketId"])
  if sig == "setTotalPositionCap(address,uint256)":
    return uint_at(read_fn(rpc_url, art["escrow"], "totalPositionCap(address)", word_address(art["srm"]))) == int(art["collateralCap"])
  if sig == "setInterestRateModel(address)":
    return address_at(read_fn(rpc_url, art["cash"], "rateModel()")) == art["rateModel"].lower()
  if sig == "setWhitelistManager(address,bool)":
    return uint_at(read_fn(rpc_url, art["escrow"], "whitelistedManager(address)", word_address(art["srm"]))) == 1
  raise AssertionError(sig)


def print_sheet(actions: list[dict]) -> None:
  print()
  for i, a in enumerate(actions):
    print(f"  [{i}] to {a['to']}\n      data {a['data']}\n      digest {a['digest']}\n      {a['description']}")
  print()


def self_test() -> int:
  for sig, expected in SELECTORS.items():
    assert sel(sig) == expected, (sig, sel(sig))
  art = json.loads(COLLATERAL.read_text())
  configure = load_actions(CONFIGURE_ACTIONS, art)
  enable = load_actions(ENABLE_ACTIONS, art)
  assert [a["sig"] for a in configure] == [
    "acceptOwnership()", "setBaseAssetMarginFactor(uint256,uint256,uint256)", "whitelistAsset(address,uint256,uint8)",
    "setTotalPositionCap(address,uint256)", "setInterestRateModel(address)"], [a["sig"] for a in configure]
  assert [a["sig"] for a in enable] == ["setWhitelistManager(address,bool)"]
  # The enabling switch must never be inside the configuring batch.
  assert not any(a["sig"] == "setWhitelistManager(address,bool)" for a in configure)
  print("self-test ok")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Gated proposal of the cNGN-as-margin vault batches")
  ap.add_argument("--batch", choices=["configure", "enable"], default="configure")
  ap.add_argument("--propose", action="store_true", help="create MPCVault signing requests, one at a time")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--rehearsed", action="store_true", help="batch 5: the fork rehearsal's cNGN scenario has run against this escrow")
  ap.add_argument("--markets-url", default="https://api.numofx.com")
  ap.add_argument("--keeper-health-url", default=os.environ.get("KEEPER_HEALTH_URL", "http://127.0.0.1:9464/health"))
  args = ap.parse_args()
  if args.self_test:
    return self_test()

  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc_url = os.environ.get("RPC_URL", "")
  vault = os.environ.get("VAULT_ADDRESS", EXPECTED_VAULT)
  if not rpc_url:
    raise SystemExit("RPC_URL is required (run via run-with-ssm-mark.sh)")
  if vault.lower() != EXPECTED_VAULT.lower():
    raise SystemExit(f"VAULT_ADDRESS {vault} is not the recorded vault {EXPECTED_VAULT}")

  art = json.loads(COLLATERAL.read_text())
  actions = load_actions(CONFIGURE_ACTIONS if args.batch == "configure" else ENABLE_ACTIONS, art)

  def gates() -> list[Gate]:
    g = [gate_chain(rpc_url), gate_custody(rpc_url, art, vault), gate_escrow(rpc_url, art, vault), gate_market(rpc_url, art), gate_rate_model(rpc_url, art)]
    if args.batch == "enable":
      # Batch 4 must be complete: the SRM credits the escrow, the cap is set, the cash is on the new model.
      done = all(landed(rpc_url, art, a, vault) for a in load_actions(CONFIGURE_ACTIONS, art))
      g.append(Gate("batch 4 landed", done, "every configuring action's post-state reads back" if done else "a configuring action has not landed"))
      g.extend(gate_services(art, args.markets_url, args.keeper_health_url))
      g.append(Gate("fork rehearsal", args.rehearsed, "--rehearsed given" if args.rehearsed else "pass --rehearsed once the rehearsal's cNGN scenario has run against this escrow"))
    return g

  print(f"batch {args.batch}: {len(actions)} action(s); gates:")
  if not report(gates()):
    print("\nGATES FAILED: nothing proposed.")
    print_sheet(actions)
    return 1
  print_sheet(actions)
  if not args.propose:
    print("dry run: nothing proposed. Re-run with --propose; compare each digest with MPCVault before approving.")
    return 0

  token, vault_uuid = os.environ.get("MPCVAULT_TOKEN", ""), os.environ.get("MPCVAULT_VAULT", "")
  if not token or not vault_uuid:
    raise SystemExit("MPCVAULT_TOKEN and MPCVAULT_VAULT are required (run via run-with-ssm-mark.sh)")
  for i, a in enumerate(actions):
    if landed(rpc_url, art, a, vault):
      print(f"  [{i}] already landed on chain; skipping {a['description']}")
      continue
    if i > 0 and not report(gates()):
      raise SystemExit(f"a gate failed before action {i}. Stop and investigate.")
    uuid = propose(token, vault_uuid, vault, a)
    print(f"  [{i}] proposed uuid={uuid}\n       {a['description']}\n       digest {a['digest']}\n       -> approve in MPCVault now")
    deadline, tx_hash = time.time() + CONFIRM_TIMEOUT_SEC, None
    while time.time() < deadline and not tx_hash:
      time.sleep(CONFIRM_POLL_SEC)
      tx_hash = request_tx_hash(token, uuid)
    if not tx_hash:
      raise SystemExit(f"action {i} not approved within the timeout")
    confirm_on_chain(rpc_url, tx_hash)
    if not landed(rpc_url, art, a, vault):
      raise SystemExit(f"action {i} mined but its post-state does not read back. Stop and investigate.")
    print(f"       landed: {a['description']}")
  print(f"\nbatch {args.batch} complete.")
  return 0


if __name__ == "__main__":
  sys.exit(main())
