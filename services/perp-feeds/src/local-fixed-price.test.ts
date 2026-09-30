import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { assertLocalChain, localSources, parseFixedPrice, parseLocalSources } from './local-fixed-price.js';

describe('--local-fixed-price', () => {
  it('runs on a local anvil', () => {
    assert.doesNotThrow(() => assertLocalChain(31337, 31337));
  });

  it('refuses Base mainnet, whether configured or behind the RPC', () => {
    assert.throws(() => assertLocalChain(8453, 8453), /refuses CHAIN_ID = 8453/);
    // The dangerous case: config says local, the RPC is mainnet.
    assert.throws(() => assertLocalChain(31337, 8453), /refuses the RPC = 8453/);
  });

  it('refuses Base Sepolia and any other chain', () => {
    assert.throws(() => assertLocalChain(31337, 84532), /refuses the RPC = 84532/);
    assert.throws(() => assertLocalChain(1, 1), /only on a local anvil/);
  });

  it('parses the price, and is off without the flag', () => {
    assert.equal(parseFixedPrice(['node', 'main.js', '--local-fixed-price=1374']), 1374);
    assert.equal(parseFixedPrice(['node', 'main.js', '--once']), null);
    assert.throws(() => parseFixedPrice(['--local-fixed-price']));
    assert.throws(() => parseFixedPrice(['--local-fixed-price=0']));
  });
});

describe('--local-sources', () => {
  it('stands in three agreeing providers, and is off without the flag', async () => {
    assert.equal(parseLocalSources(['--local-sources=2290']), 2290);
    assert.equal(parseLocalSources(['--once']), null);
    const readings = await Promise.all(localSources(2290).map((source) => source.read({ signal: new AbortController().signal, fetch })));
    assert.deepEqual(readings.map((r) => r.cngnPerUsdt), [2290, 2290, 2290]);
  });
});
