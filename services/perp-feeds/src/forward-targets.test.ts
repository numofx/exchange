import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { bookMid, carryForward, computeForwardTarget, invert, ONE, type ForwardInputs } from './forward-targets.js';
import type { RestingOrder } from './mark-targets.js';

// The feed holds USDC per cNGN; the index in cNGN per USDC is its inverse, as the publisher computes it
// (1400.0000000000004: 1/1400 does not round-trip exactly at 18dp).
const INDEX_USDC = invert(1400n * ONE);
const INDEX = invert(INDEX_USDC);
const DAY = 86_400n;

function inputs(overrides: Partial<ForwardInputs> = {}): ForwardInputs {
  return {
    indexUsdc: INDEX_USDC,
    carry: (2n * ONE) / 10n, // 20% a year
    secondsToExpiry: 73n * DAY, // a fifth of a year: carry forward is index * 1.04
    orders: [],
    lastMark: INDEX,
    band: ONE / 10n, // 10%
    maxMove: ONE / 20n, // 5%
    maxBasisBps: 300n,
    safetyBps: 50n,
    ...overrides,
  };
}

const order = (side: 'buy' | 'sell', price: bigint): RestingOrder => ({ side, price, remaining: ONE });

describe('carry forward', () => {
  it('is index * (1 + carry * tau)', () => {
    assert.equal(carryForward(INDEX, (2n * ONE) / 10n, 73n * DAY), (INDEX * 104n) / 100n);
  });
  it('is the index at and after expiry', () => {
    assert.equal(carryForward(INDEX, (2n * ONE) / 10n, 0n), INDEX);
    assert.equal(carryForward(INDEX, (2n * ONE) / 10n, -1n), INDEX);
  });
});

describe('book mid', () => {
  it('is the mid of the best bid and ask', () => {
    assert.equal(bookMid([order('buy', 1450n * ONE), order('buy', 1440n * ONE), order('sell', 1460n * ONE)]), 1455n * ONE);
  });
  it('is null one-sided, crossed, or empty', () => {
    assert.equal(bookMid([order('buy', 1450n * ONE)]), null);
    assert.equal(bookMid([order('buy', 1460n * ONE), order('sell', 1450n * ONE)]), null);
    assert.equal(bookMid([]), null);
  });
});

describe('forward target', () => {
  it('marks to carry without a book', () => {
    const t = computeForwardTarget(inputs({ lastMark: (INDEX * 104n) / 100n }));
    assert.ok(t.ok);
    assert.equal(t.basis, 'carry');
    assert.equal(t.mark, (INDEX * 104n) / 100n);
    assert.deepEqual(t.clampedBy, []);
  });

  it('marks to the book mid when there is one', () => {
    const fair = (INDEX * 104n) / 100n;
    const t = computeForwardTarget(inputs({ lastMark: fair, orders: [order('buy', fair - ONE), order('sell', fair + 3n * ONE)] }));
    assert.ok(t.ok);
    assert.equal(t.basis, 'book-mid');
    assert.equal(t.mark, fair + ONE);
  });

  it('holds a thin book to the carry forward +/- the max basis', () => {
    const fair = (INDEX * 104n) / 100n;
    const far = (fair * 110n) / 100n;
    const t = computeForwardTarget(inputs({ lastMark: fair, orders: [order('buy', far - ONE), order('sell', far + ONE)] }));
    assert.ok(t.ok);
    assert.equal(t.mark, fair + (fair * 300n) / 10_000n);
    assert.deepEqual(t.clampedBy, ['basis']);
  });

  it('stays inside the index band, less the safety margin', () => {
    // a 9% carry forward against a 5% band
    const t = computeForwardTarget(inputs({ carry: (45n * ONE) / 100n, band: ONE / 20n, lastMark: (INDEX * 105n) / 100n }));
    assert.ok(t.ok);
    assert.equal(t.mark, INDEX + (INDEX * ((ONE / 20n) * 9950n / 10_000n)) / ONE);
    assert.ok(t.clampedBy.includes('index-band'));
  });

  it('stays inside the move limit from the last mark, less the safety margin', () => {
    const t = computeForwardTarget(inputs({ lastMark: (INDEX * 99n) / 100n }));
    assert.ok(t.ok);
    // carry forward is 1.04 x index, 5.05% from the last mark: held to 4.975%
    assert.equal(t.mark, (INDEX * 99n) / 100n + ((INDEX * 99n) / 100n * ((ONE / 20n) * 9950n / 10_000n)) / ONE);
    assert.ok(t.clampedBy.includes('move-limit'));
  });

  it('refuses when no single move reaches the band', () => {
    // last mark 8% over the index, band narrowed to 1%: one 5% move cannot get inside it
    const t = computeForwardTarget(inputs({ lastMark: (INDEX * 108n) / 100n, band: ONE / 100n, secondsToExpiry: DAY }));
    assert.equal(t.ok, false);
  });

  it('gives the diff the feed stores: forward minus index, in USDC per cNGN', () => {
    const t = computeForwardTarget(inputs({ lastMark: (INDEX * 104n) / 100n }));
    assert.ok(t.ok);
    assert.equal(t.diffUsdc, invert(t.mark) - INDEX_USDC);
    assert.ok(t.diffUsdc < 0n, 'a cNGN-per-USDC premium is a USDC-per-cNGN discount');
    // and the contract's inverse of index + diff recovers the mark. A USDC-per-cNGN price (~7e14 at
    // 18dp) carries ~15 significant digits, so the round trip is exact to ~1e-15, not to the wei.
    const recovered = invert(INDEX_USDC + t.diffUsdc);
    const error = recovered > t.mark ? recovered - t.mark : t.mark - recovered;
    assert.ok(error * 10n ** 12n <= t.mark, `${recovered} vs ${t.mark}: more than 1e-12 apart`);
  });
});
