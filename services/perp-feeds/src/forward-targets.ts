/**
 * The forward a USDC/cNGN future is marked to, and the diff its LyraForwardFeed stores.
 *
 * Prices here are cNGN per USDC at 18dp, the future's own denomination, unless named `...Usdc`
 * (USDC per cNGN, the index and forward feeds' denomination). The feed stores the forward as
 * `index + diff` in USDC per cNGN; FutureAsset.pullMark inverts that back.
 *
 * The target is the futures book's mid when both sides have depth, otherwise the carry forward
 * index * (1 + carry * tau). Each side's price is its depth-weighted average over minDepthUsdc of
 * notional, so a dust order at the top of the book cannot set the mark; a side that cannot fill that
 * much counts as no book. Then it is clamped, in order:
 *   1. to the carry forward +/- maxBasisBps, so a thin book cannot drag the mark away from carry;
 *   2. inside the contract's index band (markIndexBand), less a safety margin;
 *   3. inside the contract's per-mark move limit from the last mark, less the same margin.
 * If 2 and 3 cannot both hold (the band has narrowed past where one move can reach), nothing is
 * published: the contract would refuse it, and it needs a person.
 */
import type { RestingOrder } from './mark-targets.js';

export const ONE = 10n ** 18n;
const YEAR = 365n * 24n * 60n * 60n;

export type ForwardInputs = {
  /** The index feed: USDC per cNGN. */
  indexUsdc: bigint;
  /** Annual NGN-over-USD carry, 18dp. */
  carry: bigint;
  secondsToExpiry: bigint;
  /** The futures book: prices in cNGN per USDC, amounts in contracts (18dp). */
  orders: RestingOrder[];
  /** USDC per contract (18dp), FutureAsset.contractSize. */
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

/** index * (1 + carry * tau), cNGN per USDC. */
export function carryForward(index: bigint, carry: bigint, secondsToExpiry: bigint): bigint {
  if (secondsToExpiry <= 0n) return index;
  return index + (index * carry / ONE) * secondsToExpiry / YEAR;
}

/**
 * Volume-weighted price to fill `minDepthUsdc` of notional walking one side best-first, or null if
 * the side cannot fill it. A contract's notional is its USDC size, whatever the price.
 */
export function depthPrice(side: RestingOrder[], contractSize: bigint, minDepthUsdc: bigint): bigint | null {
  if (contractSize <= 0n) throw new Error('contract size must be positive');
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

/** Mid of the depth-weighted bid and ask, or null without depth on both sides or with a crossed book. */
export function bookMid(orders: RestingOrder[], contractSize: bigint, minDepthUsdc: bigint): bigint | null {
  const live = orders.filter((o) => o.remaining > 0n);
  const bids = live.filter((o) => o.side === 'buy').sort((a, b) => (a.price > b.price ? -1 : a.price < b.price ? 1 : 0));
  const asks = live.filter((o) => o.side === 'sell').sort((a, b) => (a.price < b.price ? -1 : a.price > b.price ? 1 : 0));
  if (bids.length === 0 || asks.length === 0 || bids[0].price >= asks[0].price) return null;
  const bid = depthPrice(bids, contractSize, minDepthUsdc);
  const ask = depthPrice(asks, contractSize, minDepthUsdc);
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
  const index = invert(inputs.indexUsdc);
  const fair = carryForward(index, inputs.carry, inputs.secondsToExpiry);
  const mid = bookMid(inputs.orders, inputs.contractSize, inputs.minDepthUsdc);
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

  const diffUsdc = invert(mark) - inputs.indexUsdc;
  const limit = 2n ** 95n;
  if (diffUsdc < -limit || diffUsdc >= limit) return { ok: false, reason: `diff ${diffUsdc} does not fit int96` };
  return { ok: true, mark, diffUsdc, basis, clampedBy };
}
