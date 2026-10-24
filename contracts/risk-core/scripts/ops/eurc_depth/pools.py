"""EURC/USDC pools on Base, the JSON-RPC and ABI plumbing the depth reading needs, and the main pool's LP concentration.

No third-party dependency and no `cast`: the ops box has neither forge nor web3, only python3 (as log_cngn_basis.py).

The pools are the ones found on 2026-10-21 by asking each factory for every fee tier / tick spacing it knows (Uniswap v3
and v4 hookless keys, Aerodrome v2 and Slipstream). `other_pools_usdc` in each reading sums USDC in any pool the
factories return that is NOT in POOLS, so depth growing somewhere new is visible rather than silently missed.

LP concentration is read for the main pool (Slipstream tick spacing 50, ~82% of the 2% sell depth on 2026-10-21) from
its gauge: Deposit/Withdraw logs give each staked NFT position's depositor, and NonfungiblePositionManager.positions
gives its liquidity and range. The logs are scanned incrementally into a state file, so only the first reading pays
for the gauge's history. Unstaked positions are not attributed (finding them means walking the position manager's
history across every Slipstream pool); their share of the in-range liquidity is reported as `unattributed`, so the
largest LP's share is a lower bound when that column is large. A reading whose staked liquidity in range does not sum
to the pool's own stakedLiquidity() has missed an event: its LP columns are left empty and `lp_check` says why.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from resolve_cngn_action6 import keccak  # noqa: E402  pure-python keccak, shared by the ops scripts

EURC = "0x60a3e35cc302bfa44cb288bc5a4f316fdb1adb42"
USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
ZERO = "0x" + "0" * 40
MULTICALL3 = "0xca11bde05977b3631167028862be2a173976ca11"

UNI3_FACTORY = "0x33128a8fc17869897dce68ed026d694621f6fdfd"
UNI3_QUOTER = "0x3d4e44eb1374240ce5f1b871ab261cd16335b76a"
UNI4_STATE_VIEW = "0xa3c0c9b65bad0b08107aa264b0f3db444b867a71"
UNI4_QUOTER = "0x0d5e0f971ed27fbff6c2837bf31316121532048d"
AERO_FACTORY = "0x420dd381b31aef6683db6b902084cb0ffece40da"
AERO_ROUTER = "0xcf77a3ba9a5ca399b7c97c74d54e5b1beb874e43"
CL_FACTORY = "0x5e7bb104d84c7cb9b682aac2f3d509f5f406809a"
CL_QUOTER = "0x254cf9e1e6e233aa1ac962cb9b05b2cfeaae15b0"

# (column name, kind, parameter, pool address or v4 pool id)
POOLS = [
  ("slipstream_ts50", "cl", 50, "0xe846373c1a92b167b4e9cd5d8e4d6b1db9e90ec7"),
  ("slipstream_ts1", "cl", 1, "0xc5e51044eb7318950b1afb044fccfb25782c48c1"),
  ("uni3_500", "uni3", 500, "0x7279c08a36333e12c3fc81747963264c100d66fb"),
  ("uni3_3000", "uni3", 3000, "0x03d8219070e54a55a9ce60889ead2ffd18eb6aa9"),
  ("uni4_500", "uni4", (500, 10), "0x64db64264317af2fa1cc5a5deff9900dcf504d426580ab16dc59279b4ade4423"),
  ("aero_volatile", "aero", False, "0xfdf5139b38525627b47538536042a7c8d2686bd9"),
  ("aero_stable", "aero", True, "0xef0d374fe41fc6da7f8ed7c56c10a8f2a4f75313"),
]
MAIN_POOL = POOLS[0][3]
# The main pool's first block with code (binary search on eth_getCode, mainnet.base.org, 2026-10-21). Its gauge cannot
# be older, so a gauge scan never needs to start earlier, and starting here instead is only slower, never wrong.
MAIN_POOL_CREATED_BLOCK = 17_827_297
UNI3_FEES = [100, 500, 3000, 10000]
CL_TICK_SPACINGS = [1, 10, 50, 100, 200, 2000]

DEPOSIT_TOPIC = "0x" + keccak(b"Deposit(address,uint256,uint128)").hex()
WITHDRAW_TOPIC = "0x" + keccak(b"Withdraw(address,uint256,uint128)").hex()


# --- JSON-RPC ----------------------------------------------------------------------------------

class Rpc:
  """eth_call / eth_getLogs over plain JSON-RPC, retrying 429s and transient errors with backoff."""

  def __init__(self, url: str, tries: int = 6):
    self.url, self.tries = url, tries

  def request(self, method: str, params: list):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    last, limited = None, False
    for attempt in range(self.tries):
      req = urllib.request.Request(self.url, data=body, method="POST",
                                   headers={"Content-Type": "application/json", "User-Agent": "numo-eurc-depth/1.0"})
      try:
        with urllib.request.urlopen(req, timeout=60) as resp:
          payload = json.loads(resp.read())
      except urllib.error.HTTPError as error:
        if error.code != 429 and 400 <= error.code < 500:
          raise RpcError(method, {"message": f"HTTP {error.code}"})  # refused (a range too large, say): not transient
        last, limited = error, error.code == 429
        time.sleep(min(2 ** attempt, 30))
        continue
      except (urllib.error.URLError, TimeoutError, ConnectionError) as error:
        last, limited = error, False
        time.sleep(min(2 ** attempt, 30))
        continue
      if "error" in payload:
        raise RpcError(method, payload["error"])
      return payload["result"]
    error = RateLimited if limited else RpcError
    raise error(method, {"message": f"no answer after {self.tries} tries: {last}"})

  def call(self, to: str, data: str, block: int) -> str:
    return self.request("eth_call", [{"to": to, "data": data}, hex(block)])

  def head(self) -> int:
    return int(self.request("eth_blockNumber", []), 16)

  def block_time(self, block: int) -> int:
    return int(self.request("eth_getBlockByNumber", [hex(block), False])["timestamp"], 16)

  def code_at(self, address: str, block: int) -> bool:
    return self.request("eth_getCode", [address, hex(block)]) != "0x"


class RpcError(RuntimeError):
  def __init__(self, method: str, error: dict):
    super().__init__(f"{method}: {str(error.get('message', error))[:200]}")


class RateLimited(RpcError):
  """The endpoint kept answering 429. Not a sign the request was too large: a log scan keeps its span and stops."""


def rpc_from_env() -> Rpc:
  url = os.environ.get("RPC_URL") or os.environ.get("BASE_RPC_URL")
  if not url:
    raise SystemExit("RPC_URL is required (on the box: run-with-ssm-readonly.sh supplies the provider endpoint)")
  return Rpc(url)


# --- ABI: just enough to encode the quoter, router, multicall and getter calls ------------------

def selector(sig: str) -> str:
  return keccak(sig.encode()).hex()[:8]


def _split(types: str) -> list[str]:
  out, depth, cur = [], 0, ""
  for ch in types:
    if ch == "," and depth == 0:
      out.append(cur)
      cur = ""
      continue
    depth += ch == "("
    depth -= ch == ")"
    cur += ch
  return out + ([cur] if cur else [])


def _dynamic(t: str) -> bool:
  if t == "bytes" or t.endswith("[]"):
    return True
  if t.startswith("("):
    return any(_dynamic(x) for x in _split(t[1:-1]))
  return False


def _word(v: int) -> str:
  return (v % (1 << 256)).to_bytes(32, "big").hex()


def encode(types: list[str], values: list) -> str:
  heads, tails, offset = [], [], 32 * len(types)
  for t, v in zip(types, values):
    if _dynamic(t):
      heads.append(_word(offset))
      tail = _encode_one(t, v)
      tails.append(tail)
      offset += len(tail) // 2
    else:
      heads.append(_encode_one(t, v))
  return "".join(heads) + "".join(tails)


def _encode_one(t: str, v) -> str:
  if t.endswith("[]"):
    return _word(len(v)) + encode([t[:-2]] * len(v), list(v))
  if t.startswith("("):
    return encode(_split(t[1:-1]), list(v))
  if t == "bytes":
    raw = bytes.fromhex(v.removeprefix("0x"))
    return _word(len(raw)) + raw.hex().ljust(64 * ((len(raw) + 31) // 32), "0")
  if t == "address":
    return v.lower().removeprefix("0x").rjust(64, "0")
  if t == "bool":
    return _word(1 if v else 0)
  if t == "bytes32":
    return v.removeprefix("0x").rjust(64, "0")
  return _word(int(v))  # uintN / intN, two's complement


def calldata(sig: str, *values) -> str:
  inner = sig[sig.index("(") + 1:-1]
  return "0x" + selector(sig) + encode(_split(inner), list(values))


def words(raw: str) -> list[int]:
  raw = raw.removeprefix("0x")
  return [int(raw[i:i + 64], 16) for i in range(0, len(raw), 64)]


def signed(word: int, bits: int = 256) -> int:
  word &= (1 << bits) - 1
  return word - (1 << bits) if word >> (bits - 1) else word


def address_word(word: int) -> str:
  return "0x" + f"{word:064x}"[-40:]


def multicall(rpc: Rpc, calls: list[tuple[str, str]], block: int, chunk: int = 150) -> list[str | None]:
  """Multicall3.aggregate3 with allowFailure: one eth_call per `chunk` reads. None for a call that reverted."""
  out: list[str | None] = []
  for i in range(0, len(calls), chunk):
    part = calls[i:i + chunk]
    data = calldata("aggregate3((address,bool,bytes)[])", [(to, True, d) for to, d in part])
    raw = rpc.call(MULTICALL3, data, block).removeprefix("0x")
    w = lambda k: int(raw[64 * k: 64 * (k + 1)], 16)  # noqa: E731
    base = w(0) // 32
    n = w(base)
    for j in range(n):
      at = base + 1 + w(base + 1 + j) // 32  # each element is a dynamic (bool, bytes) tuple
      ok = w(at) == 1
      length = w(at + w(at + 1) // 32)
      start = 64 * (at + w(at + 1) // 32 + 1)
      out.append("0x" + raw[start:start + 2 * length] if ok else None)
  return out


# --- balances and pool discovery -----------------------------------------------------------------

def balance(rpc: Rpc, token: str, who: str, block: int) -> int:
  return words(rpc.call(token, calldata("balanceOf(address)", who), block))[0]


def factory_pools(rpc: Rpc, block: int) -> list[str]:
  """Every EURC/USDC pool the v3, Aerodrome v2 and Slipstream factories return (v4 pools have no factory)."""
  calls = [(UNI3_FACTORY, calldata("getPool(address,address,uint24)", EURC, USDC, f)) for f in UNI3_FEES]
  calls += [(AERO_FACTORY, calldata("getPool(address,address,bool)", EURC, USDC, s)) for s in (False, True)]
  calls += [(CL_FACTORY, calldata("getPool(address,address,int24)", EURC, USDC, ts)) for ts in CL_TICK_SPACINGS]
  found = [address_word(words(r)[0]) for r in multicall(rpc, calls, block) if r]
  return [a for a in found if a != ZERO]


def other_pools_usdc(rpc: Rpc, block: int) -> float:
  known = {p[3] for p in POOLS}
  return sum(balance(rpc, USDC, a, block) for a in factory_pools(rpc, block) if a not in known) / 1e6


# --- main pool LP concentration ------------------------------------------------------------------

def _first_block_with_code(rpc: Rpc, address: str, head: int, lo: int = 0) -> int:
  hi = head
  while lo < hi:
    mid = (lo + hi) // 2
    if rpc.code_at(address, mid):
      hi = mid
    else:
      lo = mid + 1
  return lo


def scan_gauge(rpc: Rpc, gauge: str, to_block: int, state: dict, max_span: int = 2_000_000, save=None) -> dict:
  """Bring state["staked"] (tokenId -> depositor) up to `to_block`. Spans adapt: double on success, halve when the
  endpoint refuses the range. `save(state)` runs after every chunk, so an interrupted backfill resumes where it was."""
  if state.get("gauge") != gauge:
    state.clear()
    try:
      start = _first_block_with_code(rpc, gauge, to_block, lo=MAIN_POOL_CREATED_BLOCK)
    except RpcError:  # an endpoint without historical state: scan from the pool's own creation instead
      start = MAIN_POOL_CREATED_BLOCK
    state.update({"gauge": gauge, "from_block": start, "staked": {}})
    state["scanned_to"] = state["from_block"] - 1
  span = state.get("span", 10_000)
  while state["scanned_to"] < to_block:
    start, end = state["scanned_to"] + 1, min(state["scanned_to"] + span, to_block)
    try:
      logs = rpc.request("eth_getLogs", [{"address": gauge, "fromBlock": hex(start), "toBlock": hex(end),
                                          "topics": [[DEPOSIT_TOPIC, WITHDRAW_TOPIC]]}])
    except RateLimited:
      raise
    except RpcError:
      if span <= 500:
        raise
      span //= 2
      state["span"], state["ceiling"] = span, span  # never grow back into a range the endpoint refused
      continue
    for log in sorted(logs, key=lambda x: (int(x["blockNumber"], 16), int(x["logIndex"], 16))):
      token_id = str(int(log["topics"][2], 16))
      if log["topics"][0] == DEPOSIT_TOPIC:
        state["staked"][token_id] = address_word(int(log["topics"][1], 16))
      else:
        state["staked"].pop(token_id, None)
    state["scanned_to"] = end
    span = min(span * 2, max_span, state.get("ceiling", max_span))
    state["span"] = span
    if save:
      save(state)
  return state


def concentration(staked: dict[str, str], positions: dict[str, tuple[int, int, int]], tick: int, pool_liquidity: int,
                  pool_staked: int) -> dict:
  """LP columns from staked positions (tokenId -> (tickLower, tickUpper, liquidity)), checked against the pool."""
  by_lp_any: dict[str, int] = {}
  by_lp_in_range: dict[str, int] = {}
  for token_id, lp in staked.items():
    lower, upper, liq = positions[token_id]
    if liq == 0:
      continue
    by_lp_any[lp] = by_lp_any.get(lp, 0) + liq
    if lower <= tick < upper:
      by_lp_in_range[lp] = by_lp_in_range.get(lp, 0) + liq
  in_range = sum(by_lp_in_range.values())
  if in_range != pool_staked:
    return {"lp_check": f"staked in range {in_range} != pool stakedLiquidity {pool_staked}: missed gauge events"}
  largest_lp, largest = max(by_lp_in_range.items(), key=lambda kv: kv[1]) if by_lp_in_range else ("", 0)
  return {
    "lp_check": "ok",
    "main_pool_staked_lps": len(by_lp_any),
    "main_pool_staked_lps_in_range": len(by_lp_in_range),
    "main_pool_largest_lp": largest_lp,
    "main_pool_largest_lp_share": round(largest / pool_liquidity, 4) if pool_liquidity else "",
    "main_pool_unattributed_share": round((pool_liquidity - pool_staked) / pool_liquidity, 4) if pool_liquidity else "",
  }


def main_pool_lps(rpc: Rpc, block: int, state_path: Path) -> dict:
  pool = MAIN_POOL
  gauge = address_word(words(rpc.call(pool, calldata("gauge()"), block))[0])
  nft = address_word(words(rpc.call(pool, calldata("nft()"), block))[0])
  state = json.loads(state_path.read_text()) if state_path.exists() else {}
  if state.get("scanned_to", -1) > block:
    raise SystemExit(f"state {state_path} is scanned past block {block}: readings go forward only")
  def save(s: dict) -> None:
    tmp = state_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(s))
    tmp.replace(state_path)  # atomic: a reading killed mid-write leaves the last good state
  scan_gauge(rpc, gauge, block, state, save=save)
  save(state)
  tick = signed(words(rpc.call(pool, calldata("slot0()"), block))[1], 24)
  pool_liquidity = words(rpc.call(pool, calldata("liquidity()"), block))[0]
  pool_staked = words(rpc.call(pool, calldata("stakedLiquidity()"), block))[0]
  ids = list(state["staked"])
  raws = multicall(rpc, [(nft, calldata("positions(uint256)", int(i))) for i in ids], block)
  positions = {}
  for token_id, raw in zip(ids, raws):
    w = words(raw) if raw else [0] * 12
    positions[token_id] = (signed(w[5], 24), signed(w[6], 24), w[7])  # tickLower, tickUpper, liquidity
  out = concentration(state["staked"], positions, tick, pool_liquidity, pool_staked)
  if out.get("lp_check") == "ok" and out["main_pool_largest_lp"]:
    lp = out["main_pool_largest_lp"]
    out["_largest_lp_positions"] = [positions[i] for i, who in state["staked"].items() if who == lp and positions[i][2]]
  return out


# --- the main pool without its largest LP --------------------------------------------------------
#
# Depth if the largest LP withdrew: the pool's initialized ticks around the price, with that LP's staked positions taken
# out of liquidityNet (and out of the active liquidity where in range), swapped through locally with Uniswap v3's swap
# math (Slipstream's is the same). The same simulation with nothing removed must agree with the pool's own quoter, or the
# reading reports the mismatch instead of a number: a local swap is only evidence while it reproduces the real one.

Q96 = 1 << 96
MIN_TICK, MAX_TICK = -887272, 887272
SIM_WINDOW_TICKS = 1_000  # ~10% either side: past 2% the marginal test has already failed, so nothing further is needed

_TICK_FACTORS = [
  (0x2, 0xfff97272373d413259a46990580e213a), (0x4, 0xfff2e50f5f656932ef12357cf3c7fdcc),
  (0x8, 0xffe5caca7e10e4e61c3624eaa0941cd0), (0x10, 0xffcb9843d60f6159c9db58835c926644),
  (0x20, 0xff973b41fa98c081472e6896dfb254c0), (0x40, 0xff2ea16466c96a3843ec78b326b52861),
  (0x80, 0xfe5dee046a99a2a811c461f1969c3053), (0x100, 0xfcbe86c7900a88aedcffc83b479aa3a4),
  (0x200, 0xf987a7253ac413176f2b074cf7815e54), (0x400, 0xf3392b0822b70005940c7a398e4b70f3),
  (0x800, 0xe7159475a2c29b7443b29c7fa6e889d9), (0x1000, 0xd097f3bdfd2022b8845ad8f792aa5825),
  (0x2000, 0xa9f746462d870fdf8a65dc1f90e061e5), (0x4000, 0x70d869a156d2a1b890bb3df62baf32f7),
  (0x8000, 0x31be135f97d08fd981231505542fcfa6), (0x10000, 0x9aa508b5b7a84e1c677de54f3e99bc9),
  (0x20000, 0x5d6af8dedb81196699c329225ee604), (0x40000, 0x2216e584f5fa1ea926041bedfe98),
  (0x80000, 0x48a170391f7dc42444e8fa2),
]


def sqrt_ratio_at_tick(tick: int) -> int:
  """TickMath.getSqrtRatioAtTick."""
  a = abs(tick)
  ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if a & 1 else 1 << 128
  for bit, factor in _TICK_FACTORS:
    if a & bit:
      ratio = (ratio * factor) >> 128
  if tick > 0:
    ratio = ((1 << 256) - 1) // ratio
  return (ratio >> 32) + (1 if ratio % (1 << 32) else 0)


def _div_up(a: int, b: int) -> int:
  return -(-a // b)


def _amount0(sa: int, sb: int, liq: int, up: bool) -> int:
  sa, sb = min(sa, sb), max(sa, sb)
  num1, num2 = liq << 96, sb - sa
  return _div_up(_div_up(num1 * num2, sb), sa) if up else num1 * num2 // sb // sa


def _amount1(sa: int, sb: int, liq: int, up: bool) -> int:
  sa, sb = min(sa, sb), max(sa, sb)
  return _div_up(liq * (sb - sa), Q96) if up else liq * (sb - sa) // Q96


def _next_sqrt_from_input(sp: int, liq: int, amount: int, zero_for_one: bool) -> int:
  if zero_for_one:  # SqrtPriceMath.getNextSqrtPriceFromAmount0RoundingUp, adding
    num1, product = liq << 96, amount * sp
    if product < (1 << 256) and num1 + product < (1 << 256):
      return _div_up(num1 * sp, num1 + product)
    return _div_up(num1, num1 // sp + amount)
  return sp + (amount << 96) // liq  # getNextSqrtPriceFromAmount1RoundingDown, adding


def _swap_step(cur: int, target: int, liq: int, remaining: int, fee: int) -> tuple[int, int, int, int]:
  """SwapMath.computeSwapStep, exact input: (next sqrt price, amount in, amount out, fee amount)."""
  zero_for_one = cur >= target
  less_fee = remaining * (10**6 - fee) // 10**6
  amount_in = _amount0(target, cur, liq, True) if zero_for_one else _amount1(cur, target, liq, True)
  nxt = target if less_fee >= amount_in else _next_sqrt_from_input(cur, liq, less_fee, zero_for_one)
  reached = nxt == target
  if zero_for_one:
    amount_in = amount_in if reached else _amount0(nxt, cur, liq, True)
    amount_out = _amount1(nxt, cur, liq, False)
  else:
    amount_in = amount_in if reached else _amount1(cur, nxt, liq, True)
    amount_out = _amount0(cur, nxt, liq, False)
  fee_amount = _div_up(amount_in * fee, 10**6 - fee) if reached else remaining - amount_in
  return nxt, amount_in, amount_out, fee_amount


def cl_swap_out(state: dict, zero_for_one: bool, amount_in: int, liquidity_net: dict[int, int] | None = None,
                liquidity: int | None = None) -> int:
  """Exact-input output of a swap through `state` (cl_state), optionally with other liquidity. Stops at the window's
  edge: output stays flat past it, which the 2% search reads as no more depth."""
  net = state["liquidity_net"] if liquidity_net is None else liquidity_net
  liq = state["liquidity"] if liquidity is None else liquidity
  sp, tick, fee = state["sqrt_price"], state["tick"], state["fee"]
  lo, hi = state["window"]
  initialized = sorted(net)
  remaining, out = amount_in, 0
  while remaining > 0:
    if zero_for_one:
      below = [t for t in initialized if lo <= t <= tick]
      tick_next, edge = (below[-1], False) if below else (lo, True)
    else:
      above = [t for t in initialized if tick < t <= hi]
      tick_next, edge = (above[0], False) if above else (hi, True)
    target = sqrt_ratio_at_tick(tick_next)
    if liq == 0:
      nxt, step_in, step_out, step_fee = target, 0, 0, 0
    else:
      nxt, step_in, step_out, step_fee = _swap_step(sp, target, liq, remaining, fee)
    remaining -= step_in + step_fee
    out += step_out
    sp = nxt
    if sp != target:
      break  # the input ran out inside this range
    if edge:
      break  # past the window: no more output
    liq += -net[tick_next] if zero_for_one else net[tick_next]
    tick = tick_next - 1 if zero_for_one else tick_next
  return out


def cl_state(rpc: Rpc, pool: str, block: int) -> dict:
  """slot0, liquidity, fee and every initialized tick within SIM_WINDOW_TICKS, at `block`."""
  raw = words(rpc.call(pool, calldata("slot0()"), block))
  sqrt_price, tick = raw[0], signed(raw[1], 24)
  spacing = signed(words(rpc.call(pool, calldata("tickSpacing()"), block))[0], 24)
  fee = words(rpc.call(pool, calldata("fee()"), block))[0]
  liquidity = words(rpc.call(pool, calldata("liquidity()"), block))[0]
  lo = (tick - SIM_WINDOW_TICKS) // spacing * spacing
  hi = (tick + SIM_WINDOW_TICKS) // spacing * spacing + spacing
  word_ids = list(range((lo // spacing) >> 8, ((hi // spacing) >> 8) + 1))
  bitmaps = multicall(rpc, [(pool, calldata("tickBitmap(int16)", w)) for w in word_ids], block)
  ticks = []
  for w, raw_word in zip(word_ids, bitmaps):
    bits = words(raw_word)[0] if raw_word else 0
    ticks += [(w * 256 + b) * spacing for b in range(256) if bits >> b & 1]
  ticks = [t for t in ticks if lo <= t <= hi]
  nets = multicall(rpc, [(pool, calldata("ticks(int24)", t)) for t in ticks], block)
  liquidity_net = {t: signed(words(r)[1], 128) for t, r in zip(ticks, nets) if r}
  if len(liquidity_net) != len(ticks):
    raise RpcError("ticks", {"message": "a ticks() read failed"})
  return {"sqrt_price": sqrt_price, "tick": tick, "fee": fee, "liquidity": liquidity, "liquidity_net": liquidity_net,
          "window": (lo, hi)}


def without_positions(state: dict, positions: list[tuple[int, int, int]]) -> tuple[dict[int, int], int]:
  """liquidityNet and active liquidity with `positions` ((tickLower, tickUpper, liquidity)) withdrawn."""
  net, liq = dict(state["liquidity_net"]), state["liquidity"]
  lo, hi = state["window"]
  for lower, upper, amount in positions:
    if lo <= lower <= hi:
      net[lower] = net.get(lower, 0) - amount
    if lo <= upper <= hi:
      net[upper] = net.get(upper, 0) + amount
    if lower <= state["tick"] < upper:
      liq -= amount
  if liq < 0:
    raise ValueError("withdrawing more active liquidity than the pool has")
  return net, liq
