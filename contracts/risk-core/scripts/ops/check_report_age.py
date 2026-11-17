#!/usr/bin/env python3
"""Pages when the Data Streams reports a StreamsIndexAdapter holds go stale.

The EURC index (EurcIndexFeed) reverts once its reports are over 60 s old, and with it every mark, every fixing sample
and, under self-priced quoting (spec C3), the OnchainBook's quotes. The keeper posts every 20 s; a dry relayer, a stopped
keeper or a Data Streams outage shows here first. On 2026-11-16 the v3 relayer ran dry and the index was stale for 3 h
18 m before anyone looked.

Each run reads the adapter's two stored reports (latest(baseFeedId), latest(quoteFeedId)) against the head block's
time. Over REPORT_MAX_AGE_S (default 120 s, ~5 missed posts), or unreadable, counts as bad; it pages only on the second
bad run in a row (REPORT_BAD_RUNS, default 2), so one refused RPC call does not wake anyone.

Env (or ~/.numo-feeds.env):
  ADAPTER             the StreamsIndexAdapter (default: EURC-30NOV26's, 0x9E9a…FfEB)
  RPC_URL             read RPC; RPC_SSM names a keyed endpoint in SSM to use instead (read once, never printed)
  REPORT_MAX_AGE_S    default 120
  REPORT_BAD_RUNS     default 2
  REPORT_STATE_FILE   default /var/tmp/numo-report-age.state

Exit codes, read by run-with-heartbeat.sh: 0 fresh (or the first bad run), 3 stale or unreadable for REPORT_BAD_RUNS
runs (the check goes down: a HIGH-priority page).

  python3 scripts/ops/check_report_age.py --self-test
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_ADAPTER = "0x9E9aB6ee5ccf0b050Eba0b64Ce9429334D49FfEB"
SEL_BASE_FEED = "0x99b447af"   # StreamsIndexAdapter.baseFeedId()
SEL_QUOTE_FEED = "0x05cdccbf"  # StreamsIndexAdapter.quoteFeedId()
SEL_LATEST = "0x79feb107"      # StreamsIndexAdapter.latest(bytes32)
RETRIES_429 = 3


def load_env_file(path: Path) -> None:
  if not path.exists():
    return
  for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
      continue
    key, value = line.split("=", 1)
    os.environ.setdefault(key.strip().removeprefix("export ").strip(), value.strip())


def rpc(url: str, method: str, params: list, _open=urllib.request.urlopen, _sleep=time.sleep):
  body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
  req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json", "User-Agent": "numo-report-age/1"})
  for attempt in range(RETRIES_429 + 1):
    try:
      with _open(req, timeout=15) as resp:
        out = json.loads(resp.read())
      break
    except urllib.error.HTTPError as exc:
      if exc.code != 429 or attempt == RETRIES_429:
        raise
      _sleep(2 ** attempt)
  if "error" in out:
    raise RuntimeError(out["error"])
  return out["result"]


def resolve_rpc() -> str:
  name = os.environ.get("RPC_SSM", "").strip()
  if name:
    try:
      return subprocess.run(
        ["aws", "ssm", "get-parameter", "--name", name, "--with-decryption", "--query", "Parameter.Value", "--output",
         "text", "--region", os.environ.get("AWS_REGION", "us-east-1")],
        capture_output=True, text=True, timeout=20, check=True).stdout.strip()
    except Exception as exc:  # noqa: BLE001
      print(f"RPC_SSM {name} unreadable ({type(exc).__name__}); using RPC_URL")
  return os.environ.get("RPC_URL", "https://mainnet.base.org")


def report_ages(url: str, adapter: str, _rpc=None) -> dict[str, int]:
  """Each stored report's age in seconds against the head block's timestamp."""
  call = _rpc or rpc
  head = int(call(url, "eth_getBlockByNumber", ["latest", False])["timestamp"], 16)
  ages = {}
  for name, sel in (("base", SEL_BASE_FEED), ("quote", SEL_QUOTE_FEED)):
    feed = call(url, "eth_call", [{"to": adapter, "data": sel}, "latest"])
    out = call(url, "eth_call", [{"to": adapter, "data": SEL_LATEST + feed[2:].rjust(64, "0")}, "latest"])
    words = out[2:]
    observed = int(words[64:128], 16)
    if observed == 0:
      raise RuntimeError(f"{name} feed has no stored report")
    ages[name] = head - observed
  return ages


def decide(bad: bool, previous_bad_runs: int, needed: int) -> tuple[int, int]:
  """(exit code, bad runs so far): page (3) only once `needed` bad runs are in a row."""
  if not bad:
    return 0, 0
  runs = previous_bad_runs + 1
  return (3 if runs >= needed else 0), runs


def main() -> int:
  load_env_file(Path.home() / ".numo-feeds.env")
  adapter = os.environ.get("ADAPTER", DEFAULT_ADAPTER)
  max_age = int(os.environ.get("REPORT_MAX_AGE_S", "120"))
  needed = int(os.environ.get("REPORT_BAD_RUNS", "2"))
  state = Path(os.environ.get("REPORT_STATE_FILE", "/var/tmp/numo-report-age.state"))
  previous = int(state.read_text().strip() or 0) if state.exists() else 0

  try:
    ages = report_ages(resolve_rpc(), adapter)
    stale = {k: v for k, v in ages.items() if v > max_age}
    bad, detail = bool(stale), ", ".join(f"{k} {v}s" for k, v in ages.items())
  except Exception as exc:  # noqa: BLE001
    bad, detail = True, f"unreadable: {str(exc)[:160]}"
  code, runs = decide(bad, previous, needed)
  state.write_text(str(runs))
  if not bad:
    print(f"ok: adapter {adapter} reports {detail} old (limit {max_age}s)")
  elif code == 0:
    print(f"bad run {runs} of {needed}: adapter {adapter} {detail} (limit {max_age}s); not paging yet")
  else:
    print(f"NUMO INDEX REPORTS STALE: adapter {adapter} {detail} (limit {max_age}s) for {runs} runs. The EURC index "
          "reverts past 60 s: marks, fixing samples and self-priced quoting stop. Check the keeper "
          "(numo-future-feeds-v3@eurc-30nov26) and its relayer's gas.")
  return code


def self_test() -> int:
  import io
  # selectors: name and signature agree (and, via abi_selectors, name a compiled function where out/ exists)
  pinned = {"baseFeedId()": SEL_BASE_FEED, "quoteFeedId()": SEL_QUOTE_FEED, "latest(bytes32)": SEL_LATEST}
  try:
    for sig, sel in pinned.items():
      got = subprocess.run(["cast", "sig", sig], capture_output=True, text=True, check=True).stdout.strip()
      assert got == sel, f"{sig}: {got} != pinned {sel}"
  except FileNotFoundError:
    print("cast not installed: selector check skipped (CI runs it)")
  try:
    from abi_selectors import assert_script
    assert_script(__file__)
  except ImportError:
    pass

  # decide: one bad run does not page; two do; a good run resets
  assert decide(False, 5, 2) == (0, 0)
  assert decide(True, 0, 2) == (0, 1), "the first bad run waits"
  assert decide(True, 1, 2) == (3, 2), "the second pages"
  assert decide(True, 2, 2) == (3, 3), "and it keeps paging while bad"

  # report_ages against a scripted chain: head 1000, base observed 990, quote observed 850
  def fake(url, method, params):
    if method == "eth_getBlockByNumber":
      return {"timestamp": hex(1000)}
    data = params[0]["data"]
    if data == SEL_BASE_FEED:
      return "0x" + "aa" * 32
    if data == SEL_QUOTE_FEED:
      return "0x" + "bb" * 32
    observed = 990 if data.endswith("aa" * 32) else 850
    return "0x" + format(10**18, "064x") + format(observed, "064x")
  assert report_ages("x", "0xadapter", _rpc=fake) == {"base": 10, "quote": 150}

  # a 429 is retried, anything else is not
  def opener(script):
    def _open(req, timeout):
      code = script.pop(0)
      if code != 200:
        raise urllib.error.HTTPError(req.full_url, code, "x", {}, io.BytesIO(b""))
      return io.BytesIO(b'{"jsonrpc":"2.0","id":1,"result":"0x1"}')
    return _open
  assert rpc("http://x", "m", [], _open=opener([429, 200]), _sleep=lambda s: None) == "0x1"
  try:
    rpc("http://x", "m", [], _open=opener([500, 200]), _sleep=lambda s: None)
    raise AssertionError("a 500 is not retried")
  except urllib.error.HTTPError:
    pass
  print("self-test ok: selectors, paging on the second bad run, report ages, 429 retry")
  return 0


if __name__ == "__main__":
  try:
    sys.exit(self_test() if "--self-test" in sys.argv[1:] else main())
  except Exception as exc:  # noqa: BLE001
    print(f"report age check FAILED to run: {exc}", file=sys.stderr)
    sys.exit(2)
