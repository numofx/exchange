import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { bookMid, carryForward, computeForwardTarget, depthPrice, discountForward, invert, ONE, type ForwardInputs } from './forward-targets.js';
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
    contractSize: 1_000n * ONE,
    minDepthUsdc: 1_000n * ONE, // one contract
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

const SIZE = 1_000n * ONE; // USDC per contract
const ONE_CONTRACT = 1_000n * ONE; // of notional
const sized = (side: 'buy' | 'sell', price: bigint, contracts: bigint): RestingOrder => ({ side, price, remaining: contracts });

describe('book mid', () => {
  it('is the mid of the best bid and ask when each fills the depth', () => {
    assert.equal(
      bookMid([order('buy', 1450n * ONE), order('buy', 1440n * ONE), order('sell', 1460n * ONE)], SIZE, ONE_CONTRACT),
      1455n * ONE,
    );
  });
  it('is null one-sided, crossed, or empty', () => {
    assert.equal(bookMid([order('buy', 1450n * ONE)], SIZE, ONE_CONTRACT), null);
    assert.equal(bookMid([order('buy', 1460n * ONE), order('sell', 1450n * ONE)], SIZE, ONE_CONTRACT), null);
    assert.equal(bookMid([], SIZE, ONE_CONTRACT), null);
  });
  it('ignores a book with dust at the top and no depth behind it', () => {
    const dust = ONE / 1000n; // a thousandth of a contract each side
    assert.equal(bookMid([sized('buy', 1450n * ONE, dust), sized('sell', 1460n * ONE, dust)], SIZE, 2n * ONE_CONTRACT), null);
  });
  it('weights each side by depth, so a dust order at the top cannot move it', () => {
    const book = [
      sized('buy', 1459n * ONE, ONE / 1000n), // dust bid just under the ask
      sized('buy', 1440n * ONE, 5n * ONE),
      sized('sell', 1460n * ONE, 5n * ONE),
    ];
    const mid = bookMid(book, SIZE, 2n * ONE_CONTRACT)!;
    // bid: 0.001 at 1459 + 1.999 at 1440 over 2 contracts
    const bid = (1459n * ONE * (ONE / 1000n) + 1440n * ONE * (2n * ONE - ONE / 1000n)) / (2n * ONE);
    assert.equal(mid, (bid + 1460n * ONE) / 2n);
    assert.ok(mid < 1450n * ONE + ONE / 100n, 'the dust bid barely moves it: 1450.0095, not the 1459.5 its price would give');
  });
  it('fills a side across several orders', () => {
    assert.equal(depthPrice([sized('sell', 1460n * ONE, ONE), sized('sell', 1470n * ONE, ONE)], SIZE, 2n * ONE_CONTRACT), 1465n * ONE);
    assert.equal(depthPrice([sized('sell', 1460n * ONE, ONE)], SIZE, 2n * ONE_CONTRACT), null);
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

// v2: every price is USDC per unit of the base, as the feeds hold it; one contract is contractSize of the base.
const CNGN_INDEX = 724_089_970_981_047n; // 0.000724 USDC per cNGN, the live index on 2026-10-27
const CNGN_SIZE = 1_000_000n * ONE; // cNGN per contract, cNGN-30NOV26's
const EURC_INDEX = 1_162_500_000_000_000_000n; // 1.1625 USDC per EURC
const EURC_SIZE = 1_000n * ONE; // EURC per contract

function v2(overrides: Partial<ForwardInputs> = {}): ForwardInputs {
  return inputs({
    version: 'v2',
    indexUsdc: CNGN_INDEX,
    carry: (118n * ONE) / 1000n, // 11.8%, cNGN-30NOV26's
    contractSize: CNGN_SIZE,
    minDepthUsdc: 2_000n * ONE,
    lastMark: CNGN_INDEX,
    ...overrides,
  });
}

describe('v2 discount forward', () => {
  it('is index / (1 + carry * tau): a positive carry is a discount, a negative one a premium', () => {
    // 20% over a fifth of a year: index / 1.04
    assert.equal(discountForward(1_040n * ONE, (2n * ONE) / 10n, 73n * DAY), 1_000n * ONE);
    // -2% over a fifth of a year: index / 0.996
    assert.equal(discountForward(996n * ONE, -(2n * ONE) / 100n, 73n * DAY), 1_000n * ONE);
    assert.equal(discountForward(CNGN_INDEX, (2n * ONE) / 10n, 0n), CNGN_INDEX);
  });
});

describe('v2 depth', () => {
  it('values a contract at contractSize x price: fewer contracts fill the depth as the price rises', () => {
    // one contract of 1,000,000 cNGN at 0.0008 is $800: $2,000 needs 2.5 contracts
    const price = (8n * ONE) / 10_000n;
    assert.equal(depthPrice([sized('sell', price, (25n * ONE) / 10n)], CNGN_SIZE, 2_000n * ONE, 'v2'), price);
    assert.equal(depthPrice([sized('sell', price, (24n * ONE) / 10n)], CNGN_SIZE, 2_000n * ONE, 'v2'), null);
    // the same 2.4 contracts, read as v1's USDC contracts ($1,000 each), would fill it
    assert.equal(depthPrice([sized('sell', price, (24n * ONE) / 10n)], 1_000n * ONE, 2_000n * ONE), price);
  });
  it('fills across levels, weighting each by the contracts taken', () => {
    // EURC: 1,000 EURC at 1.16 is $1,160, at 1.17 $1,170. $2,000: all of 1 at 1.16, then 840/1170 of one at 1.17
    const a = (116n * ONE) / 100n;
    const b = (117n * ONE) / 100n;
    const second = (840n * ONE * ONE + 1_170n * ONE - 1n) / (1_170n * ONE);
    const expected = (a * ONE + b * second) / (ONE + second);
    assert.equal(depthPrice([sized('sell', a, ONE), sized('sell', b, 5n * ONE)], EURC_SIZE, 2_000n * ONE, 'v2'), expected);
  });
});

describe('v2 forward target', () => {
  it('marks cNGN to index / (1 + carry * tau), and the diff is the mark less the index: negative, nothing inverted', () => {
    const fair = discountForward(CNGN_INDEX, (118n * ONE) / 1000n, 73n * DAY);
    const t = computeForwardTarget(v2({ lastMark: fair }));
    assert.ok(t.ok);
    assert.equal(t.basis, 'carry');
    assert.equal(t.mark, fair);
    assert.equal(t.diffUsdc, fair - CNGN_INDEX);
    assert.ok(t.diffUsdc < 0n, 'cNGN at a forward discount');
    // the contract's pullMark reads index + diff as is
    assert.equal(CNGN_INDEX + t.diffUsdc, t.mark);
  });

  it('marks EURC, at a negative carry, to a premium: a positive diff', () => {
    const carry = -(15n * ONE) / 1000n; // -1.5%
    const fair = discountForward(EURC_INDEX, carry, 73n * DAY);
    const t = computeForwardTarget(v2({ indexUsdc: EURC_INDEX, carry, contractSize: EURC_SIZE, lastMark: fair }));
    assert.ok(t.ok);
    assert.equal(t.mark, fair);
    assert.ok(fair > EURC_INDEX && t.diffUsdc > 0n, 'EUR at a forward premium');
    assert.equal(EURC_INDEX + t.diffUsdc, t.mark);
  });

  it('marks to a v2 book mid when each side fills the depth in USDC', () => {
    const fair = discountForward(CNGN_INDEX, (118n * ONE) / 1000n, 73n * DAY);
    const tick = fair / 1000n;
    // 3 contracts a side, ~$2,150 of notional at these prices
    const book = [sized('buy', fair - tick, 3n * ONE), sized('sell', fair + 3n * tick, 3n * ONE)];
    const t = computeForwardTarget(v2({ lastMark: fair, orders: book }));
    assert.ok(t.ok);
    assert.equal(t.basis, 'book-mid');
    assert.equal(t.mark, fair + tick);
    // the same book with 2 contracts a side is ~$1,430 a side: below the depth, so carry
    const thin = computeForwardTarget(v2({ lastMark: fair, orders: [sized('buy', fair - tick, 2n * ONE), sized('sell', fair + 3n * tick, 2n * ONE)] }));
    assert.ok(thin.ok);
    assert.equal(thin.basis, 'carry');
  });

  it('bands and move-limits around the index and last mark in USDC per cNGN', () => {
    // a 45% carry over a fifth of a year is a 9% discount, against a 5% band
    const t = computeForwardTarget(v2({ carry: (45n * ONE) / 100n, band: ONE / 20n, lastMark: (CNGN_INDEX * 95n) / 100n }));
    assert.ok(t.ok);
    assert.equal(t.mark, CNGN_INDEX - (CNGN_INDEX * ((ONE / 20n) * 9950n / 10_000n)) / ONE);
    assert.ok(t.clampedBy.includes('index-band'));
  });
});
