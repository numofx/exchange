import assert from 'node:assert/strict';
import { test } from 'node:test';
import { priceFromSnapshot, type Snapshot } from './quote.js';

const snapshot = (over: Partial<Snapshot> = {}): Snapshot => ({
  commitment: '0xabc',
  standardAmount: 1_000_000_000n,
  medianPrice: 1_368_315_500_000n,
  lowestPrice: 1_368_315_500_000n,
  highestPrice: 1_368_315_500_000n,
  bidCount: 2,
  snapshotTime: new Date('2026-09-18T00:00:00Z'),
  ...over,
});
const now = new Date('2026-09-18T00:05:00Z');

test('prices on gross input, matching what fills on chain', () => {
  // The 300 USDC order settled on Base paid out exactly 410,494.65 cNGN: gross * median / standard.
  // Deducting the 5bps protocol fee first (as the SDK does) would give 410,281.4 and under-quote.
  const q = priceFromSnapshot(snapshot(), 300_000_000n, 1800, now);
  assert.equal(q.amountOut, 410_494_650_000n);
});

test('refuses a snapshot past the age limit', () => {
  // The guard that the SDK does not have: its V1 feed served a 40-day-old price because the only
  // check was that the timestamp parsed.
  const stale = snapshot({ snapshotTime: new Date('2026-08-08T12:03:24Z') });
  assert.throws(() => priceFromSnapshot(stale, 20_000_000n, 1800, now), /refusing to trade on it/);
});

test('accepts a snapshot inside the age limit', () => {
  const q = priceFromSnapshot(snapshot(), 20_000_000n, 1800, now);
  assert.equal(q.amountOut, 27_366_310_000n);
  assert.ok(q.ageSeconds > 0 && q.ageSeconds < 1800);
});

test('rejects a snapshot with no bids behind it', () => {
  assert.throws(() => priceFromSnapshot(snapshot({ bidCount: 0 }), 20_000_000n, 1800, now), /no bids/);
});

test('rejects a non-positive median price', () => {
  assert.throws(() => priceFromSnapshot(snapshot({ medianPrice: 0n }), 20_000_000n, 1800, now), /medianPrice/);
});

test('rejects an amount that rounds down to zero output', () => {
  assert.throws(() => priceFromSnapshot(snapshot({ medianPrice: 1n, standardAmount: 10n ** 18n }), 1n, 1800, now), /zero output/);
});
