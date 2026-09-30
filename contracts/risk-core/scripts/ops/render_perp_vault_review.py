#!/usr/bin/env python3
"""Renders every USDCcNGN-PERP vault action as one readable file, for review before signing.

Three batches, in signing order:
  1. CNGN_PERP_STACK_VAULT_ACTIONS.json         custody of the stack, then the SRM guardian
  2. CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json  custody of the TradeModule
  3. the enable batch                           built exactly as propose_perp_enable_batch.py builds it

For each action: the target (named from the deployment artifacts), the function, the decoded
arguments (named, with units), what it is for, and the digest MPCVault will show. Nothing is taken
on trust from the JSON:
  - every selector must be one of the four functions these batches may contain;
  - the decoded arguments are re-encoded and must reproduce the calldata byte for byte;
  - every digest is recomputed as keccak256(abi.encodePacked(to, keccak256(data))) and must match;
  - every target must be a contract named in the artifacts, and every value 0.
Any mismatch stops the render: a file that exists is a file whose contents were checked.

  python3 scripts/ops/render_perp_vault_review.py              # 8453 artifacts -> deployments/8453/CNGN_PERP_VAULT_REVIEW.md
  python3 scripts/ops/render_perp_vault_review.py --stack <json> --stack-actions <json> \\
    --module <json> --module-actions <json> --out <md>          # any other set (e.g. the local venue's)
  python3 scripts/ops/render_perp_vault_review.py --self-test
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from propose_perp_enable_batch import build_actions, load_venue  # noqa: E402
from resolve_cngn_action6 import keccak  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
EXECUTION = ROOT.parent / "execution"
MATCHING = "0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191"
VAULT = "0x1dcA42ab54Bd3862853A821F84B29BF65245F435"

# The only functions these batches may call, with their argument types.
FUNCTIONS = {
  "acceptOwnership()": [],
  "setGuardian(address)": ["address"],
  "setTotalPositionCap(address,uint256)": ["address", "uint256"],
  "setAllowedModule(address,bool)": ["address", "bool"],
}
SELECTORS = {"0x" + keccak(sig.encode()).hex()[:8]: sig for sig in FUNCTIONS}


def names(stack: dict, module: dict) -> dict[str, str]:
  """address (lowercase) -> human name, from the artifacts."""
  label = {
    "cash": "CashAsset (the perp's USDC cash)", "srmViewer": "SRMPortfolioViewer", "srm": "StandardManager (perp SRM)",
    "securityModule": "SecurityModule", "auction": "DutchAuction", "stableFeed": "stable feed (static)",
    "indexFeed": "index feed", "markFeed": "mark feed", "impactAskFeed": "impact ask feed",
    "impactBidFeed": "impact bid feed", "perp": "PerpAsset (USDCcNGN-PERP)", "rateModel": "InterestRateModel",
  }
  out = {stack[k].lower(): v for k, v in label.items() if k in stack and isinstance(stack[k], str)}
  out[module["tradePerp"].lower()] = "TradeModule (perp)"
  out[module.get("matching", MATCHING).lower()] = "Matching"
  out[VAULT.lower()] = "the vault (MPCVault)"
  if "guardian" in stack:
    out.setdefault(stack["guardian"].lower(), "PERP_GUARDIAN (hot KMS key)")
  return out


def decode(data: str) -> tuple[str, list]:
  raw = data.removeprefix("0x")
  sig = SELECTORS.get("0x" + raw[:8])
  if sig is None:
    raise SystemExit(f"REFUSED: selector 0x{raw[:8]} is not one these batches may contain")
  words = [raw[8 + 64 * i: 8 + 64 * (i + 1)] for i in range(len(FUNCTIONS[sig]))]
  if len(raw) != 8 + 64 * len(words):
    raise SystemExit(f"REFUSED: {sig} calldata has trailing or missing bytes")
  args = []
  for kind, word in zip(FUNCTIONS[sig], words):
    if kind == "address":
      args.append("0x" + word[24:])
    elif kind == "bool":
      args.append(bool(int(word, 16)))
    else:
      args.append(int(word, 16))
  # Round trip: the decode must reproduce the calldata exactly.
  encoded = "0x" + raw[:8] + "".join(
    a.removeprefix("0x").rjust(64, "0").lower() if k == "address" else f"{int(a):064x}"
    for k, a in zip(FUNCTIONS[sig], args))
  if encoded.lower() != data.lower():
    raise SystemExit(f"REFUSED: {sig} does not re-encode to its own calldata")
  return sig, args


def digest(to: str, data: str) -> str:
  return "0x" + keccak(bytes.fromhex(to.removeprefix("0x")) + keccak(bytes.fromhex(data.removeprefix("0x")))).hex()


def purpose(sig: str, args: list, target: str, stack: dict) -> str:
  if sig == "acceptOwnership()":
    return f"The vault takes ownership of the {target} (Ownable2Step: it was nominated at deploy). Moves no funds, opens nothing."
  if sig == "setGuardian(address)":
    return ("Makes the hot KMS key the SRM's guardian: it alone can pause and unpause every adjustment on the perp's "
            "accounts (trades, deposits, withdrawals, liquidation bids). The vault can reclaim it with another setGuardian.")
  if sig == "setTotalPositionCap(address,uint256)":
    return (f"Opens the perp to every path, bounded: open interest may reach {args[1] // 10**18:,} cNGN summed over both "
            f"sides ({args[1] // 10**18 // 2:,} cNGN a side). Until this, the cap is 0 and nothing can open a position.")
  if sig == "setAllowedModule(address,bool)":
    return ("Opens the venue: Matching accepts orders settled through the perp's TradeModule. From here the matcher "
            "trades the perp.") if args[1] else "Closes the venue to this module."
  raise AssertionError(sig)


def render_args(sig: str, args: list, named: dict[str, str]) -> str:
  if not args:
    return "(none)"
  kinds = FUNCTIONS[sig]
  params = {"setGuardian(address)": ["guardian"], "setTotalPositionCap(address,uint256)": ["manager", "cap"],
            "setAllowedModule(address,bool)": ["module", "allowed"]}[sig]
  parts = []
  for name, kind, value in zip(params, kinds, args):
    if kind == "address":
      parts.append(f"`{name}` = `{value}` ({named.get(value.lower(), 'NOT IN THE ARTIFACTS')})")
    elif kind == "uint256":
      parts.append(f"`{name}` = `{value}` ({value / 10**18:,.0f} cNGN, 18dp)")
    else:
      parts.append(f"`{name}` = `{str(value).lower()}`")
  return "<br>".join(parts)


def section(title: str, when: str, actions: list[dict], named: dict[str, str], stack: dict) -> str:
  lines = [f"## {title}", "", when, "", "| # | Target | Function | Arguments | Purpose | MPCVault digest |",
           "| --- | --- | --- | --- | --- | --- |"]
  for i, action in enumerate(actions):
    to, data = action["to"], action["data"]
    if str(action.get("value", "0")) != "0":
      raise SystemExit(f"REFUSED: {title} action {i} sends value {action['value']}")
    if to.lower() not in named:
      raise SystemExit(f"REFUSED: {title} action {i} targets {to}, which no artifact names")
    computed = digest(to, data)
    if action.get("digest") and action["digest"].lower() != computed:
      raise SystemExit(f"REFUSED: {title} action {i} digest {action['digest']} is not keccak(to, keccak(data)) = {computed}")
    sig, args = decode(data)
    target = named[to.lower()]
    lines.append(f"| {i} | {target}<br>`{to}` | `{sig}` | {render_args(sig, args, named)} | "
                 f"{purpose(sig, args, target, stack)} | `{computed}` |")
  return "\n".join(lines) + "\n"


def render(stack_path: Path, stack_actions: Path, module_path: Path, module_actions: Path) -> str:
  stack, module = json.loads(stack_path.read_text()), json.loads(module_path.read_text())
  named = names(stack, module)
  batch1 = json.loads(stack_actions.read_text())
  batch2 = json.loads(module_actions.read_text())
  batch3 = build_actions(load_venue(stack_path, module_path))
  try:
    commit = subprocess.run(["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=ROOT).stdout.strip()
  except Exception:  # noqa: BLE001
    commit = "unknown"
  guardian = stack.get("guardian", "(not recorded in the artifact)")
  return "\n".join([
    "# USDCcNGN-PERP vault actions: review before signing",
    "",
    f"Rendered {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')} from commit `{commit}`, from "
    f"`{stack_path.name}`, `{stack_actions.name}`, `{module_path.name}` and `{module_actions.name}`.",
    "Every row was decoded and re-encoded to its own calldata, every digest recomputed, every target matched "
    "to an artifact, and every value is 0. Compare each digest with the one MPCVault shows before approving.",
    "",
    f"- Vault: `{VAULT}`",
    f"- Guardian set by batch 1: `{guardian}`",
    f"- Perp: `{stack['perp']}`, SRM: `{stack['srm']}`, TradeModule: `{module['tradePerp']}`",
    "",
    "None of these moves funds. Batches 1 and 2 are custody only: after them the market is still closed "
    "(cap 0, module not allowlisted). Batch 3 opens it, and is proposed only by `propose_perp_enable_batch.py "
    "--propose`, one action at a time, after its gates pass.",
    "",
    section("Batch 1: stack custody and the guardian", "Sign after the stack deploy (checklist step 10).", batch1, named, stack),
    section("Batch 2: TradeModule custody", "Sign after the module deploy (checklist step 11).", batch2, named, stack),
    section("Batch 3: enable (opens the market)", "Last (checklist step 21). Action 0 first, then action 1.", batch3, named, stack),
  ])


def self_test() -> int:
  assert set(SELECTORS.values()) == set(FUNCTIONS)
  assert "0x79ba5097" in SELECTORS  # acceptOwnership(), `cast sig`
  cap = "0x40a557bd" + "00" * 12 + "ab" * 20 + f"{50_000_000 * 10**18:064x}"
  sig, args = decode(cap)
  assert sig == "setTotalPositionCap(address,uint256)" and args[1] == 50_000_000 * 10**18
  try:
    decode("0xa9059cbb" + "00" * 64)  # transfer(address,uint256): never allowed here
    raise AssertionError("an unknown selector must be refused")
  except SystemExit:
    pass
  try:
    decode(cap + "00")  # trailing bytes
    raise AssertionError("trailing bytes must be refused")
  except SystemExit:
    pass
  print("self-test ok")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Render the perp vault batches for review")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--stack", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_STACK.json")
  ap.add_argument("--stack-actions", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_STACK_VAULT_ACTIONS.json")
  ap.add_argument("--module", type=Path, default=EXECUTION / "deployments/8453/CNGN_PERP_TRADE_MODULE.json")
  ap.add_argument("--module-actions", type=Path, default=EXECUTION / "deployments/8453/CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json")
  ap.add_argument("--out", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_VAULT_REVIEW.md")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  args.out.write_text(render(args.stack, args.stack_actions, args.module, args.module_actions))
  print(f"wrote {args.out}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
