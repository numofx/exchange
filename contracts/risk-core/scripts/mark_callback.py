#!/usr/bin/env python3
"""MPCVault Client Signer callback — the function/parameter guardrail.

The MPCVault Client Signer calls this endpoint before signing. We approve ONLY if the
pending transaction is a setMarkPrice call to the deliverable FX future with in-bounds
parameters; everything else (including setSettlementPrice and any other owner op) is
rejected. This is the layer the MPCVault address-allowlist policy can't enforce (it sees
address+amount, not the function).

FAIL-CLOSED: any parse failure, unknown field shape, or check miss -> reject.

Env (or ~/.numo-mark-keeper.env):
  RPC_URL             Base RPC (to re-read the live mark/spot for bounds)
  CALLBACK_SECRET     shared secret; the request must present it (header or body)
  CALLBACK_PORT       listen port (default 8799)

NOTE: MPCVault's exact callback request/response JSON shape is confirmed during the
pre-launch rehearsal. Parsing is defensive and this defaults to REJECT on anything it
cannot positively verify, so an unconfirmed shape fails safe (no signature) rather than
open. Adjust `extract_tx` / `approve_response` to the observed contract at rehearsal.
"""

from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from mark_keeper import artifact, get_series, get_spot, load_env_file, run  # noqa: E402

# setMarkPrice(uint96,uint64,uint256) selector (verified: cast sig).
SETMARKPRICE_SELECTOR = "0x272e3661"
DEVIATION_CAP_BPS = 500     # must stay within the on-chain 5% wall vs the last mark
SANITY_VS_SPOT_BPS = 1000   # ...and within 10% of live spot (catches ratchet drift)
MARKTIME_PAST_SEC = 300     # markTime not older than this
MARKTIME_FUTURE_SEC = 120   # ...nor further ahead than this


def extract_tx(body: dict) -> dict:
  """Pull {to, input, value} out of the callback body, tolerant of nesting. Returns {}
  if the expected fields aren't present (-> caller rejects)."""
  candidates = [body, body.get("transaction", {}), body.get("evmSendCustom", {}),
                body.get("signingRequest", {}), body.get("request", {})]
  for c in candidates:
    if isinstance(c, dict) and c.get("to") and (c.get("input") or c.get("data")):
      return {"to": c["to"], "input": c.get("input") or c.get("data"), "value": str(c.get("value", "0"))}
  return {}


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


def make_handler(rpc, future, feed, sub_id, secret):
  class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet default logging; we print our own
      pass

    def _respond(self, approved: bool, reason: str):
      # Response shape confirmed at rehearsal; default is an explicit approve flag.
      payload = json.dumps({"approved": approved, "reason": reason}).encode()
      self.send_response(200 if approved else 403)
      self.send_header("Content-Type", "application/json")
      self.end_headers()
      self.wfile.write(payload)
      print(f"{time.strftime('%H:%M:%S')} {'APPROVE' if approved else 'REJECT '} {reason}",
            file=sys.stderr)

    def do_POST(self):
      try:
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        body = json.loads(raw or b"{}")
        if secret and self.headers.get("x-callback-secret") != secret and body.get("secret") != secret:
          return self._respond(False, "bad secret")
        tx = extract_tx(body)
        if not tx:
          return self._respond(False, "no tx in callback body")
        ok, reason = check(tx, rpc, future, feed, sub_id)
        self._respond(ok, reason)
      except Exception as exc:  # fail closed
        self._respond(False, f"exception: {exc}")

  return Handler


def main() -> int:
  load_env_file(Path.home() / ".numo-mark-keeper.env")
  rpc = os.environ.get("RPC_URL") or "https://mainnet.base.org"
  secret = os.environ.get("CALLBACK_SECRET", "")
  port = int(os.environ.get("CALLBACK_PORT", "8799"))
  fut = artifact("CNGN_SEP16_2026_FUTURE.json")
  future, feed, sub_id = fut["future"], fut["spotFeed"], str(fut["subId"])
  if not secret:
    print("WARNING: CALLBACK_SECRET unset — callback is unauthenticated (set it + IP allowlist)", file=sys.stderr)
  print(f"callback listening :{port} | future {future} | subId {sub_id}", file=sys.stderr)
  HTTPServer(("0.0.0.0", port), make_handler(rpc, future, feed, sub_id, secret)).serve_forever()
  return 0


if __name__ == "__main__":
  sys.exit(main())
