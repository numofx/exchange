import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import type { RateProvider } from 'cngn-rate-picker';

import { buildIndexSources, fiatNgnAtParity } from './index-sources.js';
import type { Config } from './config.js';

const signal = new AbortController().signal;
const fixed = (price: number): RateProvider => ({ name: 'textile', getPriceInNgn: async () => ({ price }) });

describe('fiatNgnAtParity', () => {
  it('takes fiat NGN per USDT as cNGN per USDT at redemption parity, unconverted', async () => {
    assert.deepEqual(await fiatNgnAtParity(fixed(1368.83)).read({ signal, fetch }), { source: 'textile', cngnPerUsdt: 1368.83 });
  });
  it('lets a failing venue throw, so the sample goes on without it', async () => {
    const broken: RateProvider = { name: 'bybit-p2p', getPriceInNgn: async () => { throw new Error('HTTP 403'); } };
    await assert.rejects(fiatNgnAtParity(broken).read({ signal, fetch }), /HTTP 403/);
  });
});

describe('buildIndexSources', () => {
  it('is the three fiat venues and nothing that trades cNGN itself', () => {
    const names = buildIndexSources({ QUIDAX_API_URL: 'https://app.quidax.io/api/v1' } as Config).map((s) => s.name);
    assert.deepEqual(names, ['quidax', 'textile', 'bybit-p2p']);
  });
});
