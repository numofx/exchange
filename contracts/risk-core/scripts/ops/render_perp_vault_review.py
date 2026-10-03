#!/usr/bin/env python3
"""Renders every USDCcNGN-PERP vault action as one readable file, for review before signing.

Four batches, in signing order:
  1. CNGN_PERP_STACK_VAULT_ACTIONS.json         custody of the stack, then the SRM guardian
  2. CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json  custody of the TradeModule
  3. the enable batch                           built exactly as propose_perp_enable_batch.py builds it
  4. CNGN_PERP_COLLATERAL_VAULT_ACTIONS.json    cNGN as margin: custody, haircut, whitelist, cap, rate model
  5. CNGN_PERP_COLLATERAL_ENABLE_VAULT_ACTIONS.json  opens cNGN deposits; signed last, on its own
  (4 and 5 are rendered when the collateral artifact exists)

For each action: the target (named from the deployment artifacts), the function, the decoded
arguments (named, with units), what it is for, and the digest MPCVault will show. Nothing is taken
on trust from the JSON:
  - every selector must be one of the functions these batches may contain;
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
  # batch 4, cNGN collateral (deploy-cngn-perp-collateral.s.sol / cngn-perp-collateral-batch.sol)
  "setBaseAssetMarginFactor(uint256,uint256,uint256)": ["uint256", "uint256", "uint256"],
  "whitelistAsset(address,uint256,uint8)": ["address", "uint256", "uint8"],
  "setWhitelistManager(address,bool)": ["address", "bool"],
  "setInterestRateModel(address)": ["address"],
}
ASSET_TYPES = {0: "NotSet", 1: "Option", 2: "Perpetual", 3: "Base"}
# The fork test's sizing (DeployCngnPerpCollateral.SIZED_MARGIN_FACTOR); a larger factor is refused here as well.
SIZED_MARGIN_FACTOR = 5 * 10**17
SELECTORS = {"0x" + keccak(sig.encode()).hex()[:8]: sig for sig in FUNCTIONS}


def names(stack: dict, module: dict, collateral: dict | None = None) -> dict[str, str]:
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
  if collateral is not None:
    out[collateral["escrow"].lower()] = "cNGN escrow (perp collateral, WrappedERC20Asset)"
    out.setdefault(collateral["cngnToken"].lower(), "cNGN token")
    if "rateModel" in collateral:
      out[collateral["rateModel"].lower()] = f"InterestRateModel (replacement, {int(collateral.get('rateFloor', 0)) / 10**16:.0f}% floor)"
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
  if sig == "setBaseAssetMarginFactor(uint256,uint256,uint256)":
    if args[1] > SIZED_MARGIN_FACTOR:
      raise SystemExit(f"REFUSED: margin factor {args[1] / 10**18:.2f} is above the sized {SIZED_MARGIN_FACTOR / 10**18:.2f}")
    return (f"The haircut: {args[1] / 10**16:.0f}% of cNGN's oracle value counts as maintenance margin "
            f"(x{args[2] / 10**18:.2f} again for initial margin) on market {args[0]}. Sized by CngnPerpCollateralFork so a "
            "long-naira account on cNGN alone, left at maintenance margin, is still solvent after a 25% step.")
  if sig == "whitelistAsset(address,uint256,uint8)":
    if args[2] != 3:
      raise SystemExit(f"REFUSED: whitelistAsset type {args[2]} is not Base (3)")
    return (f"The SRM accepts the cNGN escrow as a BASE asset of market {args[1]}: valued at the market's spot feed (the "
            "perp index), haircut by the factor above. The escrow itself is still shut.")
  if sig == "setWhitelistManager(address,bool)":
    return ("THE ENABLING SWITCH: the escrow accepts the perp SRM, so cNGN can be deposited into perp accounts. "
            "Nothing can enter before this. Sign only once the keeper, markets-service and app that enforce the "
            "cNGN rules are live and the fork rehearsal has run a cNGN scenario against this escrow.") if args[1] else "Shuts the escrow to this manager."
  if sig == "setInterestRateModel(address)":
    return ("The perp's cash prices borrowed cash on the replacement model: a higher floor so a USDC withdrawal "
            "against cNGN (borrowing stays on: a cNGN-only account pays its fee from zero cash) is unattractive. "
            "Changes no balance; interest accrues from the next touch.")
  raise AssertionError(sig)


def render_args(sig: str, args: list, named: dict[str, str]) -> str:
  if not args:
    return "(none)"
  kinds = FUNCTIONS[sig]
  params = {"setGuardian(address)": ["guardian"], "setTotalPositionCap(address,uint256)": ["manager", "cap"],
            "setAllowedModule(address,bool)": ["module", "allowed"],
            "setBaseAssetMarginFactor(uint256,uint256,uint256)": ["marketId", "marginFactor", "imScale"],
            "whitelistAsset(address,uint256,uint8)": ["asset", "marketId", "assetType"],
            "setWhitelistManager(address,bool)": ["manager", "whitelisted"],
            "setInterestRateModel(address)": ["rateModel"]}[sig]
  parts = []
  for name, kind, value in zip(params, kinds, args):
    if kind == "address":
      parts.append(f"`{name}` = `{value}` ({named.get(value.lower(), 'NOT IN THE ARTIFACTS')})")
    elif name == "marketId":
      parts.append(f"`{name}` = `{value}`")
    elif name in ("marginFactor", "imScale"):
      parts.append(f"`{name}` = `{value}` ({value / 10**16:.0f}%, 18dp)")
    elif name == "assetType":
      parts.append(f"`{name}` = `{value}` ({ASSET_TYPES.get(value, 'unknown')})")
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


def render(stack_path: Path, stack_actions: Path, module_path: Path, module_actions: Path,
           collateral_path: Path | None = None, collateral_actions: Path | None = None,
           collateral_enable: Path | None = None) -> str:
  stack, module = json.loads(stack_path.read_text()), json.loads(module_path.read_text())
  collateral = None
  batch4 = None
  batch5 = None
  if collateral_path is not None and collateral_actions is not None and collateral_path.exists() and collateral_actions.exists():
    collateral = json.loads(collateral_path.read_text())
    batch4 = json.loads(collateral_actions.read_text())
    if collateral["srm"].lower() != stack["srm"].lower():
      raise SystemExit("REFUSED: the collateral artifact names a different SRM than the stack")
    if collateral_enable is None or not collateral_enable.exists():
      raise SystemExit("REFUSED: the collateral artifact exists but its enable batch does not")
    batch5 = json.loads(collateral_enable.read_text())
    for action in batch4:
      if action["data"].lower().startswith("0x" + keccak(b"setWhitelistManager(address,bool)").hex()[:8]):
        raise SystemExit("REFUSED: the enabling switch must be in its own batch, not in the configuring one")
    if len(batch5) != 1:
      raise SystemExit("REFUSED: the enable batch must be exactly one action")
  named = names(stack, module, collateral)
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
  ] + ([] if batch4 is None else [
    section(
      "Batch 4: cNGN as margin (configure)",
      f"After the escrow deploy (`{collateral_path.name}`: escrow `{collateral['escrow']}`, factor "
      f"{int(collateral['marginFactor']) / 10**16:.0f}%, cap {int(collateral['collateralCap']) // 10**18:,} cNGN, rate floor "
      f"{int(collateral.get('rateFloor', 0)) / 10**16:.0f}%; hash of both batches `{collateral['batchHash']}`). In order; every "
      "prefix is a safe place to stop. None of these lets cNGN in.",
      batch4, named, stack),
    section(
      "Batch 5: cNGN as margin (open deposits)",
      "LAST, on its own. Sign only once the keeper, markets-service and app are deployed with the escrow configured "
      "and the mainnet-fork rehearsal has run a cNGN scenario against this escrow.",
      batch5, named, stack),
  ]))


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
  factor = "0x" + keccak(b"setBaseAssetMarginFactor(uint256,uint256,uint256)").hex()[:8]
  sig, args = decode(factor + f"{1:064x}" + f"{5 * 10**17:064x}" + f"{10**18:064x}")
  assert args == [1, 5 * 10**17, 10**18]
  purpose(sig, args, "srm", {})
  try:
    purpose(sig, [1, 6 * 10**17, 10**18], "srm", {})  # above the sized factor
    raise AssertionError("a factor above the sized one must be refused")
  except SystemExit:
    pass
  irm = "0x" + keccak(b"setInterestRateModel(address)").hex()[:8]
  sig, args = decode(irm + "00" * 12 + "cd" * 20)
  assert sig == "setInterestRateModel(address)" and "floor" in purpose(sig, args, "cash", {})
  wl = "0x" + keccak(b"whitelistAsset(address,uint256,uint8)").hex()[:8]
  sig, args = decode(wl + "00" * 12 + "ab" * 20 + f"{1:064x}" + f"{3:064x}")
  assert args[2] == 3 and "BASE" in purpose(sig, args, "srm", {})
  print("self-test ok")
  return 0


def main() -> int:
  ap = argparse.ArgumentParser(description="Render the perp vault batches for review")
  ap.add_argument("--self-test", action="store_true")
  ap.add_argument("--stack", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_STACK.json")
  ap.add_argument("--stack-actions", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_STACK_VAULT_ACTIONS.json")
  ap.add_argument("--module", type=Path, default=EXECUTION / "deployments/8453/CNGN_PERP_TRADE_MODULE.json")
  ap.add_argument("--module-actions", type=Path, default=EXECUTION / "deployments/8453/CNGN_PERP_TRADE_MODULE_VAULT_ACTIONS.json")
  ap.add_argument("--collateral", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_COLLATERAL.json")
  ap.add_argument("--collateral-actions", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_COLLATERAL_VAULT_ACTIONS.json")
  ap.add_argument("--collateral-enable", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_COLLATERAL_ENABLE_VAULT_ACTIONS.json")
  ap.add_argument("--out", type=Path, default=ROOT / "deployments/8453/CNGN_PERP_VAULT_REVIEW.md")
  args = ap.parse_args()
  if args.self_test:
    return self_test()
  args.out.write_text(render(args.stack, args.stack_actions, args.module, args.module_actions, args.collateral, args.collateral_actions, args.collateral_enable))
  print(f"wrote {args.out}")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
