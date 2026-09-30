import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { averageFill, clamp, computeMarkTargets, toSpotDiff, type RestingOrder } from './mark-targets.js';
import { needsUpdate } from './mark-publisher.js';

const E18 = 10n ** 18n;
const INDEX = 720_000_000_000_000n; // 0.00072 USDC per cNGN
const rules = { maxBasisBps: 200n, impactNotional: 1_000n * E18 };

/** A resting order at `price` (18dp USDC/cNGN) worth `usd` of notional. */
function order(side: 'buy' | 'sell', price: bigint, usd: bigint): RestingOrder {
  return { side, price, remaining: (usd * E18 * E18) / price };
}

describe('computeMarkTargets', () => {
  it('anchors everything to the index when the book is empty', () => {
    const targets = computeMarkTargets(INDEX, [], rules);
    assert.equal(targets.mark, INDEX);
    assert.equal(targets.impactAsk, INDEX);
    assert.equal(targets.impactBid, INDEX);
    assert.deepEqual(targets.basis, { mark: 'index', impactAsk: 'index', impactBid: 'index' });
  });

  it('marks to the book mid and prices impacts off real depth', () => {
    const bid = (INDEX * 9_990n) / 10_000n;
    const ask = (INDEX * 10_010n) / 10_000n;
    const targets = computeMarkTargets(INDEX, [order('buy', bid, 5_000n), order('sell', ask, 5_000n)], rules);
    assert.equal(targets.mark, (bid + ask) / 2n);
    assert.ok(targets.impactAsk >= ask - 1n && targets.impactAsk <= ask);
    assert.ok(targets.impactBid >= bid - 1n && targets.impactBid <= bid);
    assert.equal(targets.basis.impactAsk, 'depth');
  });

  it('reads a side too thin for the impact notional as the index, not as its one order', () => {
    // $50 of asks 3% up would otherwise set a 3% premium and a funding rate against every long.
    const targets = computeMarkTargets(INDEX, [order('sell', (INDEX * 103n) / 100n, 50n)], rules);
    assert.equal(targets.impactAsk, INDEX);
    assert.equal(targets.basis.impactAsk, 'index');
    assert.equal(targets.mark, INDEX, 'one-sided book has no mid');
  });

  it('clamps a mid far from the index to the maximum basis', () => {
    const targets = computeMarkTargets(
      INDEX,
      [order('buy', (INDEX * 110n) / 100n, 5_000n), order('sell', (INDEX * 112n) / 100n, 5_000n)],
      rules,
    );
    assert.equal(targets.mark, (INDEX * 10_200n) / 10_000n);
  });

  it('ignores a crossed book entirely', () => {
    const targets = computeMarkTargets(
      INDEX,
      [order('buy', (INDEX * 101n) / 100n, 5_000n), order('sell', (INDEX * 99n) / 100n, 5_000n)],
      rules,
    );
    assert.equal(targets.mark, INDEX);
    assert.equal(targets.impactAsk, INDEX);
    assert.equal(targets.impactBid, INDEX);
  });

  it('never publishes an impact ask below the impact bid', () => {
    // Both sides clamp to the same edge of the band: the chain would revert funding on ask < bid.
    const targets = computeMarkTargets(
      INDEX,
      [order('buy', (INDEX * 130n) / 100n, 5_000n), order('sell', (INDEX * 140n) / 100n, 5_000n)],
      rules,
    );
    assert.ok(targets.impactAsk >= targets.impactBid);
  });
});

describe('averageFill', () => {
  it('walks levels until the notional is filled', () => {
    const levels = [order('sell', 100n * E18, 500n), order('sell', 200n * E18, 1_000n)];
    // $500 buys 5 at 100, the next $500 buys 2.5 at 200: 1000 / 7.5
    assert.equal(averageFill(levels, 1_000n * E18), (1_000n * E18 * E18) / (75n * E18 / 10n));
  });

  it('returns null when the side cannot fill it', () => {
    assert.equal(averageFill([order('sell', 100n * E18, 999n)], 1_000n * E18), null);
  });
});

describe('clamp and toSpotDiff', () => {
  it('holds a price inside index ± basis', () => {
    assert.equal(clamp(INDEX * 2n, INDEX, 200n), (INDEX * 10_200n) / 10_000n);
    assert.equal(clamp(INDEX / 2n, INDEX, 200n), (INDEX * 9_800n) / 10_000n);
    assert.equal(clamp(INDEX, INDEX, 200n), INDEX);
  });

  it('refuses a diff that does not fit int96', () => {
    assert.throws(() => toSpotDiff(2n ** 96n, 0n));
    assert.equal(toSpotDiff(INDEX + 5n, INDEX), 5n);
  });
});

describe('needsUpdate', () => {
  const now = 10_000n;

  it('publishes an unreadable feed', () => {
    assert.equal(needsUpdate(null, INDEX, now, 10n, 420n), true);
  });

  it('republishes an unchanged value before it goes stale', () => {
    assert.equal(needsUpdate({ result: INDEX, updatedAt: now - 420n }, INDEX, now, 10n, 420n), true);
    assert.equal(needsUpdate({ result: INDEX, updatedAt: now - 60n }, INDEX, now, 10n, 420n), false);
  });

  it('publishes a move past the threshold', () => {
    assert.equal(needsUpdate({ result: INDEX, updatedAt: now - 60n }, (INDEX * 10_011n) / 10_000n, now, 10n, 420n), true);
    assert.equal(needsUpdate({ result: INDEX, updatedAt: now - 60n }, (INDEX * 10_005n) / 10_000n, now, 10n, 420n), false);
  });
});
