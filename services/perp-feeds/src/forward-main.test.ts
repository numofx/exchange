import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { keccak256, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import { loadForwardConfig } from './forward-config.js';
import { obtainSigner, sweep } from './forward-main.js';

const config = loadForwardConfig({
  RPC_URL: 'http://127.0.0.1:8545',
  RELAYER_KEY: keccak256(toHex('relayer')),
  FORWARD_SIGNER_KMS_KEY_ID: 'arn:aws:kms:us-east-1:1:key/forward',
  DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
  INDEX_FEED: '0x00000000000000000000000000000000000000A1',
  FORWARD_FEED: '0x00000000000000000000000000000000000000A4',
  FUTURE_ASSET: '0x00000000000000000000000000000000000000F0',
  FUTURE_SUB_ID: '1796047200',
  CARRY: '0',
});

describe('forward signer at startup', () => {
  it('keeps trying KMS, alerting each failure, instead of crashing', async () => {
    const alerts: string[] = [];
    let calls = 0;
    const signer = privateKeyToAccount(keccak256(toHex('kms-stand-in')));
    const got = await obtainSigner(
      config,
      async (key) => void alerts.push(key),
      async () => {
        calls++;
        if (calls < 3) throw new Error('AccessDeniedException: kms:GetPublicKey');
        return signer;
      },
      0,
    );
    assert.equal(got.address, signer.address);
    assert.equal(calls, 3);
    assert.deepEqual(alerts, ['forward-signer-unavailable', 'forward-signer-unavailable']);
  });

  it('gives up only when told to, after alerting', async () => {
    const alerts: string[] = [];
    await assert.rejects(
      () => obtainSigner(config, async (key) => void alerts.push(key), async () => Promise.reject(new Error('KMS down')), 0, 1),
      /KMS down/,
    );
    assert.deepEqual(alerts, ['forward-signer-unavailable']);
  });
});

describe('VM sweep', () => {
  it('alerts a sweep that throws, and does not take the loop down with it', async () => {
    const alerts: string[] = [];
    await sweep({ sweep: async () => Promise.reject(new Error('rpc down')) }, async (key) => void alerts.push(key));
    assert.deepEqual(alerts, ['sweep-error']);
  });
});
