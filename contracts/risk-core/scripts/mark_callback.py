#!/usr/bin/env python3
"""MPCVault Client Signer callback — the function/parameter guardrail.

The client signer POSTs the pending request here before signing (a raw `SigningRequest`
protobuf, Content-Type application/octet-stream) and expects HTTP 200 = approve /
4xx = reject (plain-text body) within 5s. We approve ONLY setMarkPrice to the future with
in-bounds params; everything else (setSettlementPrice, any other call) is rejected. Fail-closed.

We do NOT decode the protobuf. Instead we pull the request UUID out of the body and fetch the
transaction via the REST `getSigningRequestDetails` endpoint, which returns {to, input, value}
(+ evmInputDataDecode) as JSON — then validate that with the same `check()` used everywhere.
Only the UUID comes from the protobuf (a verbatim string, regex-extractable). Proto ref if a
real decode is ever wanted: github.com/mpcvault/mpcvaultapis.

MPCVault sends NO auth on the callback (per docs) — protect port 8799 by network isolation:
do NOT open it in the security group; only the client-signer container reaches it via
host.docker.internal. `check()` also bounds any request to setMarkPrice-to-future regardless.

Env (via run-with-ssm-mark.sh):
  RPC_URL, MPCVAULT_TOKEN, MPCVAULT_VAULT, CALLBACK_PORT (default 8799)

REHEARSAL-VERIFY: the getSigningRequestDetails response nesting and the `input` encoding
(hex vs base64) are confirmed against a live call during rehearsal. Parsing is defensive and
fails closed; prove one setMarkPrice on a throwaway series before enabling the signer/keeper.
"""

from __future__ import annotations

import base64
import os
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mark_keeper import MPCVAULT_BASE, artifact, get_series, get_spot, http_post, load_env_file, run  # noqa: E402

SETMARKPRICE_SELECTOR = "0x272e3661"  # setMarkPrice(uint96,uint64,uint256)
DEVIATION_CAP_BPS = 500     # must stay within the on-chain 5% wall vs the last mark
SANITY_VS_SPOT_BPS = 1000   # ...and within 10% of live spot (catches ratchet drift)
MARKTIME_PAST_SEC = 300
MARKTIME_FUTURE_SEC = 120

UUID_RE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def normalize_input(s: str) -> str:
  """Return 0x-hex calldata whether MPCVault gives us hex (0x/bare) or base64."""
  s = (s or "").strip()
  if s.startswith(("0x", "0X")):
    return "0x" + s[2:].lower()
  try:  # bare hex?
    int(s, 16)
    if len(s) % 2 == 0:
      return "0x" + s.lower()
  except ValueError:
    pass
  try:  # base64?
    return "0x" + base64.b64decode(s).hex()
  except Exception:
    return s  # let check() reject it


def resolve_tx(token: str, uuids: list[str], vault_uuid: str) -> dict | None:
  """Look up each candidate UUID via getSigningRequestDetails; return the EVM custom tx of the
  first that resolves to one. The vault UUID (if it appears in the body) is skipped."""
  seen = set()
  for u in uuids:
    lu = u.lower()
    if lu in seen or lu == (vault_uuid or "").lower():
      continue
    seen.add(lu)
    try:
      resp = http_post(MPCVAULT_BASE + "getSigningRequestDetails", token, {"uuid": u})
    except Exception:
      continue
    sr = resp.get("signingRequest") or (resp.get("data") or {}).get("signingRequest") or {}
    custom = sr.get("evmSendCustom") or {}
    if custom.get("to"):
      return {
        "to": custom["to"],
        "input": normalize_input(custom.get("input") or ""),
        "value": str(custom.get("value", "0")),
        "uuid": u,
      }
  return None


def check(tx: dict, rpc: str, future: str, feed: str, sub_id: str) -> tuple[bool, str]:
  to = (tx.get("to") or "").lower()
  data = (tx.get("input") or "").lower()
  value = str(tx.get("value", "0")).lower()

  if to != future.lower():
    return False, f"to {to} != future"
  if value not in ("0", "0x0", ""):
    return False, f"nonzero value {value}"
  if not data.startswith(SETMARKPRICE_SELECTOR):
    return False, f"selector {data[:10]} != setMarkPrice"

  decoded = run(["cast", "calldata-decode", "setMarkPrice(uint96,uint64,uint256)", data])
  parts = [p.strip().split()[0] for p in decoded.splitlines() if p.strip()]
  if len(parts) != 3:
    return False, f"decode arity {len(parts)}"
  got_sub, mark_time, mark = int(parts[0]), int(parts[1]), int(parts[2])

  if str(got_sub) != str(sub_id):
    return False, f"subId {got_sub} != {sub_id}"

  series = get_series(rpc, future, sub_id)
  if series["settlementPriceSet"]:
    return False, "series already settled"
  last = series["markPrice"]
  dev_bps = abs(mark - last) * 10_000 // last if last else 10_000
  if dev_bps > DEVIATION_CAP_BPS:
    return False, f"deviation {dev_bps}bps > {DEVIATION_CAP_BPS} vs last mark"

  spot = get_spot(rpc, feed)  # raises if stale -> caller rejects
  spot_bps = abs(mark - spot) * 10_000 // spot if spot else 10_000
  if spot_bps > SANITY_VS_SPOT_BPS:
    return False, f"mark {spot_bps}bps off spot > {SANITY_VS_SPOT_BPS}"

  now = int(time.time())
  if mark_time <= series["lastMarkTime"]:
    return False, "markTime not increasing"
  if not (now - MARKTIME_PAST_SEC <= mark_time <= now + MARKTIME_FUTURE_SEC):
    return False, f"markTime {mark_time} not fresh (now {now})"
  if mark_time > series["expiry"]:
    return False, "markTime past expiry"

  return True, f"ok: {last}->{mark} ({dev_bps}bps, spot {spot})"


def make_handler(rpc, token, vault_uuid, future, feed, sub_id):
  class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
      pass

    def _respond(self, approved: bool, reason: str):
      # MPCVault contract: HTTP 200 = approve, 4xx = reject; body is plain text.
      self.send_response(200 if approved else 403)
      self.send_header("Content-Type", "text/plain")
      self.end_headers()
      self.wfile.write(b"approved" if approved else b"rejected")
      print(f"{time.strftime('%H:%M:%S')} {'APPROVE' if approved else 'REJECT '} {reason}", file=sys.stderr)

    def do_POST(self):
      try:
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0)
        uuids = UUID_RE.findall(raw.decode("latin-1", errors="ignore"))
        if not uuids:
          return self._respond(False, "no uuid in callback body")
        tx = resolve_tx(token, uuids, vault_uuid)
        if not tx:
          return self._respond(False, "could not resolve a signing-request tx from body uuids")
        ok, reason = check(tx, rpc, future, feed, sub_id)
        self._respond(ok, reason)
      except Exception as exc:  # fail closed
        self._respond(False, f"exception: {exc}")

  return Handler


def main() -> int:
  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc = os.environ.get("RPC_URL") or "https://mainnet.base.org"
  token = os.environ.get("MPCVAULT_TOKEN", "")
  vault_uuid = os.environ.get("MPCVAULT_VAULT", "")
  port = int(os.environ.get("CALLBACK_PORT", "8799"))
  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  future, feed, sub_id = fut["future"], fut["spotFeed"], str(fut["subId"])
  if not token:
    print("WARNING: MPCVAULT_TOKEN unset — cannot fetch signing-request details; will reject all", file=sys.stderr)
  print(f"callback listening :{port} | future {future} | subId {sub_id}", file=sys.stderr)
  HTTPServer(("0.0.0.0", port), make_handler(rpc, token, vault_uuid, future, feed, sub_id)).serve_forever()
  return 0


if __name__ == "__main__":
  sys.exit(main())
