#!/usr/bin/env python3
"""Re-derive the recorded core addresses AND the documented SRM state from live chain state.

Why this exists: `deployments/8453/core.json` recorded `stableFeed` as the live
LyraSpotFeed, but the vault batch repointed the SRM at a static feed and nobody updated
the artifact. `scripts/deploy-market.s.sol` and `scripts/deploy-pm2.s.sol` read that key,
so the next new market would have been wired to a dead feed. A hand edit fixes today's
drift; deriving from chain is what stops it recurring.

Only the SRM address and the chain id are trusted as input. Everything derivable is read
back through the SRM:

    srm.subAccounts()   -> subAccounts
    srm.cashAsset()     -> cash
    srm.liquidation()   -> auction
    srm.viewer()        -> srmViewer
    srm.stableFeed()    -> stableFeed
    cash.rateModel()    -> rateModel

Keys with no on-chain path from the SRM (dataSubmitter, securityModule, and the two
settlement helpers) are reported as UNVERIFIABLE and never touched. Saying "unverifiable"
is the point: silently passing them through would imply a check that did not happen.

It also regenerates the "Live SRM state" section of DEPLOYED_ADDRESSES.md, between the
GENERATED markers. That section exists because prose went stale the same way the addresses
did, and worse: within one day this file carried a heading saying a vault batch was
"NOT YET EXECUTED" after it had executed, and later a second one saying market 1 was
"pending" after it had landed. Both were true when typed.

The split is deliberate. CURRENT STATE -- which feed a market reads, what a margin factor
is, whether borrowing is on -- is generated, because it changes without anyone editing this
file. HISTORY and RATIONALE -- transaction hashes, why an ordering was required, what a
setting is for -- stays hand-written, because it is fixed the moment it happens and no
generator can express it.

Usage:
  python3 scripts/ops/refresh_deployment_artifacts.py            # report only
  python3 scripts/ops/refresh_deployment_artifacts.py --write    # apply the derivable fixes
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
CHAIN_ID = 8453
CORE = ROOT / "deployments" / str(CHAIN_ID) / "core.json"
DOC = ROOT / "DEPLOYED_ADDRESSES.md"

# The one trusted anchor. Everything else is read back through it.
SRM = "0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b"

BEGIN_MARKER = "<!-- BEGIN GENERATED: live SRM state -->"
END_MARKER = "<!-- END GENERATED -->"

SELECTORS = {
  "subAccounts()": "0x779e5012",
  "cashAsset()": "0x5cd93cf3",
  "liquidation()": "0xf2dfbf66",
  "viewer()": "0xf30878c1",
  "stableFeed()": "0xf4d0508a",
  "rateModel()": "0xa1088459",
  # state-section reads
  "lastMarketId()": "0x565eb87c",
  "borrowingEnabled()": "0xa35d1300",
  "getMarketFeeds(uint256)": "0xa95371a4",
  "baseMarginParams(uint256)": "0xcd27955d",
  "oracleContingencyParams(uint256)": "0x0addd056",
  "getSpot()": "0x2b37269c",
  "heartbeat()": "0x3defb962",
  "assetDetails(address)": "0xd21415a3",
  "symbol()": "0x95d89b41",
  "wrappedAsset()": "0xd9a1836a",
}

ASSET_WHITELISTED_TOPIC = "0x65e6c2e07fd179979855ae720448f582bc92322fc62ed1cd98a0cc9d4c33b94b"
ASSET_TYPES = {0: "NotSet", 1: "Option", 2: "Perpetual", 3: "Base", 4: "DatedFuture"}

UNVERIFIABLE = ("dataSubmitter", "securityModule", "optionSettlementHelper", "perpSettlementHelper")


def rpc(url: str, method: str, params: list):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(
    url, data=body,
    headers={"Content-Type": "application/json", "User-Agent": "numo-ops/1.0"}, method="POST")
  with urllib.request.urlopen(req, timeout=20) as resp:
    payload = json.loads(resp.read())
  if "error" in payload:
    raise RuntimeError(f"{method}: {payload['error']}")
  return payload["result"]


def read_address(url: str, target: str, signature: str) -> str:
  """eth_call a zero-argument address getter, checksummed back through EIP-55."""
  word = rpc(url, "eth_call", [{"to": target, "data": SELECTORS[signature]}, "latest"])
  if len(word) != 66:
    raise RuntimeError(f"{signature} on {target} returned {word!r}, not one word")
  return to_checksum("0x" + word[26:])


def to_checksum(addr: str) -> str:
  from resolve_cngn_action6 import keccak  # zero-dependency, already vector-checked

  low = addr.lower().removeprefix("0x")
  digest = keccak(low.encode()).hex()
  return "0x" + "".join(c.upper() if c.isalpha() and int(digest[i], 16) >= 8 else c
                        for i, c in enumerate(low))


def call(url: str, target: str, data: str, block: str = "latest") -> str:
  return rpc(url, "eth_call", [{"to": target, "data": data}, block])


def word_address(word_hex: str, index: int = 0) -> str:
  """Pull the index-th 32-byte word out of returndata and read it as an address."""
  raw = word_hex[2:]
  chunk = raw[index * 64 : (index + 1) * 64]
  return to_checksum("0x" + chunk[24:])


def feed_kind(url: str, feed: str) -> str:
  """LyraStaticSpotFeed has no heartbeat; the keeper-driven LyraSpotFeed does.

  Read as a capability probe rather than a name lookup: a feed that cannot go stale is
  the property that matters here, and a contract's symbol or address would not prove it.
  """
  try:
    call(url, feed, SELECTORS["heartbeat()"])
    return "live"
  except Exception:
    return "static"


def read_spot(url: str, feed: str) -> str:
  try:
    out = call(url, feed, SELECTORS["getSpot()"])
    return f"{int(out[2:66], 16) / 1e18:.12f}".rstrip("0").rstrip(".")
  except Exception as exc:
    return f"REVERTED ({str(exc)[:60]})"


def read_string(url: str, target: str, selector: str) -> str | None:
  """Decode an ABI dynamic string return, or None if the call has no such method."""
  try:
    raw = call(url, target, selector)
  except Exception:
    return None
  body = raw[2:]
  if len(body) < 128:
    return None
  offset = int(body[0:64], 16) * 2
  length = int(body[offset : offset + 64], 16)
  return bytes.fromhex(body[offset + 64 : offset + 64 + length * 2]).decode(errors="replace")


def whitelisted_assets(url: str, srm: str, last_market: int) -> list[dict]:
  logs = rpc(url, "eth_getLogs", [{
    "fromBlock": "0x0", "toBlock": "latest", "address": srm, "topics": [ASSET_WHITELISTED_TOPIC],
  }])
  out = []
  for entry in logs:
    data = entry["data"][2:]
    asset = to_checksum("0x" + data[24:64])
    # Read the CURRENT registration, not the historical one: whitelistAsset can be called
    # again, and a log says only that it happened once.
    detail = call(url, srm, SELECTORS["assetDetails(address)"] + "0" * 24 + asset[2:].lower())[2:]
    if int(detail[0:64], 16) != 1:
      continue

    # struct AssetDetail { bool isWhitelisted; AssetType assetType; uint marketId; }
    # assetType comes BEFORE marketId. Decoding them the other way round yields values that
    # look entirely plausible -- a Base asset on market 1 reads as an Option on market 3 --
    # which is why the sanity check below exists rather than a comment saying "be careful".
    asset_type_id = int(detail[64:128], 16)
    market_id = int(detail[128:192], 16)
    if asset_type_id not in ASSET_TYPES or not (1 <= market_id <= last_market):
      raise SystemExit(
        f"assetDetails({asset}) decoded as assetType={asset_type_id}, marketId={market_id}, "
        f"which is impossible with lastMarketId={last_market}. The struct layout has changed."
      )

    # The wrapped asset is an IAsset, not an ERC20: it has no symbol(). The token it wraps does.
    underlying = None
    try:
      underlying = word_address(call(url, asset, SELECTORS["wrappedAsset()"]))
    except Exception:
      pass
    symbol = (read_string(url, underlying, SELECTORS["symbol()"]) if underlying else None) or "?"

    out.append({
      "asset": asset,
      "symbol": symbol,
      "underlying": underlying,
      "marketId": market_id,
      "assetType": ASSET_TYPES[asset_type_id],
    })
  return sorted(out, key=lambda a: (a["marketId"], a["asset"]))


def render_state_section(url: str, srm: str, block: int) -> str:
  """Everything here is read from chain. Nothing in it should ever be edited by hand."""
  last_market = int(call(url, srm, SELECTORS["lastMarketId()"]), 16)
  borrowing = int(call(url, srm, SELECTORS["borrowingEnabled()"]), 16) == 1
  stable = word_address(call(url, srm, SELECTORS["stableFeed()"]))

  lines = [
    BEGIN_MARKER,
    "",
    "### Live SRM state",
    "",
    f"Generated from chain at block {block} by `scripts/ops/refresh_deployment_artifacts.py --write`.",
    "Do not edit by hand — rerun the script. Narrative and transaction hashes live outside this block.",
    "",
    f"- `srm`: `{to_checksum(srm)}`",
    f"- `lastMarketId`: **{last_market}**",
    f"- `borrowingEnabled`: **{str(borrowing).lower()}**"
    + ("  ← negative cash is possible" if borrowing else "  — negative cash is rejected outright"),
    f"- `stableFeed`: `{stable}` — **{feed_kind(url, stable)}**, reads `{read_spot(url, stable)}`",
    "",
    "| market | spot feed | kind | getSpot | marginFactor | IMScale | oracle contingency |",
    "| --- | --- | --- | --- | --- | --- | --- |",
  ]

  for market_id in range(1, last_market + 1):
    feeds = call(url, srm, SELECTORS["getMarketFeeds(uint256)"] + f"{market_id:064x}")
    spot = word_address(feeds, 0)
    params = call(url, srm, SELECTORS["baseMarginParams(uint256)"] + f"{market_id:064x}")[2:]
    margin_factor = int(params[0:64], 16) / 1e18
    im_scale = int(params[64:128], 16) / 1e18
    contingency = call(url, srm, SELECTORS["oracleContingencyParams(uint256)"] + f"{market_id:064x}")[2:]
    all_zero = all(int(contingency[i : i + 64], 16) == 0 for i in range(0, 256, 64))
    lines.append(
      f"| {market_id} | `{spot}` | {feed_kind(url, spot)} | {read_spot(url, spot)} "
      f"| {margin_factor:g} | {im_scale:g} | {'all zero' if all_zero else '**NON-ZERO**'} |"
    )

  lines += ["", "Whitelisted assets:", ""]
  assets = whitelisted_assets(url, srm, last_market)
  if not assets:
    lines.append("- none")
  for a in assets:
    wraps = f", wraps `{a['symbol']}` `{a['underlying']}`" if a["underlying"] else ""
    lines.append(f"- `{a['asset']}` — market {a['marketId']}, `AssetType.{a['assetType']}`{wraps}")

  live_feeds = [
    f"market {m}" for m in range(1, last_market + 1)
    if feed_kind(url, word_address(call(url, srm, SELECTORS["getMarketFeeds(uint256)"] + f"{m:064x}"), 0)) == "live"
  ]
  if feed_kind(url, stable) == "live":
    live_feeds.append("stableFeed")
  lines += [
    "",
    "**The SRM reads no live feed**, so no publisher outage can halt settlement."
    if not live_feeds
    else f"**The SRM reads live, staleable feeds: {', '.join(live_feeds)}.** A stalled publisher halts settlement.",
    "",
    END_MARKER,
  ]
  return "\n".join(lines)


def self_test() -> None:
  """The selectors are hardcoded, so prove they are what their signatures hash to.

  Also vector-check the checksummer: a wrong one would rewrite every address in the file
  into a differently-cased but still-valid-looking string, which is the kind of diff that
  gets approved without being read.
  """
  from resolve_cngn_action6 import keccak

  assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470", "keccak broken"
  for signature, expected in SELECTORS.items():
    actual = "0x" + keccak(signature.encode()).hex()[:8]
    assert actual == expected, f"{signature}: hardcoded {expected}, actual {actual}"
  # EIP-55 vector from the spec, plus our own anchor
  assert to_checksum("0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed") == \
         "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
  assert to_checksum(SRM.lower()) == SRM, "checksummer disagrees with the recorded SRM"

  from resolve_cngn_action6 import keccak as k
  actual_topic = "0x" + k(b"AssetWhitelisted(address,uint256,uint8)").hex()
  assert actual_topic == ASSET_WHITELISTED_TOPIC, f"whitelist topic drifted: {actual_topic}"

  # A generated block that cannot be found again would be appended a second time on every
  # run, which is a worse failure than not generating it at all.
  doc = DOC.read_text()
  assert doc.count(BEGIN_MARKER) <= 1, "more than one generated block in the doc"
  assert doc.count(END_MARKER) <= 1, "more than one end marker in the doc"
  assert doc.count(BEGIN_MARKER) == doc.count(END_MARKER), "unbalanced generated-block markers"


def main() -> int:
  ap = argparse.ArgumentParser(description="Re-derive core deployment addresses from chain")
  ap.add_argument("--write", action="store_true", help="apply the derivable fixes in place")
  ap.add_argument("--self-test", action="store_true",
                  help="check the hardcoded selectors and the doc markers offline; no network")
  args = ap.parse_args()

  sys.path.insert(0, str(Path(__file__).resolve().parent))
  self_test()
  if args.self_test:
    print(f"self-test ok: {len(SELECTORS)} selectors match their signatures, "
          "checksummer matches the EIP-55 vector, generated-block markers balanced")
    return 0

  url = os.environ.get("RPC_URL") or os.environ.get("BASE_RPC_URL", "")
  if not url:
    raise SystemExit("RPC_URL (or BASE_RPC_URL) is required")

  chain_id = int(rpc(url, "eth_chainId", []), 16)
  if chain_id != CHAIN_ID:
    raise SystemExit(f"RPC is chain {chain_id}, expected {CHAIN_ID}")

  cash = read_address(url, SRM, "cashAsset()")
  derived = {
    "srm": to_checksum(SRM),
    "subAccounts": read_address(url, SRM, "subAccounts()"),
    "cash": cash,
    "auction": read_address(url, SRM, "liquidation()"),
    "srmViewer": read_address(url, SRM, "viewer()"),
    "stableFeed": read_address(url, SRM, "stableFeed()"),
    "rateModel": read_address(url, cash, "rateModel()"),
  }

  recorded = json.loads(CORE.read_text())
  drift = {k: (recorded.get(k), v) for k, v in derived.items()
           if (recorded.get(k) or "").lower() != v.lower()}

  print(f"anchor: srm {SRM} on chain {chain_id}\n")
  print(f"{'key':<24} {'recorded':<44} {'chain':<44} state")
  for k, v in derived.items():
    was = recorded.get(k, "(absent)")
    print(f"{k:<24} {was:<44} {v:<44} {'DRIFT' if k in drift else 'ok'}")
  for k in UNVERIFIABLE:
    print(f"{k:<24} {recorded.get(k, '(absent)'):<44} {'-':<44} UNVERIFIABLE (no path from the SRM)")

  block = int(rpc(url, "eth_blockNumber", []), 16)
  section = render_state_section(url, SRM, block)
  doc = DOC.read_text()
  if BEGIN_MARKER in doc and END_MARKER in doc:
    start = doc.index(BEGIN_MARKER)
    end = doc.index(END_MARKER) + len(END_MARKER)
    # Compare from line 5 on: lines 0-4 are the markers, heading and the "generated at block N"
    # provenance line, which changes on every run. Including it would report STALE forever and
    # rewrite the file on every invocation, which trains people to ignore the output.
    state_stale = doc[start:end].split("\n")[5:] != section.split("\n")[5:]
    current = doc[:start] + section + doc[end:]
  else:
    state_stale = True
    current = None  # first run: the operator places the markers, see below

  print()
  if current is None:
    print("live state section: markers not found in DEPLOYED_ADDRESSES.md")
    print("  add these two lines where the section should go, then rerun:")
    print(f"    {BEGIN_MARKER}")
    print(f"    {END_MARKER}")
  else:
    print(f"live state section: {'STALE' if state_stale else 'up to date'} (chain block {block})")

  if not drift and not state_stale:
    print("\nno drift: every derivable key and the generated state section match chain")
    return 0

  if args.write and current is not None and state_stale:
    DOC.write_text(current)
    print(f"regenerated the live state section in {DOC.relative_to(ROOT)}")

  if not drift:
    return 0 if args.write else 1

  print(f"\n{len(drift)} key(s) drifted from chain:")
  for k, (was, now) in drift.items():
    print(f"  {k}: {was} -> {now}")

  if not args.write:
    print("\nreport only. Re-run with --write to apply.")
    return 1

  for k, (_, now) in drift.items():
    recorded[k] = now
  CORE.write_text(json.dumps(recorded, indent=2, sort_keys=True) + "\n")
  print(f"\nwrote {CORE.relative_to(ROOT)}")

  # The markdown mirrors core.json as `- `key`: `0x…`` bullets under "### Core". Rewrite only
  # those exact bullets; prose is left alone for a human to read and fix.
  doc = DOC.read_text()
  start = doc.index("### Core")
  end = doc.index("###", start + 1)
  section = doc[start:end]
  patched = section
  for k, (_, now) in drift.items():
    patched = re.sub(rf"(- `{re.escape(k)}`: `)0x[0-9a-fA-F]{{40}}(`)", rf"\g<1>{now}\g<2>", patched)
  if patched != section:
    DOC.write_text(doc[:start] + patched + doc[end:])
    print(f"wrote {DOC.relative_to(ROOT)} (### Core bullets only)")
  else:
    print(f"{DOC.relative_to(ROOT)}: no matching bullets under ### Core; check it by hand")
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
