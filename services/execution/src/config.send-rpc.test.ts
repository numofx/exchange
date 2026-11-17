import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from './config.js';

function load(extra: Record<string, string | undefined>) {
  const keys = ['RPC_URL', 'SEND_RPC_URL', 'PRIVATE_KEY', 'CHAIN_ID'];
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  Object.assign(process.env, { RPC_URL: 'https://reads.invalid/rpc', PRIVATE_KEY: `0x${'11'.repeat(32)}`, CHAIN_ID: '8453' });
  delete process.env.SEND_RPC_URL;
  for (const [k, v] of Object.entries(extra)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return loadConfig();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test('SEND_RPC_URL is where transactions go; unset or empty, RPC_URL', () => {
  assert.equal(load({ SEND_RPC_URL: 'https://sends.invalid/key' }).sendRpcUrl, 'https://sends.invalid/key');
  assert.equal(load({}).sendRpcUrl, 'https://reads.invalid/rpc');
  assert.equal(load({ SEND_RPC_URL: '' }).sendRpcUrl, 'https://reads.invalid/rpc');
  assert.equal(load({ SEND_RPC_URL: 'https://sends.invalid/key' }).rpcUrl, 'https://reads.invalid/rpc', 'reads stay put');
});
