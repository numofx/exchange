import assert from 'node:assert/strict';
import { test } from 'node:test';

import { parseDayaBook, fetchDayaBook, type DayaBook } from './daya.js';
import { handler, refresh, refreshDaya, type State } from './main.js';

// Daya's response at 2026-11-21T18:48:40Z, depth=5, verbatim.
const RAW = {
  success: true,
  message: 'Orderbook retrieved successfully',
  data: {
    symbol: 'USD-NGN',
    market_id: '1f6c75ec-4724-45df-9f5c-04497f72c5f6',
    base_asset: 'USD',
    quote_asset: 'NGN',
    bids: [
      { price: '1440.20', quantity: '117.59' },
      { price: '1440.19', quantity: '150.00' },
      { price: '1440.12', quantity: '1433.42' },
      { price: '1440.11', quantity: '614.32' },
      { price: '1440.10', quantity: '6290.91' },
    ],
    asks: [
      { price: '1442.80', quantity: '166.71' },
      { price: '1442.83', quantity: '153.55' },
      { price: '1442.84', quantity: '10.00' },
      { price: '1442.85', quantity: '10.00' },
      { price: '1442.90', quantity: '148.93' },
    ],
    stats: { best_bid: '1440.2', best_ask: '1442.8', spread: '2.6', spread_percent: '0.18', mid_price: '1441.5' },
    depth: 5,
    timestamp: '2026-11-21T18:48:40.312819Z',
  },
  timestamp: '2026-11-21T18:48:41Z',
};
const NOW = Date.parse('2026-11-21T18:48:41Z');
const clone = () => structuredClone(RAW) as typeof RAW;

test('sides swap under inversion: the cNGN bid is 1 / the NGN ask, the cNGN ask is 1 / the NGN bid', () => {
  const b = parseDayaBook(RAW, NOW);
  assert.equal(b.best_bid_usd_per_cngn_e18, '693096756307181'); // 1e18 / 1442.80 = 693096756307180.48, within 1 wei
  assert.equal(b.best_ask_usd_per_cngn_e18, '694348007221219'); // 1e18 / 1440.20 = 694348007221219.28
  assert.ok(BigInt(b.best_bid_usd_per_cngn_e18) < BigInt(b.mid_usd_per_cngn_e18));
  assert.ok(BigInt(b.mid_usd_per_cngn_e18) < BigInt(b.best_ask_usd_per_cngn_e18));
  assert.equal(b.spread_bps, 18.04);
  assert.equal(b.observed_at, Math.floor(Date.parse('2026-11-21T18:48:40.312819Z') / 1000));
  // cNGN bids come from NGN asks, best first; cNGN asks from NGN bids, best first.
  assert.deepEqual(b.bids.map((l) => l.ngn_per_usd), ['1442.80', '1442.83', '1442.84', '1442.85', '1442.90']);
  assert.deepEqual(b.asks.map((l) => l.ngn_per_usd), ['1440.20', '1440.19', '1440.12', '1440.11', '1440.10']);
  assert.equal(b.asks[4].usd, '6290.91');
});

test('levels are sorted here, not trusted to arrive sorted', () => {
  const raw = clone();
  raw.data.bids.reverse();
  raw.data.asks.reverse();
  assert.deepEqual(parseDayaBook(raw, NOW), parseDayaBook(RAW, NOW));
});

test('a book it cannot vouch for is refused', () => {
  const cases: [string, (r: ReturnType<typeof clone>) => void, RegExp][] = [
    ['not a success', (r) => { r.success = false; }, /not a success/],
    ['wrong symbol', (r) => { r.data.symbol = 'EUR-NGN'; }, /not USD-NGN/],
    ['empty bids', (r) => { r.data.bids = []; }, /bid side is empty/],
    ['empty asks', (r) => { r.data.asks = []; }, /ask side is empty/],
    ['crossed', (r) => { r.data.bids[0].price = '1443.00'; }, /crossed or locked/],
    ['locked', (r) => { r.data.bids[0].price = '1442.80'; }, /crossed or locked/],
    ['implausible price', (r) => { r.data.asks[0].price = '14428.0'; }, /outside/],
    ['price in kobo-per-cent', (r) => { r.data.bids[2].price = '1.4401'; }, /outside/],
    ['non-numeric price', (r) => { r.data.asks[1].price = 'n/a'; }, /outside/],
    ['zero quantity', (r) => { r.data.bids[1].quantity = '0'; }, /not positive/],
    ['bad timestamp', (r) => { r.data.timestamp = 'yesterday'; }, /does not parse/],
    ['future timestamp', (r) => { r.data.timestamp = '2026-11-21T18:48:50Z'; }, /in the future/],
  ];
  for (const [name, mutate, err] of cases) {
    const raw = clone();
    mutate(raw);
    assert.throws(() => parseDayaBook(raw, NOW), err, name);
  }
});

test('an HTTP error is an error, not an empty book', async () => {
  const fake = (async () => new Response('rate limited', { status: 429 })) as unknown as typeof fetch;
  await assert.rejects(fetchDayaBook(() => NOW, fake), /HTTP 429/);
  const ok = (async () => new Response(JSON.stringify(RAW), { status: 200 })) as unknown as typeof fetch;
  assert.equal((await fetchDayaBook(() => NOW, ok)).spread_bps, 18.04);
});

test('/daya: 503 before the first book, 200 while fresh by Daya\'s clock, 503 once stale', async () => {
  const state: State = {};
  let now = NOW;
  const route = handler(state, 300, () => now, 15);
  assert.equal(route('/daya').status, 503);
  await refreshDaya(state, async () => parseDayaBook(RAW, now));
  assert.equal(route('/daya').status, 200);
  assert.equal((route('/daya').body as DayaBook).best_bid_usd_per_cngn_e18, '693096756307181');
  // Daya's timestamp is 18:48:40; at +15 s from 18:48:41 it is 16 s old.
  now += 15_000;
  assert.equal(route('/daya').status, 503, 'stale by Daya\'s own timestamp');
});

test('a failing Daya keeps the last book until it ages out, and never touches /usd-per-cngn', async () => {
  const state: State = {};
  let now = NOW;
  const route = handler(state, 300, () => now, 15);
  await refresh(state, { getStablecoinToNgn: async () => ({ rate: 1447.08, provider: 'textile' }) }, () => now);
  await refreshDaya(state, async () => parseDayaBook(RAW, now));
  now += 5_000;
  await refreshDaya(state, async () => { throw new Error('Daya orderbook HTTP 503'); });
  assert.equal(route('/daya').status, 200, 'still inside the max age');
  now += 20_000;
  const r = route('/daya');
  assert.equal(r.status, 503);
  assert.match(JSON.stringify(r.body), /HTTP 503/);
  assert.equal(route('/usd-per-cngn').status, 200, 'the P2P reference is unaffected');
});
