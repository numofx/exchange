/**
 * The forward a dated future (cNGN, or on v2 any base quoted in USDC) is marked to, and the diff its LyraForwardFeed stores.
 *
 * Two contracts, by `version`:
 *  - v1 (src/legacy/v1/FutureAssetV1, USDC-cNGN-<expiry>): prices here are cNGN per USDC at 18dp, the
 *    future's own denomination, unless named `...Usdc` (USDC per cNGN, the index and forward feeds'
 *    denomination). One contract is contractSize USDC. The feed stores the forward as `index + diff` in
 *    USDC per cNGN; pullMark inverts that back. The carry forward is index * (1 + carry * tau).
 *  - v2 (src/assets/FutureAsset, <BASE>-<expiry>: cNGN-30NOV26, and EURC-30NOV26 to come): every price is
 *    USDC per unit of the base, the feeds' units and the future's, so nothing is inverted and pullMark
 *    reads index + diff as is. One contract is contractSize of the base, worth contractSize * price USDC.
 *    The carry forward is index / (1 + carry * tau), carry being the base's rate over USD's: positive for
 *    cNGN (a forward discount, a negative diff), negative for EURC (a forward premium).
 *
 * The target is the futures book's mid when both sides have depth, otherwise the carry forward.
 * Each side's price is its depth-weighted average over minDepthUsdc of notional, so a dust order at
 * the top of the book cannot set the mark; a side that cannot fill that much counts as no book. Then
 * it is clamped, in order:
 *   1. to the carry forward +/- maxBasisBps, so a thin book cannot drag the mark away from carry;
 *   2. inside the contract's index band (markIndexBand), less a safety margin;
 *   3. inside the contract's per-mark move limit from the last mark, less the same margin.
 * If 2 and 3 cannot both hold (the band has narrowed past where one move can reach), nothing is
 * published: the contract would refuse it, and it needs a person.
 */
import type { RestingOrder } from './mark-targets.js';

export const ONE = 10n ** 18n;
const YEAR = 365n * 24n * 60n * 60n;

/** Which FutureAsset is marked: v1 (inverse, a USDC contract) or v2 (linear, a contract of the base). */
export type FutureVersion = 'v1' | 'v2';

export type ForwardInputs = {
  /** Defaults to v1. */
  version?: FutureVersion;
  /** The index feed: USDC per cNGN (v2: per unit of the base). */
  indexUsdc: bigint;
  /** Annual carry of the base's rate over USD's, 18dp. Signed on v2 (EUR's is negative). */
  carry: bigint;
  secondsToExpiry: bigint;
  /** The futures book: prices in the future's units (v1 cNGN per USDC, v2 USDC per cNGN), amounts in contracts (18dp). */
  orders: RestingOrder[];
  /** FutureAsset.contractSize, 18dp: USDC per contract on v1, the base per contract on v2. */
  contractSize: bigint;
  /** Notional (USDC, 18dp) each side must be able to fill for the book to set the mark. */
  minDepthUsdc: bigint;
  lastMark: bigint;
  /** FutureAsset.markIndexBand(expiry) now: a fraction of the index, 18dp. */
  band: bigint;
  /** FutureAsset.maxMarkDeviation: a fraction of the last mark, 18dp. 0 disables. */
  maxMove: bigint;
  maxBasisBps: bigint;
  safetyBps: bigint;
};

export type ForwardTarget =
  | { ok: true; mark: bigint; diffUsdc: bigint; basis: 'book-mid' | 'carry'; clampedBy: string[] }
  | { ok: false; reason: string };

export function invert(price: bigint): bigint {
  if (price <= 0n) throw new Error('price must be positive');
  return ONE * ONE / price;
}

/** index * (1 + carry * tau), cNGN per USDC: v1's forward. */
export function carryForward(index: bigint, carry: bigint, secondsToExpiry: bigint): bigint {
  if (secondsToExpiry <= 0n) return index;
  return index + (index * carry / ONE) * secondsToExpiry / YEAR;
}

/**
 * index / (1 + carry * tau), USDC per unit of the base: v2's forward. A positive carry (cNGN) is a
 * forward discount, a negative one (EURC) a premium. The same arithmetic as
 * deploy-margin-engine-v2.s.sol's fairForward, which the initial mark was checked against.
 */
export function discountForward(index: bigint, carry: bigint, secondsToExpiry: bigint): bigint {
  if (secondsToExpiry <= 0n) return index;
  return index * ONE / (ONE + carry * secondsToExpiry / YEAR);
}

/**
 * Volume-weighted price to fill `minDepthUsdc` of notional walking one side best-first, or null if
 * the side cannot fill it. On v1 a contract's notional is its USDC size, whatever the price; on v2
 * it is contractSize of the base at the order's price.
 */
export function depthPrice(side: RestingOrder[], contractSize: bigint, minDepthUsdc: bigint, version: FutureVersion = 'v1'): bigint | null {
  if (contractSize <= 0n) throw new Error('contract size must be positive');
  if (version === 'v2') return depthPriceLinear(side, contractSize, minDepthUsdc);
  // contracts (18dp) needed, rounded up
  let needed = (minDepthUsdc * ONE + contractSize - 1n) / contractSize;
  if (needed === 0n) needed = 1n;
  let taken = 0n;
  let weighted = 0n;
  for (const order of side) {
    if (taken >= needed) break;
    const take = order.remaining < needed - taken ? order.remaining : needed - taken;
    taken += take;
    weighted += order.price * take;
  }
  if (taken < needed) return null;
  return weighted / taken;
}

/** depthPrice for v2: each level's contracts are worth contractSize * price USDC, so the count needed varies by level. */
function depthPriceLinear(side: RestingOrder[], contractSize: bigint, minDepthUsdc: bigint): bigint | null {
  let short = minDepthUsdc > 0n ? minDepthUsdc : 1n; // notional (USDC, 18dp) still to fill
  let taken = 0n;
  let weighted = 0n;
  for (const order of side) {
    if (short <= 0n) break;
    const perContract = contractSize * order.price / ONE; // USDC one whole contract is worth here
    if (perContract <= 0n) continue;
    // contracts (18dp) to cover what is short, rounded up
    const want = (short * ONE + perContract - 1n) / perContract;
    const take = order.remaining < want ? order.remaining : want;
    taken += take;
    weighted += order.price * take;
    short -= take * perContract / ONE;
  }
  if (short > 0n || taken === 0n) return null;
  return weighted / taken;
}

/** Mid of the depth-weighted bid and ask, or null without depth on both sides or with a crossed book. */
export function bookMid(orders: RestingOrder[], contractSize: bigint, minDepthUsdc: bigint, version: FutureVersion = 'v1'): bigint | null {
  const live = orders.filter((o) => o.remaining > 0n);
  const bids = live.filter((o) => o.side === 'buy').sort((a, b) => (a.price > b.price ? -1 : a.price < b.price ? 1 : 0));
  const asks = live.filter((o) => o.side === 'sell').sort((a, b) => (a.price < b.price ? -1 : a.price > b.price ? 1 : 0));
  if (bids.length === 0 || asks.length === 0 || bids[0].price >= asks[0].price) return null;
  const bid = depthPrice(bids, contractSize, minDepthUsdc, version);
  const ask = depthPrice(asks, contractSize, minDepthUsdc, version);
  if (bid === null || ask === null) return null;
  return (bid + ask) / 2n;
}

function within(price: bigint, reference: bigint, fraction: bigint): boolean {
  const diff = price > reference ? price - reference : reference - price;
  return diff * ONE <= reference * fraction;
}

function clampTo(price: bigint, reference: bigint, fraction: bigint): bigint {
  const cap = reference * fraction / ONE;
  if (price > reference + cap) return reference + cap;
  if (price < reference - cap) return reference - cap;
  return price;
}

export function computeForwardTarget(inputs: ForwardInputs): ForwardTarget {
  const v2 = inputs.version === 'v2';
  // the index and the forward in the future's own units
  const index = v2 ? inputs.indexUsdc : invert(inputs.indexUsdc);
  const fair = v2
    ? discountForward(index, inputs.carry, inputs.secondsToExpiry)
    : carryForward(index, inputs.carry, inputs.secondsToExpiry);
  const mid = bookMid(inputs.orders, inputs.contractSize, inputs.minDepthUsdc, inputs.version);
  const clampedBy: string[] = [];
  const keep = (10_000n - inputs.safetyBps) * ONE / 10_000n; // the share of each limit we use

  let mark = mid ?? fair;
  const basis = mid === null ? 'carry' : 'book-mid';

  const toBasis = clampTo(mark, fair, inputs.maxBasisBps * ONE / 10_000n);
  if (toBasis !== mark) clampedBy.push('basis');
  mark = toBasis;

  const bandUsed = inputs.band * keep / ONE;
  const toBand = clampTo(mark, index, bandUsed);
  if (toBand !== mark) clampedBy.push('index-band');
  mark = toBand;

  if (inputs.maxMove > 0n) {
    const toMove = clampTo(mark, inputs.lastMark, inputs.maxMove * keep / ONE);
    if (toMove !== mark) clampedBy.push('move-limit');
    mark = toMove;
  }

  // The contract checks both limits; publishing what one of them refuses only burns gas.
  if (!within(mark, index, inputs.band)) {
    return { ok: false, reason: `no mark within one move of ${inputs.lastMark} is inside the index band around ${index}` };
  }
  if (inputs.maxMove > 0n && !within(mark, inputs.lastMark, inputs.maxMove)) {
    return { ok: false, reason: `mark ${mark} is outside the move limit from ${inputs.lastMark}` };
  }

  // v1's pullMark inverts index + diff; v2's reads it as is
  const diffUsdc = (v2 ? mark : invert(mark)) - inputs.indexUsdc;
  const limit = 2n ** 95n;
  if (diffUsdc < -limit || diffUsdc >= limit) return { ok: false, reason: `diff ${diffUsdc} does not fit int96` };
  return { ok: true, mark, diffUsdc, basis, clampedBy };
}
