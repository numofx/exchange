import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { aggregateSample, checkJump, toUsdPerNgn, windowTwap } from './index-aggregation.js';
const rules = { minSources: 3, maxSourceDeviationBps: 150 };
describe('aggregateSample', () => {
    it('takes the median of agreeing sources', () => {
        const result = aggregateSample([
            { source: 'quidax', cngnPerUsdt: 1374 },
            { source: 'textile', cngnPerUsdt: 1371.87 },
            { source: 'bybit-p2p', cngnPerUsdt: 1380 },
        ], rules);
        assert.deepEqual(result, { ok: true, median: 1374, sources: ['quidax', 'textile', 'bybit-p2p'] });
    });
    it('averages the middle pair for an even count', () => {
        const result = aggregateSample([
            { source: 'a', cngnPerUsdt: 1370 },
            { source: 'b', cngnPerUsdt: 1372 },
            { source: 'c', cngnPerUsdt: 1374 },
            { source: 'd', cngnPerUsdt: 1376 },
        ], rules);
        assert.equal(result.ok && result.median, 1373);
    });
    it('refuses too few sources', () => {
        const result = aggregateSample([
            { source: 'quidax', cngnPerUsdt: 1374 },
            { source: 'textile', cngnPerUsdt: 1371.87 },
        ], rules);
        assert.equal(result.ok, false);
        assert.match(!result.ok ? result.reason : '', /only 2 of 3 required sources/);
    });
    it('does not count a zero or non-finite quote as a source', () => {
        const result = aggregateSample([
            { source: 'a', cngnPerUsdt: 1374 },
            { source: 'b', cngnPerUsdt: 0 },
            { source: 'c', cngnPerUsdt: Number.NaN },
        ], rules);
        assert.equal(result.ok, false);
    });
    it('refuses the whole sample when one source disagrees, rather than dropping it', () => {
        // A median would shrug off one outlier; the point of the check is that disagreement itself is
        // the signal (one venue broken, or the market moving faster than the sources can agree).
        const result = aggregateSample([
            { source: 'quidax', cngnPerUsdt: 1374 },
            { source: 'textile', cngnPerUsdt: 1372 },
            { source: 'bybit-p2p', cngnPerUsdt: 1450 },
        ], rules);
        assert.equal(result.ok, false);
        assert.match(!result.ok ? result.reason : '', /bybit-p2p=1450/);
    });
});
describe('windowTwap', () => {
    const now = 1_000_000_000;
    const window = { windowMs: 15 * 60_000, minSamples: 10, maxNewestAgeMs: 180_000 };
    it('refuses a window without enough samples', () => {
        const samples = Array.from({ length: 9 }, (_, i) => ({ price: 1374, at: now - i * 60_000 }));
        const result = windowTwap(samples, now, window);
        assert.equal(result.ok, false);
    });
    it('ignores samples older than the window', () => {
        const fresh = Array.from({ length: 10 }, (_, i) => ({ price: 1374, at: now - i * 60_000 }));
        const stale = Array.from({ length: 10 }, (_, i) => ({ price: 9999, at: now - 20 * 60_000 - i * 60_000 }));
        const result = windowTwap([...stale, ...fresh], now, window);
        assert.deepEqual(result, { ok: true, cngnPerUsdt: 1374, samples: 10 });
    });
    it('refuses to republish when every recent sample was refused, though older ones fill the window', () => {
        // 12 accepted samples from 15..4 minutes ago, nothing accepted since: the window is "full" but
        // no source has confirmed the price for 4 minutes.
        const samples = Array.from({ length: 12 }, (_, i) => ({ price: 1374, at: now - (15 - i) * 60_000 + 30_000 }));
        const result = windowTwap(samples, now, window);
        assert.equal(result.ok, false);
        assert.match(!result.ok ? result.reason : '', /newest accepted sample/);
    });
    it('weights each sample by how long it stood', () => {
        const samples = [
            ...Array.from({ length: 9 }, (_, i) => ({ price: 1370, at: now - (11 - i) * 60_000 })),
            { price: 1400, at: now - 2 * 60_000 },
        ];
        const result = windowTwap(samples, now, window);
        // 1370 stood 9 minutes, 1400 stood the last 2: (1370*9 + 1400*2) / 11
        assert.ok(result.ok);
        assert.ok(Math.abs((result.ok ? result.cngnPerUsdt : 0) - (1370 * 9 + 1400 * 2) / 11) < 1e-9);
    });
});
describe('checkJump', () => {
    const last = 727802037845705n; // ~1374 cNGN/USDC
    const rules = { maxJumpBps: 300 };
    it('lets a move inside the band through', () => {
        assert.deepEqual(checkJump((last * 102n) / 100n, last, rules), { ok: true });
    });
    it('refuses a move past the band, either direction', () => {
        assert.equal(checkJump((last * 104n) / 100n, last, rules).ok, false);
        assert.equal(checkJump((last * 96n) / 100n, last, rules).ok, false);
    });
    it('has nothing to compare against before the first publish', () => {
        assert.deepEqual(checkJump(last, null, rules), { ok: true });
    });
});
describe('toUsdPerNgn', () => {
    it('inverts NGN per USDT into USDC per cNGN at 18dp', () => {
        // 1 / 1374 = 0.000727802037845705...
        const value = toUsdPerNgn(1374);
        assert.equal(value, 727802037845705n);
    });
    it('refuses a rate it cannot invert', () => {
        assert.throws(() => toUsdPerNgn(0));
        assert.throws(() => toUsdPerNgn(Number.POSITIVE_INFINITY));
    });
});
