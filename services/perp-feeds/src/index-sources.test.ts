import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import type { RateProvider } from 'cngn-rate-picker';

import { fiatNgn, hyperfxReading, quidaxVolumeGate, type HyperfxRules, type HyperfxSnapshot } from './index-sources.js';

const signal = new AbortController().signal;
const E18 = 10n ** 18n;
const fixed = (price: number): RateProvider => ({ name: 'textile', getPriceInNgn: async () => ({ price }) });

describe('fiatNgn', () => {
  it('converts fiat NGN per USDT to cNGN per USDT through the measured peg', async () => {
    const peg = { ok: true as const, ngnPerCngn: 1.002, ageMs: 0, samples: 5, guardTripped: false, deviationBps: 20 };
    const reading = await fiatNgn(fixed(1374)).read({ signal, fetch, peg });
    assert.ok(Math.abs(reading.cngnPerUsdt - 1374 / 1.002) < 1e-9);
    assert.equal(reading.counts, true);
  });
  it('is absent, never converted at an assumed 1:1, when the peg is unavailable', async () => {
    await assert.rejects(fiatNgn(fixed(1374)).read({ signal, fetch, peg: { ok: false, reason: 'peg unavailable' } }), /no cNGN conversion/);
  });
});

describe('quidaxVolumeGate', () => {
  const peg = { ok: false as const, reason: 'unused' };
  const ticker = (vol: string) => (async () => new Response(JSON.stringify({ data: { usdtcngn: { ticker: { vol } } } }))) as unknown as typeof fetch;
  it('counts usdtcngn only at $1k of 24h volume', async () => {
    const gate = quidaxVolumeGate('https://q', 'usdtcngn', 1_000);
    assert.equal((await gate({ signal, fetch: ticker('29.7'), peg })).counts, false);
    assert.equal((await gate({ signal, fetch: ticker('1500'), peg })).counts, true);
  });
});

describe('hyperfxReading', () => {
  const rules: HyperfxRules = {
    url: 'https://h', book: 'USDC-cNGN', fillChain: 'EVM-8453', minSizeUsd: 1_000, minSolvers: 2,
    maxSpreadBps: 50, windowMs: 15 * 60_000, minSnapshots: 2, maxLiveDeviationBps: 50,
  };
  const now = Date.parse('2026-09-30T02:00:00Z');
  const snap = (minutesAgo: number, mid: number, over: Partial<HyperfxSnapshot> = {}): HyperfxSnapshot => ({
    recordedAt: new Date(now - minutesAgo * 60_000).toISOString(),
    mid: (BigInt(Math.round(mid * 1e6)) * 10n ** 12n).toString(),
    spread: (1n * E18).toString(), // 1 cNGN on ~1372: ~7bps
    bidSolvers: 2, askSolvers: 2, bidDepthBase: (5_000n * E18).toString(), askDepthBase: (5_000n * E18).toString(),
    ...over,
  });
  const live = (bid: number, ask: number, solvers = 2) => ({
    bid: { rate: (BigInt(Math.round(bid * 1e6)) * 10n ** 12n).toString(), solverCount: solvers },
    ask: { rate: (BigInt(Math.round(ask * 1e6)) * 10n ** 12n).toString(), solverCount: solvers },
  });

  it('is a TWAP of qualifying snapshots, checked against the live minSize quotes', () => {
    const reading = hyperfxReading([snap(14, 1370), snap(9, 1372), snap(4, 1374)], live(1373.5, 1374.5), now, rules);
    assert.ok(reading.ok);
    // 1370 for 5 min, 1372 for 5, 1374 for the last 4: the live mid is not the reading.
    assert.ok(reading.ok && Math.abs(reading.cngnPerUsdc - (1370 * 5 + 1372 * 5 + 1374 * 4) / 14) < 1e-6);
  });
  it('refuses today\'s book: one solver per side', () => {
    const oneSolver = [snap(14, 1372, { bidSolvers: 1, askSolvers: 1 }), snap(9, 1372, { bidSolvers: 1, askSolvers: 1 })];
    const reading = hyperfxReading(oneSolver, live(1372, 1372, 1), now, rules);
    assert.match(!reading.ok ? reading.reason : '', /solvers bid 1 \/ ask 1/);
  });
  it('refuses dust: a side under minSize cannot set the price', () => {
    const dust = [snap(14, 1372, { askDepthBase: (406n * E18).toString() }), snap(9, 1372, { askDepthBase: (30n * E18).toString() })];
    assert.match((hyperfxReading(dust, live(1372, 1372.1), now, rules) as { reason: string }).reason, /depth bid \$5000 \/ ask \$30/);
  });
  it('refuses an empty side, a wide spread, too few solvers live, or a live mid far from the TWAP', () => {
    assert.equal(hyperfxReading([snap(14, 1372, { mid: null }), snap(9, 1372, { mid: null })], live(1372, 1372.1), now, rules).ok, false);
    assert.match((hyperfxReading([snap(14, 1372, { spread: (20n * E18).toString() }), snap(9, 1372, { spread: (20n * E18).toString() })], live(1372, 1372.1), now, rules) as { reason: string }).reason, /spread/);
    assert.match((hyperfxReading([snap(14, 1372), snap(9, 1372)], live(1372, 1372.1, 1), now, rules) as { reason: string }).reason, /live solvers/);
    assert.match((hyperfxReading([snap(14, 1372), snap(9, 1372)], live(1390, 1390.5), now, rules) as { reason: string }).reason, /from the window TWAP/);
    assert.match((hyperfxReading([snap(14, 1372), snap(9, 1372)], { bid: null, ask: null }, now, rules) as { reason: string }).reason, /no live/);
  });
});
