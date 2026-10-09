import test from 'node:test';
import assert from 'node:assert/strict';

import type { Config } from './config.js';
import { runCommand, type CliDeps } from './cli.js';
import { parseQuote, type FetchQuote } from './orderbook.js';

// The live response for 200 USDC on 2026-10-09: 271,464.199998 cNGN at 1357.99... per USDC.
const live = {
  route: 'SAME_CHAIN', side: 'BID',
  amountIn: '200000000000000000000', amountOut: '271464199998000000000000',
  rate: '1357999999993376817095', slippageBps: 5, fillable: true, maxFillableIn: '315347555709000000000000',
};

test('orderbook amounts are restated from 18dp to the tokens 6dp', () => {
  const q = parseQuote(live);
  assert.equal(q.amountIn, 200_000_000n);
  assert.equal(q.amountOut, 271_464_199_998n);
  assert.equal(q.maxFillableIn, 315_347_555_709n);
  assert.ok(Math.abs(q.rate - 1357.32) < 0.01, `rate ${q.rate}`);
});

test('a route that cannot fill the amount is refused, not priced', () => {
  assert.throws(() => parseQuote({ ...live, fillable: false }), /cannot fill/);
});

test('a zero output is refused', () => {
  assert.throws(() => parseQuote({ ...live, amountOut: '0' }), /zero output/);
});

// The wiring, not just the parser: an unpriceable book must reach the webhook as a failed run.
test('check --alert pages FAILED TO RUN when the orderbook cannot price', async () => {
  const posted: string[] = [];
  const unfillable: FetchQuote = async () => parseQuote({ ...live, fillable: false });
  const config = {
    MM_SUBACCOUNT_ID: 26n, VENUE_API_URL: 'http://127.0.0.1:1', ORDERBOOK_URL: 'http://127.0.0.1:1',
    ALERT_WEBHOOK_URL: 'https://hooks.example.invalid/x', CNGN_MIN_SHARE: 0.35, CNGN_FLOOR_USD: 100, HALT_NET_INVENTORY_USD: 800,
  } as unknown as Config;
  const MANAGER = '0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4';
  const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272';
  const ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98';
  // Everything else healthy, so the orderbook is the only thing that can fail the run.
  const readContract = async (a: { functionName: string }) => {
    switch (a.functionName) {
      case 'manager': return MANAGER;
      case 'assetDetails': return { isWhitelisted: true, assetType: 3, marketId: 1n };
      case 'cashAsset': return CASH;
      case 'getAccountBalances': return [];
      default: throw new Error(`unexpected call ${a.functionName}`);
    }
  };
  const deps = {
    readClients: () => ({ publicClient: { readContract } }),
    signingClients: async () => { throw new Error('read-only'); },
    post: async (_url: string, text: string) => { posted.push(text); },
    fetchQuote: unfillable,
    fetchMarkets: async () => [{ contract_type: 'spot', base_asset_symbol: 'cNGN', asset_address: ESCROW, quote_asset_address: CASH, margin_manager_address: MANAGER }],
  } as unknown as CliDeps;
  await assert.rejects(runCommand(['check', '--alert'], config, deps));
  assert.equal(posted.length, 1);
  assert.match(posted[0] ?? '', /FAILED TO RUN.*cannot fill/);
});
