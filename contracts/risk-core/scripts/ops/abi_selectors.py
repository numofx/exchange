#!/usr/bin/env python3
"""Every selector a script pins must name a function that exists in a compiled contract.

A self-test that compares a pinned selector with `cast sig` of the same name proves only that the two agree: a
misspelt or misremembered function (`getOIFeeRateBPS` for the viewer's `OIFeeRateBPS`) passes it, and on chain the
call reverts or reads empty space. This module checks the name itself against the ABIs forge compiled, in both
contract trees (risk-core and execution).

Two ways in:
  - each script's own --self-test calls `assert_script(__file__)`: every signature string and 4-byte literal in its
    source must name a compiled function;
  - `python3 abi_selectors.py --self-test` sweeps the source of every script under scripts/ and scripts/ops/ (found,
    not listed) for signature strings and 4-byte hex literals, so a script without a self-test, or a selector written
    inline, is covered too.

The check is existence in some compiled contract, not on the contract the call targets: targets are mostly read from
artifacts at run time. A wrong name, a wrong argument type, or a function that was removed all fail it.

Needs a full `forge build` in contracts/risk-core and contracts/execution first (verify.sh and CI do it).
"""

from __future__ import annotations

import json
import re
import sys
from functools import lru_cache
from pathlib import Path

HERE = Path(__file__).resolve().parent
RISK_CORE = HERE.parents[1]
CONTRACTS = RISK_CORE.parent
OUT_DIRS = [CONTRACTS / "risk-core" / "out", CONTRACTS / "execution" / "out"]

sys.path.insert(0, str(HERE))
from resolve_cngn_action6 import keccak  # noqa: E402

# A signature string as scripts write it: name(type,type), as cast also takes it with its return types appended,
# `name(args)(returns)`. Only name(args) is the selector.
SIGNATURE_STRING = re.compile(r'"([A-Za-z_][A-Za-z0-9_]*\([a-z0-9\[\](),]*\))"')
SELECTOR = re.compile(r'"(0x[0-9a-fA-F]{8})"')
# `cast abi-encode "f(uint96,uint64)" ...`: encoding templates, the name is a placeholder and never called
ENCODE_PLACEHOLDER = "f"

# Calls to contracts compiled in neither tree, each with the reason. Keep this short: every entry is a place the check
# does not look.
NOT_COMPILED: dict[str, dict[str, str]] = {
  "log_cngn_basis.py": {"slot0()": "the Uniswap v3 cNGN/USDC pool's price, an external contract"},
  # eurc_depth/: Base DEXes the EURC depth reading quotes; selectors pinned against `cast sig` in depth.py --self-test.
  "pools.py": {
    "Deposit(address,uint256,uint128)": "Aerodrome CLGauge event (topic, not a call)",
    "Withdraw(address,uint256,uint128)": "Aerodrome CLGauge event (topic, not a call)",
    "gauge()": "Aerodrome Slipstream CLPool",
    "nft()": "Aerodrome Slipstream CLPool",
    "slot0()": "Aerodrome Slipstream CLPool",
    "liquidity()": "Aerodrome Slipstream CLPool",
    "stakedLiquidity()": "Aerodrome Slipstream CLPool",
    "getPool(address,address,uint24)": "Uniswap v3 factory",
    "getPool(address,address,bool)": "Aerodrome v2 PoolFactory",
    "getPool(address,address,int24)": "Aerodrome Slipstream CLFactory",
  },
  "depth.py": {
    "quoteExactInputSingle((address,address,uint256,uint24,uint160))": "Uniswap v3 QuoterV2",
    "quoteExactInputSingle((address,address,uint256,int24,uint160))": "Aerodrome Slipstream QuoterV2",
    "quoteExactInputSingle(((address,address,uint24,int24,address),bool,uint128,bytes))": "Uniswap v4 V4Quoter",
    "getAmountsOut(uint256,(address,address,bool,address)[])": "Aerodrome v2 Router",
    "stakedLiquidity()": "Aerodrome Slipstream CLPool",
  },
}


def signature_of(text: str) -> str:
  """name(args) out of name(args) or name(args)(returns), by balancing the first parenthesis."""
  depth = 0
  for i, ch in enumerate(text):
    if ch == "(":
      depth += 1
    elif ch == ")":
      depth -= 1
      if depth == 0:
        return text[: i + 1]
  return text


def _type(param: dict) -> str:
  t = param["type"]
  if t.startswith("tuple"):
    return "(" + ",".join(_type(c) for c in param.get("components", [])) + ")" + t[len("tuple"):]
  return t


@lru_cache(maxsize=1)
def compiled() -> dict[str, set[str]]:
  """Canonical signature -> contracts that declare it, over functions, events and errors of every compiled ABI."""
  found: dict[str, set[str]] = {}
  for out in OUT_DIRS:
    if not out.is_dir():
      raise SystemExit(f"abi_selectors: {out} missing; run `forge build` in {out.parent} first")
    for path in out.glob("*/*.json"):
      try:
        abi = json.loads(path.read_text()).get("abi", [])
      except (json.JSONDecodeError, AttributeError):
        continue
      for item in abi:
        if item.get("type") in ("function", "event", "error"):
          sig = f"{item['name']}({','.join(_type(p) for p in item.get('inputs', []))})"
          found.setdefault(sig, set()).add(path.stem)
  if not found:
    raise SystemExit("abi_selectors: no compiled ABIs found; run `forge build` first")
  return found


@lru_cache(maxsize=1)
def by_selector() -> dict[str, set[str]]:
  table: dict[str, set[str]] = {}
  for sig in compiled():
    table.setdefault("0x" + keccak(sig.encode()).hex()[:8], set()).add(sig)
  return table


def missing(signatures) -> list[str]:
  """The signatures that no compiled contract declares."""
  known = compiled()
  return sorted({s for s in signatures if s not in known})


def assert_compiled(signatures, where: str) -> None:
  """For a script's --self-test: every signature it pins exists in a compiled contract."""
  bad = missing(signatures)
  assert not bad, f"{where}: no compiled contract declares {', '.join(bad)} (a wrong name or argument type)"


def assert_selectors_compiled(selectors, where: str) -> None:
  """For a script that pins bare 4-byte selectors: each is the selector of a compiled function."""
  known = by_selector()
  bad = sorted({s.lower() for s in selectors if s.lower() not in known})
  assert not bad, f"{where}: no compiled function has selector {', '.join(bad)}"


def scripts() -> list[Path]:
  return sorted([*RISK_CORE.glob("scripts/*.py"), *RISK_CORE.glob("scripts/ops/*.py"), *RISK_CORE.glob("scripts/ops/*/*.py")])


def check_file(path: Path) -> list[str]:
  """Every signature string and 4-byte literal in one script, checked against the compiled ABIs."""
  path = Path(path)
  text = path.read_text()
  skip = NOT_COMPILED.get(path.name, {})
  problems: list[str] = []
  for sig in sorted({signature_of(s) for s in SIGNATURE_STRING.findall(text)}):
    if sig.startswith(ENCODE_PLACEHOLDER + "(") or sig in skip:
      continue
    if missing([sig]):
      problems.append(f"{path.name}: {sig} is in no compiled contract")
  known_selectors = by_selector()
  for sel in sorted({s.lower() for s in SELECTOR.findall(text)}):
    if sel not in known_selectors:
      problems.append(f"{path.name}: {sel} is the selector of no compiled function")
  return problems


def assert_script(path) -> None:
  """For a script's own --self-test: every selector and signature it pins names a compiled function."""
  problems = check_file(Path(path))
  assert not problems, "selectors that name nothing compiled:\n  " + "\n  ".join(problems)


def sweep() -> list[str]:
  """Every script under scripts/ and scripts/ops/, including those with no self-test of their own."""
  return [p for path in scripts() if path.name != Path(__file__).name for p in check_file(path)]


def self_test() -> int:
  # the check fires: a real signature passes, a misnamed one and a wrong argument type fail
  assert not missing(["OIFeeRateBPS(address)"]), "a real viewer getter must be found"
  assert missing(["getOIFeeRateBPS(address)"]) == ["getOIFeeRateBPS(address)"], "a misnamed getter must be refused"
  assert missing(["OIFeeRateBPS(uint256)"]), "a wrong argument type must be refused"
  assert "0x2a84d6d9" in by_selector(), "OIFeeRateBPS(address)'s selector must resolve"
  assert "0x4425c798" not in by_selector(), "getOIFeeRateBPS(address)'s selector must not"
  assert signature_of("getSpot()(uint256,uint256)") == "getSpot()", "cast's return types are not the selector"
  assert signature_of("f((bytes,uint256),address)") == "f((bytes,uint256),address)"
  problems = sweep()
  assert not problems, "selectors that name nothing compiled:\n  " + "\n  ".join(problems)
  print(f"self-test ok: {len(scripts()) - 1} scripts swept against {len(compiled())} compiled signatures")
  return 0


if __name__ == "__main__":
  if "--self-test" in sys.argv:
    raise SystemExit(self_test())
  if "--report" in sys.argv:
    for line in sweep():
      print(line)
    raise SystemExit(0)
  print(__doc__)
