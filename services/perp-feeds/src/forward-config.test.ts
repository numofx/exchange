import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { loadForwardConfig } from './forward-config.js';

const KEY = `0x${'11'.repeat(32)}`;
const ADDR = `0x${'22'.repeat(20)}`;

function env(overrides: Record<string, string | undefined> = {}): NodeJS.ProcessEnv {
  return {
    RPC_URL: 'http://127.0.0.1:8545',
    RELAYER_KEY: KEY,
    DATA_SUBMITTER: ADDR,
    INDEX_FEED: ADDR,
    FORWARD_FEED: ADDR,
    FUTURE_ASSET: ADDR,
    FUTURE_MANAGER: ADDR,
    SUB_ACCOUNTS: ADDR,
    FUTURE_SUB_ID: '1796047200',
    CARRY: '200000000000000000',
    ...overrides,
  };
}

describe('forward config', () => {
  it('takes a KMS signer on mainnet', () => {
    const config = loadForwardConfig(env({ FORWARD_SIGNER_KMS_KEY_ID: 'arn:aws:kms:us-east-1:1:key/x' }));
    assert.equal(config.CHAIN_ID, 8453);
    assert.equal(config.FUTURE_SUB_ID, 1796047200n);
    assert.equal(config.CARRY, 200000000000000000n);
  });

  it('refuses a raw signer key on mainnet', () => {
    assert.throws(() => loadForwardConfig(env({ FORWARD_SIGNER_KEY: KEY })), /must be a KMS key/);
  });

  it('takes a raw signer key off mainnet, for anvil and Sepolia', () => {
    assert.equal(loadForwardConfig(env({ CHAIN_ID: '84532', FORWARD_SIGNER_KEY: KEY })).CHAIN_ID, 84532);
  });

  it('needs exactly one signer', () => {
    assert.throws(() => loadForwardConfig(env({ CHAIN_ID: '84532' })), /exactly one/);
    assert.throws(
      () => loadForwardConfig(env({ CHAIN_ID: '84532', FORWARD_SIGNER_KEY: KEY, FORWARD_SIGNER_KMS_KEY_ID: 'k' })),
      /exactly one/,
    );
  });
});
