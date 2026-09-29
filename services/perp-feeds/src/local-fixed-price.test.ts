import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { assertLocalChain, parseFixedPrice } from './local-fixed-price.js';

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
