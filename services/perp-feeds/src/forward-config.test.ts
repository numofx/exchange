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

  it('is v1 unless told otherwise, and refuses a negative carry there', () => {
    const kms = { FORWARD_SIGNER_KMS_KEY_ID: 'k' };
    const config = loadForwardConfig(env(kms));
    assert.equal(config.FUTURE_VERSION, 'v1');
    assert.equal(config.BASE_SYMBOL, 'cNGN');
    assert.throws(() => loadForwardConfig(env({ ...kms, CARRY: '-15000000000000000' })), /must not be negative on v1/);
  });

  it('takes a v2 series on any base, with a signed carry (EUR at a forward premium)', () => {
    const config = loadForwardConfig(env({ FORWARD_SIGNER_KMS_KEY_ID: 'k', FUTURE_VERSION: 'v2', BASE_SYMBOL: 'EURC', CARRY: '-15000000000000000' }));
    assert.equal(config.FUTURE_VERSION, 'v2');
    assert.equal(config.BASE_SYMBOL, 'EURC');
    assert.equal(config.CARRY, -15000000000000000n);
    assert.throws(() => loadForwardConfig(env({ FORWARD_SIGNER_KMS_KEY_ID: 'k', FUTURE_VERSION: 'v3' })));
  });

  it('needs exactly one signer', () => {
    assert.throws(() => loadForwardConfig(env({ CHAIN_ID: '84532' })), /exactly one/);
    assert.throws(
      () => loadForwardConfig(env({ CHAIN_ID: '84532', FORWARD_SIGNER_KEY: KEY, FORWARD_SIGNER_KMS_KEY_ID: 'k' })),
      /exactly one/,
    );
  });
});
