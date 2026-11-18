import assert from 'node:assert/strict';
import { test } from 'node:test';

import { handler, refresh, type State } from './main.js';
import { reading } from './rate.js';

const NOW = 1_795_041_200_000;

test('1447.08 NGN per USDC is 0.000691 USD per cNGN, in 18 dp', () => {
  const r = reading({ rate: 1447.08, provider: 'textile', sources: [{ provider: 'textile', price: 1447.08 }] }, NOW);
  assert.equal(r.usd_per_base_e18, '691046797689140');
  assert.equal(r.observed_at, 1_795_041_200);
  assert.deepEqual(r.sources, [{ provider: 'textile', ngn_per_usdc: 1447.08 }]);
});

test('an implausible rate is refused, not served', () => {
  for (const rate of [0, 1.447, 14470, Number.NaN, Infinity]) {
    assert.throws(() => reading({ rate, provider: 'x' }, NOW), /outside/);
  }
});

test('503 before the first reading and once it is older than the max age; 200 in between', async () => {
  const state: State = {};
  let now = NOW;
  const route = handler(state, 300, () => now);
  assert.equal(route('/usd-per-cngn').status, 503);
  await refresh(state, { getStablecoinToNgn: async () => ({ rate: 1447.08, provider: 'textile' }) }, () => now);
  assert.equal(route('/usd-per-cngn').status, 200);
  now += 301_000;
  assert.equal(route('/usd-per-cngn').status, 503, 'stale');
  assert.equal(route('/healthz').status, 200);
  assert.equal(route('/other').status, 404);
});

test('a failing picker keeps the last reading and records the error, so it ages out to 503', async () => {
  const state: State = {};
  let now = NOW;
  const route = handler(state, 300, () => now);
  await refresh(state, { getStablecoinToNgn: async () => ({ rate: 1447.08, provider: 'textile' }) }, () => now);
  now += 200_000;
  await refresh(state, { getStablecoinToNgn: async () => { throw new Error('All 2 provider(s) failed'); } }, () => now);
  assert.equal(route('/usd-per-cngn').status, 200, 'still inside the max age');
  now += 150_000;
  const r = route('/usd-per-cngn');
  assert.equal(r.status, 503);
  assert.match(JSON.stringify(r.body), /All 2 provider/);
});

test('the body is what the book maker parses', async () => {
  const state: State = {};
  await refresh(state, { getStablecoinToNgn: async () => ({ rate: 1447.08, provider: 'textile' }) }, () => NOW);
  const body = handler(state, 300, () => NOW)('/usd-per-cngn').body as Record<string, unknown>;
  assert.equal(typeof body.usd_per_base_e18, 'string');
  assert.match(body.usd_per_base_e18 as string, /^[0-9]+$/);
  assert.equal(typeof body.observed_at, 'number');
});
