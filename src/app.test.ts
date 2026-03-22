import test from 'node:test';
import assert from 'node:assert/strict';

import { buildApp } from './app.js';
import type { AppConfig } from './config.js';
import { assertPayloadConsistency } from './executor.js';
import type { ExecuteMatchRequest, ExecuteMatchResponse } from './types.js';

const config: AppConfig = {
  port: 8081,
  host: '127.0.0.1',
  rpcUrl: 'http://127.0.0.1:8545',
  privateKey: '0x1111111111111111111111111111111111111111111111111111111111111111',
  chainId: 8453,
  matchingRepoPath: '/tmp/matching',
  executorAddress: '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A',
  expectedActionOwner: undefined,
  expectedActionSigner: undefined,
  dryRun: true,
  waitForReceipt: false,
};

const requestPayload: ExecuteMatchRequest = {
  market: 'BTCUSDC-CVXPERP',
  asset_address: '0x0000000000000000000000000000000000000001',
  module_address: '0x0000000000000000000000000000000000000002',
  maker_order_id: 'maker-1',
  taker_order_id: 'taker-1',
  actions: [
    {
      subaccount_id: '10',
      nonce: '1',
      module: '0x0000000000000000000000000000000000000002',
      data: '0x1234',
      expiry: '1710000000',
      owner: '0x0000000000000000000000000000000000000003',
      signer: '0x0000000000000000000000000000000000000004',
    },
    {
      subaccount_id: '11',
      nonce: '2',
      module: '0x0000000000000000000000000000000000000002',
      data: '0x5678',
      expiry: '1710000000',
      owner: '0x0000000000000000000000000000000000000005',
      signer: '0x0000000000000000000000000000000000000006',
    },
  ],
  signatures: ['0xaaaa', '0xbbbb'],
  order_data: {
    taker_account: '10',
    taker_fee: '0',
    fill_details: [
      {
        filled_account: '11',
        amount_filled: '100',
        price: '75',
        fee: '0',
      },
    ],
    manager_data: '0x',
  },
};

test('GET /healthz returns executor status', async () => {
  const app = buildApp({
    config,
    executor: {
      execute: async (): Promise<ExecuteMatchResponse> => ({ accepted: true, tx_hash: 'dry-run' }),
    },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
  });

  const response = await app.inject({ method: 'GET', url: '/healthz' });
  assert.equal(response.statusCode, 200);

  const body = response.json();
  assert.equal(body.status, 'ok');
  assert.equal(body.chain_id, 8453);
  assert.equal(body.executor_address, '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A');

  await app.close();
});

test('POST /execute validates request payload', async () => {
  const app = buildApp({
    config,
    executor: {
      execute: async (): Promise<ExecuteMatchResponse> => ({ accepted: true, tx_hash: 'dry-run' }),
    },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
  });

  const invalidPayload = {
    ...requestPayload,
    order_data: {
      ...requestPayload.order_data,
      taker_account: '999',
    },
  };

  const response = await app.inject({ method: 'POST', url: '/execute', payload: invalidPayload });
  assert.equal(response.statusCode, 400);

  await app.close();
});

test('assertPayloadConsistency rejects owner mismatch when an expected owner is configured', () => {
  assert.throws(
    () =>
      assertPayloadConsistency(requestPayload, {
        tradeModuleAddress: '0x0000000000000000000000000000000000000002',
        expectedActionOwner: '0x00000000000000000000000000000000000000cc',
      }),
    /owner mismatch/,
  );
});

test('POST /execute forwards valid payload to executor', async () => {
  let received: ExecuteMatchRequest | undefined;

  const app = buildApp({
    config,
    executor: {
      execute: async (request): Promise<ExecuteMatchResponse> => {
        received = request;
        return { accepted: true, tx_hash: 'dry-run' };
      },
    },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
  });

  const response = await app.inject({ method: 'POST', url: '/execute', payload: requestPayload });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(received, requestPayload);

  await app.close();
});
