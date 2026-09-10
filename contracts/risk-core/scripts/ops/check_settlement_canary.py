#!/usr/bin/env python3
"""Settlement canary: can the venue still price and settle?

The 2026-09-01 feed outage was silent for 6.8 days. Every service was healthy, the API
answered, orders matched -- and every on-chain settlement reverted BLF_DataTooOld. It was
found by accident. Nothing was watching the one thing that had actually broken.

Four checks, deliberately overlapping:

  1. getMargin(accountId, true) on the StandardManager, for each configured subaccount.
     This walks the same path a settlement does -- _getMarketMargin reads the spot feed for
     every market the account holds a position in -- so a revert means the book cannot
     settle, whatever the cause: a stale feed, a bad repoint, a misconfigured market.

  2. getSpot() on every market's spot feed and on the global stableFeed. Account-independent,
     so it still catches a stale feed for a market nobody currently holds. Check 1 alone
     would report healthy in that case, which is exactly the blind spot that let the last
     outage run for a week.

  3. COLLATERAL BACKING of the cash ledger: every unit of cash must be backed by a real USDC
     sitting in the CashAsset, nothing borrowed, and nothing printed by a manager.
     Checks 1 and 2 answer "can the venue price a trade"; this answers "is what it would
     settle actually there".

  4. WRAPPER BACKING: a WrappedERC20Asset mints on deposit and burns on withdraw, so its real
     token balance must equal the position it has credited. Any divergence means tokens
     entered or left without going through deposit()/withdraw().

An empty subaccount has no market holding, so the manager reads no feed and check 1 passes
while proving nothing. Point CANARY_ACCOUNTS at accounts that actually hold positions; the
script says so loudly when a checked account turns out to have zero markets.

Env (or ~/.numo-feeds.env):
  RPC_URL            Base mainnet RPC
  ALERT_WEBHOOK_URL  Slack/Discord-compatible webhook (optional; logs only if unset)
  SRM_ADDRESS        StandardManager (default: the live Base deployment)
  EXPECTED_NET_SETTLED_CASH  pin for netSettledCash; alert if it moves (unset = not checked)
  WRAPPER_DELTA_EXCEPTIONS
                     comma-separated <wrapperAddress>:<expectedDelta18dp> pairs. A wrapper listed
                     here is healthy at exactly that delta and alerts if it MOVES, in either
                     direction. Unlisted wrappers must be exactly 1:1. See the exceptions block
                     below for why one exists and why it is pinned rather than tolerated.
  FEE_SUBACCOUNT, FEE_VAULT, FEE_MODULE, FEE_QUOTE_ASSET
                     the wrapped-quote fee account, its expected owner, the trade module that
                     must hold a positive allowance on it, and the quote asset. All four
                     required together, or the check is skipped.
  CANARY_ACCOUNTS    comma-separated subaccount ids (default: 15)

Run every few minutes via systemd timer (see numo-settlement-canary.timer).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

DEFAULT_SRM = "0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b"
DEFAULT_ACCOUNTS = "15"

# Verified with `cast sig`. A wrong selector here would eth_call into empty space and the
# node would answer 0x, which this script treats as a failure rather than a pass -- but the
# alert would name the wrong cause, so they are pinned and self-tested.
SEL_GET_MARGIN = "0x623bb445"      # getMargin(uint256,bool)
SEL_GET_MARKET_FEEDS = "0xa95371a4"  # getMarketFeeds(uint256)
SEL_LAST_MARKET_ID = "0x565eb87c"    # lastMarketId()
SEL_STABLE_FEED = "0xf4d0508a"       # stableFeed()
SEL_GET_SPOT = "0x2b37269c"          # getSpot()
SEL_CASH_ASSET = "0x5cd93cf3"        # cashAsset()
SEL_BALANCE_OF = "0x70a08231"        # balanceOf(address)
SEL_TOTAL_SUPPLY = "0x18160ddd"      # totalSupply()
SEL_TOTAL_BORROW = "0x8285ef40"      # totalBorrow()
SEL_NET_SETTLED = "0x73a46ad0"       # netSettledCash()
SEL_TOTAL_POSITION = "0xa9578774"    # totalPosition(address)
SEL_WRAPPED_ASSET = "0xd9a1836a"     # wrappedAsset()
SEL_DECIMALS = "0x313ce567"          # decimals()
SEL_SM_FEES = "0xcb5f01da"           # accruedSmFees()
SEL_OWNER_OF = "0x6352211e"          # ownerOf(uint256)
SEL_POS_ALLOWANCE = "0x4997e514"     # positiveAssetAllowance(uint256,address,address,address)
SEL_GET_BALANCE = "0x0806e640"       # getBalance(uint256,address,uint256)

# AssetWhitelisted(address,uint256,uint8) -- used to discover which assets to check, so a new
# market is covered without editing this file.
TOPIC_ASSET_WHITELISTED = "0x65e6c2e07fd179979855ae720448f582bc92322fc62ed1cd98a0cc9d4c33b94b"

# Revert selectors worth naming in an alert. Anything else is reported as raw returndata.
KNOWN_ERRORS = {
  "0x1141796d": "BLF_DataTooOld()",
  "0x93ce63e9": "BF_DataTooOld()",
  "0x1607767a": "BLF_InvalidSignature()",
}


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip().removeprefix("export ").strip(), value.strip())


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(
    url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-settlement-canary/1"}
  )
  with urllib.request.urlopen(req, timeout=15) as resp:
    out = json.loads(resp.read())
  if "error" in out:
    raise RuntimeError(out["error"])
  return out["result"]


def call(url: str, to: str, data: str) -> str:
  return rpc(url, "eth_call", [{"to": to, "data": data}, "latest"])


def describe_revert(exc: Exception) -> str:
  """Pull a named custom error out of an eth_call failure where the node returns one."""
  text = str(exc)
  actual_topic = "0x" + keccak(b"AssetWhitelisted(address,uint256,uint8)").hex()
  assert actual_topic == TOPIC_ASSET_WHITELISTED, f"whitelist topic drifted: {actual_topic}"
  assert to18(5_000_000_000, 6) == 5_000 * 10**18, "6dp -> 18dp scaling is wrong"
  assert to18(1, 18) == 1, "18dp scaling must be a no-op"
  for selector, name in KNOWN_ERRORS.items():
    if selector in text:
      return f"{name} [{selector}]"
  return text[:200]


def uint(url: str, to: str, data: str) -> int:
  return int(call(url, to, data), 16)


def as_int256(word: str) -> int:
  v = int(word, 16)
  return v - (1 << 256) if v >= (1 << 255) else v


def addr_arg(addr: str) -> str:
  return "0" * 24 + addr[2:].lower()


def to18(amount: int, decimals: int) -> int:
  """A token balance in its native decimals, restated at the 18dp the ledgers use.

  Both tokens here are 6dp while every ledger figure is 18dp, so comparing the raw numbers
  would make a fully-backed wrapper look 1e12 short. The scaling is the check.
  """
  if decimals > 18:
    raise RuntimeError(f"token has {decimals} decimals; refusing to round down to 18")
  return amount * (10 ** (18 - decimals))


def check_cash_backing(url: str, srm: str, failures: list, checked: list) -> None:
  """Every unit of cash backed by a real USDC, nothing borrowed, nothing manager-printed.

  netSettledCash is the manager-credited component of totalSupply (CashAsset's own
  convention), so a non-zero value means cash exists that no deposit put there.
  """
  cash = "0x" + call(url, srm, SEL_CASH_ASSET)[26:]
  token = "0x" + call(url, cash, SEL_WRAPPED_ASSET)[26:]
  decimals = uint(url, token, SEL_DECIMALS)

  held = to18(uint(url, token, SEL_BALANCE_OF + addr_arg(cash)), decimals)
  supply = uint(url, cash, SEL_TOTAL_SUPPLY)
  borrow = uint(url, cash, SEL_TOTAL_BORROW)
  settled = as_int256(call(url, cash, SEL_NET_SETTLED))
  sm_fees = uint(url, cash, SEL_SM_FEES)

  # Backing as CashAsset itself defines it: _getTotalCash subtracts netSettledCash, because
  # manager-settled cash is recorded there so the contract does not treat it as requiring
  # backing. Comparing against raw totalSupply would be permanently red on any venue that has
  # settled asymmetrically -- red for a reason nobody can act on.
  total_cash = supply + sm_fees - borrow - settled
  ok = True
  if held < total_cash:
    ok = False
    failures.append(
      f"cash {cash} UNDER-BACKED: holds {held / 1e18:.6f} USDC against {total_cash / 1e18:.6f} "
      f"of backed cash (short {(total_cash - held) / 1e18:.6f})"
    )
  if borrow != 0:
    ok = False
    failures.append(f"cash {cash} totalBorrow is {borrow / 1e18:.6f}, expected 0")

  # Pinned, not required-zero. donateBalance burns against total_cash, which already excludes
  # netSettledCash, so a max donate burns exactly 0 -- verified on a Base fork. Requiring zero
  # would page forever about a value no available call can change. What matters is movement.
  expected = os.environ.get("EXPECTED_NET_SETTLED_CASH")
  if expected is not None and expected.strip() != "":
    if settled != int(expected):
      ok = False
      failures.append(
        f"cash {cash} netSettledCash MOVED: {settled / 1e18:.6f}, pinned at {int(expected) / 1e18:.6f} "
        f"(delta {(settled - int(expected)) / 1e18:+.6f}) -- a manager printed or burned settled cash"
      )
  if ok:
    checked.append(
      f"cash {cash} backed ({held / 1e18:.6f} USDC against {total_cash / 1e18:.6f} required; "
      f"netSettledCash {settled / 1e18:.6f})"
    )


# ---------------------------------------------------------------------------------------------
# STANDING EXCEPTION - wrapped USDC, 2026-09-10
#
#   0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84 permanently holds 5.000000 USDC more than it has
#   credited.
#
# Cause: tx 0xfcf33112414f44cc53c493e28da4ec57cde8d029ac3920144aceab23dbe5656b, block 51125714.
# A plain ERC20 transfer of 5 USDC straight to the wrapper during the wrapped-quote cutover,
# sent through MPCVault's "Send USDC" flow instead of a Custom transaction. Send builds
# transfer(to, amount) and has nowhere to put calldata, so the intended deposit(15, 5000000)
# never happened: the tokens arrived, no position was credited, and the ERC20 allowance was
# left unspent -- which is how we knew within minutes that it was a transfer and not a deposit.
#
# RECOVERY: none. WrappedERC20Asset exposes exactly two external functions. deposit() always
# transfers in and credits the same amount; withdraw() requires msg.sender to own an account and
# reverts WERC_CannotBeNegative if the debit would take that account below zero. There is no
# rescue, skim or sweep, no owner-only path, and the contract is not behind a proxy -- both
# EIP-1967 slots read zero -- so the code cannot change. Nobody can withdraw these tokens,
# including the vault. They are inert over-collateral: every legitimate holder can still
# withdraw exactly what they deposited, and this 5 simply sits behind them.
#
# WHY PINNED RATHER THAN TOLERATED: the invariant keeps its teeth. Any NEW divergence moves the
# delta off 5e18 and fires immediately, in either direction. Widening the check to "over-backed
# is fine" would have thrown away the property that caught this within minutes of it happening.
# ---------------------------------------------------------------------------------------------


def wrapper_exceptions() -> dict:
  """Parse WRAPPER_DELTA_EXCEPTIONS into {lowercased address: expected delta at 18dp}."""
  raw = os.environ.get("WRAPPER_DELTA_EXCEPTIONS", "").strip()
  out = {}
  for entry in (e.strip() for e in raw.split(",") if e.strip()):
    addr, _, delta = entry.partition(":")
    if not delta:
      raise SystemExit(f"WRAPPER_DELTA_EXCEPTIONS entry {entry!r} must be <address>:<delta>")
    out[addr.strip().lower()] = int(delta)
  return out


def check_wrapper_backing(url: str, srm: str, failures: list, checked: list) -> None:
  """A WrappedERC20Asset's real token balance must equal the position it has credited.

  Discovered from AssetWhitelisted logs rather than hardcoded, so a new market is covered
  without editing this file. totalPosition is per-manager and the manager set is not
  enumerable on chain, so this compares against the manager we were given: another manager
  holding a position makes the check go RED rather than silently pass, which is the safe
  direction to fail in.
  """
  exceptions = wrapper_exceptions()
  logs = rpc(url, "eth_getLogs", [{
    "fromBlock": "0x0", "toBlock": "latest", "address": srm, "topics": [TOPIC_ASSET_WHITELISTED],
  }])
  seen = set()
  for entry in logs:
    asset = "0x" + entry["data"][2:][24:64]
    if asset in seen:
      continue
    seen.add(asset)
    try:
      token = "0x" + call(url, asset, SEL_WRAPPED_ASSET)[26:]
      decimals = uint(url, token, SEL_DECIMALS)
    except Exception:
      continue  # not a wrapper (cash is excluded this way too); nothing to compare

    held = to18(uint(url, token, SEL_BALANCE_OF + addr_arg(asset)), decimals)
    credited = uint(url, asset, SEL_TOTAL_POSITION + addr_arg(srm))
    delta = held - credited
    expected = exceptions.get(asset.lower(), 0)

    if delta != expected:
      note = (
        " -- tokens moved without deposit()/withdraw()" if expected == 0
        else f" -- this wrapper is pinned at {expected / 1e18:+.6f}; the delta MOVED by "
             f"{(delta - expected) / 1e18:+.6f}"
      )
      failures.append(
        f"wrapper {asset} BACKING MISMATCH: holds {held / 1e18:.6f} of {token} but has "
        f"credited {credited / 1e18:.6f} (delta {delta / 1e18:+.6f}){note}"
      )
    elif expected:
      checked.append(
        f"wrapper {asset} backed with a pinned {expected / 1e18:+.6f} exception "
        f"({held / 1e18:.6f} held / {credited / 1e18:.6f} credited)"
      )
    else:
      checked.append(f"wrapper {asset} backed 1:1 ({held / 1e18:.6f})")


def check_fee_recipient(url: str, failures: list, checked: list) -> None:
  """The wrapped-quote fee path, which fails silently and only under load.

  Two ways it breaks after the cutover, neither visible from a balance:

    - The fee subaccount changes owner. setAssetAllowances keys the grant by
      ownerOf(accountId), so a transfer silently voids it and every fee-bearing fill starts
      reverting NotEnoughSubIdOrAssetAllowances.
    - The allowance is spent down or revoked. _spendAbsAllowance decrements on every fill and
      has no max-value exemption, so a grant that is not type(uint).max is a scheduled outage.

  Skipped unless all four env vars are set: before the cutover the fee subaccount does not
  exist yet, and a check that invents an account id would be worse than no check.
  """
  account = os.environ.get("FEE_SUBACCOUNT", "").strip()
  vault = os.environ.get("FEE_VAULT", "").strip()
  module = os.environ.get("FEE_MODULE", "").strip()
  quote = os.environ.get("FEE_QUOTE_ASSET", "").strip()
  if not (account and vault and module and quote):
    return

  sub_accounts = "0x" + call(url, os.environ.get("SRM_ADDRESS", DEFAULT_SRM), "0x779e5012")[26:]
  account_word = f"{int(account):064x}"

  owner = "0x" + call(url, sub_accounts, SEL_OWNER_OF + account_word)[26:]
  if owner.lower() != vault.lower():
    failures.append(
      f"fee subaccount {account} OWNER CHANGED: {owner}, expected {vault} "
      "-- the allowance is keyed by owner, so the grant is now void and every fee-bearing fill reverts"
    )
    return

  allowance = uint(url, sub_accounts, SEL_POS_ALLOWANCE + account_word + addr_arg(owner) + addr_arg(quote) + addr_arg(module))
  if allowance == 0:
    failures.append(
      f"fee subaccount {account} has NO positive {quote} allowance for module {module} "
      "-- every fee-bearing fill reverts NotEnoughSubIdOrAssetAllowances"
    )
    return

  # A finite grant is a scheduled outage: allowances decrement on every spend with no max-value
  # exemption. Warn well before it bites rather than at the moment a fill fails.
  if allowance < (1 << 255):
    failures.append(
      f"fee subaccount {account} allowance is finite ({allowance}) and decrements on every fill "
      "-- it will run out; re-grant type(uint).max"
    )
    return

  # Fee accrual, so a venue that has switched fees on can be seen earning them -- and one that
  # thinks it has can be seen not earning them. A silently-zero fee account is the symptom of a
  # schedule that never reached the matcher.
  balance = int(call(url, sub_accounts, SEL_GET_BALANCE + account_word + addr_arg(quote) + "0" * 64), 16)
  if balance >= (1 << 255):
    balance -= 1 << 256
  checked.append(
    f"fee subaccount {account} vault-owned, unbounded allowance, accrued {balance / 1e18:.6f} of {quote}"
  )


def alert(webhook: str | None, msg: str) -> None:
  print(msg, file=sys.stderr)
  if not webhook:
    return
  body = json.dumps({"text": msg, "content": msg}).encode()
  req = urllib.request.Request(webhook, data=body, headers={"Content-Type": "application/json"})
  try:
    urllib.request.urlopen(req, timeout=15).read()
  except Exception as exc:
    print(f"webhook delivery failed: {exc}", file=sys.stderr)


def self_test() -> None:
  sys.path.insert(0, str(Path(__file__).resolve().parent))
  from resolve_cngn_action6 import keccak

  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"
  for signature, expected in {
    "getMargin(uint256,bool)": SEL_GET_MARGIN,
    "getMarketFeeds(uint256)": SEL_GET_MARKET_FEEDS,
    "lastMarketId()": SEL_LAST_MARKET_ID,
    "stableFeed()": SEL_STABLE_FEED,
    "getSpot()": SEL_GET_SPOT,
    "cashAsset()": SEL_CASH_ASSET,
    "balanceOf(address)": SEL_BALANCE_OF,
    "totalSupply()": SEL_TOTAL_SUPPLY,
    "totalBorrow()": SEL_TOTAL_BORROW,
    "netSettledCash()": SEL_NET_SETTLED,
    "totalPosition(address)": SEL_TOTAL_POSITION,
    "wrappedAsset()": SEL_WRAPPED_ASSET,
    "decimals()": SEL_DECIMALS,
    "accruedSmFees()": SEL_SM_FEES,
    "ownerOf(uint256)": SEL_OWNER_OF,
    "positiveAssetAllowance(uint256,address,address,address)": SEL_POS_ALLOWANCE,
    "getBalance(uint256,address,uint256)": SEL_GET_BALANCE,
  }.items():
    actual = "0x" + keccak(signature.encode()).hex()[:8]
    assert actual == expected, f"{signature}: hardcoded {expected}, actual {actual}"
  actual_topic = "0x" + keccak(b"AssetWhitelisted(address,uint256,uint8)").hex()
  assert actual_topic == TOPIC_ASSET_WHITELISTED, f"whitelist topic drifted: {actual_topic}"
  assert to18(5_000_000_000, 6) == 5_000 * 10**18, "6dp -> 18dp scaling is wrong"
  assert to18(1, 18) == 1, "18dp scaling must be a no-op"
  for selector, name in KNOWN_ERRORS.items():
    actual = "0x" + keccak(name.encode()).hex()[:8]
    assert actual == selector, f"{name}: hardcoded {selector}, actual {actual}"


def main() -> int:
  if "--self-test" in sys.argv:
    self_test()
    print("self-test ok: every selector matches its signature")
    return 0

  load_env_file(Path.home() / ".numo-feeds.env")
  url = os.environ.get("RPC_URL", "https://mainnet.base.org")
  webhook = os.environ.get("ALERT_WEBHOOK_URL")
  srm = os.environ.get("SRM_ADDRESS", DEFAULT_SRM)
  accounts = [int(a) for a in os.environ.get("CANARY_ACCOUNTS", DEFAULT_ACCOUNTS).split(",") if a.strip()]

  self_test()

  failures: list[str] = []      # cannot price -- the venue is halted
  solvency: list[str] = []      # can price, but what it would settle is not there
  checked: list[str] = []

  # 1. the manager path, per account
  for account_id in accounts:
    payload = SEL_GET_MARGIN + f"{account_id:064x}" + f"{1:064x}"
    try:
      margin = call(url, srm, payload)
      value = int(margin, 16)
      if value >= 1 << 255:
        value -= 1 << 256
      checked.append(f"getMargin({account_id}) = {value / 1e18:.6f}")
    except Exception as exc:
      failures.append(f"getMargin({account_id}) REVERTED: {describe_revert(exc)}")

  # 2. every feed the SRM could read, whether or not anyone holds that market
  try:
    last_market = int(call(url, srm, SEL_LAST_MARKET_ID), 16)
  except Exception as exc:
    alert(webhook, f"NUMO SETTLEMENT CANARY FAILED\nlastMarketId() on {srm}: {exc}")
    return 1

  feeds: list[tuple[str, str]] = []
  for market_id in range(1, last_market + 1):
    try:
      word = call(url, srm, SEL_GET_MARKET_FEEDS + f"{market_id:064x}")
      feeds.append((f"market {market_id} spot", "0x" + word[26:66]))
    except Exception as exc:
      failures.append(f"getMarketFeeds({market_id}) REVERTED: {describe_revert(exc)}")
  try:
    feeds.append(("stableFeed", "0x" + call(url, srm, SEL_STABLE_FEED)[26:]))
  except Exception as exc:
    failures.append(f"stableFeed() REVERTED: {describe_revert(exc)}")

  for label, feed in feeds:
    if int(feed, 16) == 0:
      continue  # unset feed: only read for asset types this venue does not list
    try:
      spot = int(call(url, feed, SEL_GET_SPOT)[2:66], 16)
      checked.append(f"{label} {feed} getSpot = {spot / 1e18:.10f}")
    except Exception as exc:
      failures.append(f"{label} {feed} getSpot() REVERTED: {describe_revert(exc)}")

  # 3 & 4. solvency, independent of whether anything can be priced
  try:
    check_cash_backing(url, srm, solvency, checked)
  except Exception as exc:
    failures.append(f"cash backing check FAILED to run: {describe_revert(exc)}")
  try:
    check_wrapper_backing(url, srm, solvency, checked)
  except Exception as exc:
    failures.append(f"wrapper backing check FAILED to run: {describe_revert(exc)}")
  try:
    check_fee_recipient(url, solvency, checked)
  except Exception as exc:
    failures.append(f"fee recipient check FAILED to run: {describe_revert(exc)}")

  # Two different emergencies, deliberately not merged into one message. A halt stops trading
  # and is loud on its own; a backing failure lets trading continue against collateral that is
  # not there, which is worse and reads completely differently to whoever is woken up.
  if failures or solvency:
    parts = []
    if failures:
      parts.append(
        "NUMO SETTLEMENT HALTED\n"
        "The venue cannot price or settle. Orders will keep matching off-chain and every\n"
        "on-chain leg will revert, silently, until this is fixed.\n\n"
        + "\n".join(f"  - {f}" for f in failures)
      )
    if solvency:
      parts.append(
        "NUMO COLLATERAL BACKING FAILURE\n"
        "The venue can still price and settle -- and that is the problem. Ledger balances are\n"
        "not matched by the tokens behind them, so fills continue against collateral that is\n"
        "not there.\n\n"
        + "\n".join(f"  - {f}" for f in solvency)
      )
    if checked:
      parts.append("still healthy:\n" + "\n".join(f"  - {c}" for c in checked))
    alert(webhook, "\n\n".join(parts))
    return 1

  print("ok: " + "; ".join(checked))
  return 0


if __name__ == "__main__":
  sys.exit(main())
