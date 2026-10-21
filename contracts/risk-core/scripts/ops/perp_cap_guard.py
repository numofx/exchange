#!/usr/bin/env python3
"""The one check every proposer runs before it reaches MPCVault: never a nonzero cNGN-PERP position cap.

The perp is delisted (exchange #251, 2026-10-21) and its cap under the perp SRM is 0 (tx 0x77efbb84…). A nonzero
cap under any manager, the SRM or the MarginEngine, would let SubAccounts.submitTransfer open perp positions between
accounts that no venue lists. The check reads the calldata, not a table of action indices, so no flag, no edit to a
DEFERRED or REFUSED table and no gate a script skips lets such an action through. Closing (a zero cap) passes.

The perp's address is pinned here as well as taken from the caller, so an artifact naming another perp does not
narrow the check.

  python3 scripts/ops/perp_cap_guard.py --self-test
"""

from __future__ import annotations

import sys
from pathlib import Path

PERP_ASSET = "0xC74EfC8B4808803dBCF439E76Fde076d56625b8E"  # CNGN_PERP_STACK.json .perp
SET_TOTAL_POSITION_CAP = "0x40a557bd"  # setTotalPositionCap(address,uint256), pinned by --self-test


def opens_a_perp_cap(action: dict, perp: str = PERP_ASSET) -> bool:
  """Whether the action is perp.setTotalPositionCap(any manager, nonzero)."""
  data = action["data"].lower()
  if action["to"].lower() not in {perp.lower(), PERP_ASSET.lower()} or not data.startswith(SET_TOTAL_POSITION_CAP):
    return False
  cap = data[2 + 8 + 64:2 + 8 + 128]
  return cap == "" or int(cap, 16) != 0


def propose_checked(token: str, vault_uuid: str, vault: str, action: dict, send, perp: str = PERP_ASSET) -> str:
  """Send `action` with `send` (the MPCVault transport) unless it opens a perp cap; then refuse, whatever called."""
  if opens_a_perp_cap(action, perp):
    raise SystemExit(f"REFUSED: {action.get('description')} would open the delisted perp (exchange #251); "
                     "no proposer sends a nonzero perp cap")
  return send(token, vault_uuid, vault, action)


def self_test() -> int:
  sys.path.insert(0, str(Path(__file__).resolve().parent))
  from abi_selectors import assert_script
  from resolve_cngn_action6 import keccak
  assert_script(__file__)
  assert "0x" + keccak(b"setTotalPositionCap(address,uint256)").hex()[:8] == SET_TOTAL_POSITION_CAP
  word = lambda v: format(v, "064x")  # noqa: E731
  for manager in ("de0423d0a1e15536265c9513d2e0c10dab5835d4", "a19e296021c9df25b90d96c2a0793cc3d0800758"):
    for cap, opens in ((1, True), (50_000_000 * 10**18, True), (0, False)):
      act = {"to": PERP_ASSET, "data": SET_TOTAL_POSITION_CAP + "0" * 24 + manager + word(cap)}
      assert opens_a_perp_cap(act) is opens, (manager, cap)
      # an artifact naming another perp does not narrow the check
      assert opens_a_perp_cap(act, perp="0x" + "11" * 20) is opens, (manager, cap)
  assert opens_a_perp_cap({"to": PERP_ASSET, "data": SET_TOTAL_POSITION_CAP + "0" * 64}), "a truncated cap"
  assert not opens_a_perp_cap({"to": "0x" + "22" * 20, "data": SET_TOTAL_POSITION_CAP + "0" * 64 + word(1)}), \
    "another asset's cap (the escrows, the future) is not the perp's"
  sent = []
  assert propose_checked("t", "v", "0x", {"to": "0x" + "22" * 20, "data": "0x00"}, lambda *a: sent.append(a) or "ok") == "ok"
  try:
    propose_checked("t", "v", "0x", {"to": PERP_ASSET, "data": SET_TOTAL_POSITION_CAP + "0" * 64 + word(1)},
                    lambda *a: sent.append(a))
  except SystemExit as refused:
    assert "#251" in str(refused), refused
  else:
    raise AssertionError("a nonzero perp cap reached the transport")
  assert len(sent) == 1, sent
  print("self-test ok: a nonzero perp cap under any manager is refused before the transport; zero and other assets pass")
  return 0


if __name__ == "__main__":
  if "--self-test" in sys.argv:
    raise SystemExit(self_test())
  raise SystemExit(__doc__)
