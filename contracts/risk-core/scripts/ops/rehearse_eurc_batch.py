#!/usr/bin/env python3
"""Rehearse the EURC-USDC vault batches on an anvil fork of Base, through propose_eurc_spot_batch.py's own logic.

The --propose loop, with the one thing a fork cannot do replaced: instead of an MPCVault signing request, each action
is sent from the impersonated vault. Every gate before an action, the createMarket market-id rule, the landed-check
after it and the "lastMarketId is exactly 2" check are the proposer's own functions, so a rehearsal that completes is
the proposer completing against that fork. The enable batch runs the proposer's service gates for real (markets-service
and the engine keeper), so before the services are live it refuses, as it would on the box.

ANVIL ONLY. It sends transactions as the vault, which only a node that lets anyone impersonate anyone will accept, and
it refuses any RPC that does not answer anvil_nodeInfo: pointed at Base it would only fail, but it must not even try.

  anvil --fork-url https://mainnet.base.org --port 8546
  cast rpc anvil_impersonateAccount 0x2D724867d3AeD4A9F09c096B87F939285DD3AE2D --rpc-url http://127.0.0.1:8546
  forge script scripts/deploy-eurc-spot.s.sol --rpc-url http://127.0.0.1:8546 \\
    --sender 0x2D724867d3AeD4A9F09c096B87F939285DD3AE2D --unlocked --broadcast   # writes deployments/8453/EURC_SPOT*.json
  python3 scripts/ops/rehearse_eurc_batch.py                  # the 7 configure actions
  python3 scripts/ops/rehearse_eurc_batch.py --batch enable   # the enable gate (refuses until the services are live)
  rm deployments/8453/EURC_SPOT*.json; rm -rf broadcast/deploy-eurc-spot.s.sol cache/deploy-eurc-spot.s.sol
  python3 scripts/ops/rehearse_eurc_batch.py --self-test

The deploy writes the fork's artifacts where the real ones go: delete them afterwards (last line above), or the real
deploy's dry run and anyone reading deployments/ sees addresses that exist only on a dead fork.

On deploy day rerun it with the real cap, at that morning's deployer nonce: the escrow and feed addresses, and so every
digest, follow from the nonce. MPCVault approvers check each digest against the sheet of that run (README.md).
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import propose_eurc_spot_batch as P  # noqa: E402
from propose_cngn_spot_batch import GAS_LIMIT  # noqa: E402  what every MPCVault request is sent with

DEFAULT_RPC = "http://127.0.0.1:8546"
VAULT_BALANCE_WEI = hex(100 * 10**18)  # gas for the impersonated vault's transactions
RECEIPT_POLLS, RECEIPT_POLL_SEC = 60, 0.5


class Rpc:
  def __init__(self, url: str):
    self.url = url

  def __call__(self, method: str, params: list):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(self.url, data=body, headers={"Content-Type": "application/json",
                                                               "User-Agent": "numo-eurc-rehearsal/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
      out = json.loads(resp.read())
    if "error" in out:
      raise RuntimeError(f"{method}: {out['error']}")
    return out["result"]


def require_anvil(rpc) -> dict:
  """The guard: anvil answers anvil_nodeInfo; a real node errors or refuses. Anything but an answer is a refusal."""
  try:
    info = rpc("anvil_nodeInfo", [])
  except (RuntimeError, urllib.error.URLError, OSError, ValueError) as error:
    raise SystemExit(f"REFUSED: {getattr(rpc, 'url', rpc)} does not answer anvil_nodeInfo ({str(error)[:160]}). "
                     "This rehearsal impersonates the vault and runs only against an anvil fork.")
  if not isinstance(info, dict):
    raise SystemExit(f"REFUSED: anvil_nodeInfo answered {info!r}, not a node description")
  return info


def send_as_vault(rpc, to: str, data: str) -> dict:
  tx = rpc("eth_sendTransaction", [{"from": P.EXPECTED_VAULT, "to": to, "data": data, "value": "0x0"}])
  for _ in range(RECEIPT_POLLS):
    receipt = rpc("eth_getTransactionReceipt", [tx])
    if receipt:
      return receipt
    time.sleep(RECEIPT_POLL_SEC)
  raise SystemExit(f"no receipt for {tx} after {RECEIPT_POLLS * RECEIPT_POLL_SEC:.0f}s")


def rehearse(url: str, batch: str, markets_url: str, keeper_health_url: str) -> int:
  rpc = Rpc(url)
  info = require_anvil(rpc)
  fork = (info.get("forkConfig") or {}).get("forkBlockNumber")
  print(f"anvil at {url}, forked from block {fork}")
  if not P.ARTIFACT.exists():
    raise SystemExit(f"no {P.ARTIFACT.name}: broadcast scripts/deploy-eurc-spot.s.sol to this fork first")
  rpc("anvil_impersonateAccount", [P.EXPECTED_VAULT])
  rpc("anvil_setBalance", [P.EXPECTED_VAULT, VAULT_BALANCE_WEI])

  art = json.loads(P.ARTIFACT.read_text())
  configure = P.load_actions(P.CONFIGURE_ACTIONS, art, P.CONFIGURE_ORDER)
  actions = configure if batch == "configure" else P.load_actions(P.ENABLE_ACTIONS, art, P.ENABLE_ORDER)

  def gates(created: bool) -> list:
    g = [P.gate_chain(url), P.gate_custody(url, art, P.EXPECTED_VAULT), P.gate_market(url, art, created),
         P.gate_escrow(url, art, P.EXPECTED_VAULT), P.gate_feed(url, art, P.EXPECTED_VAULT)]
    if batch == "enable":
      done = all(P.landed(url, art, i, a, P.EXPECTED_VAULT) for i, a in enumerate(configure))
      g.append(P.Gate("configure landed", done, "every configuring action's post-state reads back" if done else "not landed"))
      g.extend(P.gate_services(url, art, markets_url, keeper_health_url))
    return g

  print(f"batch {batch}: {len(actions)} action(s); gates:")
  if not P.report(gates(P.last_market_id(url, art) >= P.MARKET_ID)):
    print("\nGATES FAILED: nothing sent, as the proposer would stop here.")
    P.print_sheet(actions)
    return 1
  P.print_sheet(actions)
  for i, a in enumerate(actions):
    if P.landed(url, art, i, a, P.EXPECTED_VAULT):
      print(f"  [{i}] already landed; skipping")
      continue
    after_create = batch == "enable" or i > P.CONFIGURE_ORDER.index("createMarket(string)")
    if i > 0 and not P.report(gates(after_create)):
      raise SystemExit(f"a gate failed before action {i}")
    receipt = send_as_vault(rpc, a["to"], a["data"])
    status, gas = int(receipt["status"], 16), int(receipt["gasUsed"], 16)
    print(f"  [{i}] {a['description']}\n       tx {receipt['transactionHash']} status {status} gas {gas:,}")
    if status != 1:
      raise SystemExit(f"action {i} reverted")
    if gas > int(GAS_LIMIT):
      raise SystemExit(f"action {i} used {gas:,} gas, over the {int(GAS_LIMIT):,} the proposer sends with")
    if not P.landed(url, art, i, a, P.EXPECTED_VAULT):
      raise SystemExit(f"action {i} mined but its post-state does not read back")
    if a["sig"] == "createMarket(string)" and P.last_market_id(url, art) != P.MARKET_ID:
      raise SystemExit(f"createMarket landed but lastMarketId is not {P.MARKET_ID}")
  print(f"\nbatch {batch} complete: every action landed and read back. Delete the fork's artifacts now (see the docstring).")
  return 0


def self_test() -> int:
  from abi_selectors import assert_script
  assert_script(__file__)

  class Fake:
    url = "fake"

    def __init__(self, answer=None, error=None):
      self.answer, self.error = answer, error

    def __call__(self, method, params):
      assert method == "anvil_nodeInfo"
      if self.error:
        raise self.error
      return self.answer

  assert require_anvil(Fake(answer={"currentBlockNumber": 1, "forkConfig": {"forkBlockNumber": 52898297}}))
  for refused in [Fake(error=RuntimeError("anvil_nodeInfo: {'code': -32601, 'message': 'method not found'}")),
                  Fake(error=urllib.error.HTTPError("https://mainnet.base.org", 403, "Forbidden", {}, None)),
                  Fake(error=urllib.error.URLError("connection refused")), Fake(answer="0x1"), Fake(answer=None)]:
    try:
      require_anvil(refused)
    except SystemExit as stop:
      assert "REFUSED" in str(stop), stop
    else:
      raise AssertionError(f"ran against a node that is not anvil: {refused.answer or refused.error}")
  assert int(GAS_LIMIT) >= 400_000
  print("self-test ok: the anvil guard refuses an RPC without anvil_nodeInfo, an error, a refusal and a non-answer")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Rehearse the EURC-USDC vault batches on an anvil fork (anvil only)")
  ap.add_argument("--rpc-url", default=DEFAULT_RPC)
  ap.add_argument("--batch", choices=["configure", "enable"], default="configure")
  ap.add_argument("--markets-url", default="https://api.numofx.com")
  ap.add_argument("--keeper-health-url", default="http://127.0.0.1:9465/health")
  ap.add_argument("--self-test", action="store_true")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  return rehearse(args.rpc_url, args.batch, args.markets_url, args.keeper_health_url)


if __name__ == "__main__":
  sys.exit(main())
