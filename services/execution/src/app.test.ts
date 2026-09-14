import test from 'node:test';
import assert from 'node:assert/strict';

import { buildApp } from './app.js';
import type { AppConfig } from './config.js';
import { assertPayloadConsistency, buildReceiptResponse } from './executor.js';
import type { ExecuteMatchRequest, ExecuteMatchResponse, WithdrawRequest } from './types.js';
import { WithdrawalRejectedError } from './withdrawal.js';

const config: AppConfig = {
  port: 8081,
  host: '127.0.0.1',
  rpcUrl: 'http://127.0.0.1:8545',
  privateKey: '0x1111111111111111111111111111111111111111111111111111111111111111',
  chainId: 8453,
  executorAddress: '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A',
  expectedActionOwner: undefined,
  expectedActionSigner: undefined,
  dryRun: true,
  waitForReceipt: false,
  receiptTimeoutMs: 60_000,
  withdrawalAssetAddresses: [],
  withdrawalReceiptTimeoutMs: 30_000,
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

test('POST /execute rejects a non-zero maker fill fee (0.00% maker fee guaranteed)', async () => {
  const app = buildApp({
    config,
    executor: {
      execute: async (): Promise<ExecuteMatchResponse> => ({ accepted: true, tx_hash: 'dry-run' }),
    },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
  });

  const makerFeePayload = {
    ...requestPayload,
    order_data: {
      ...requestPayload.order_data,
      fill_details: [{ ...requestPayload.order_data.fill_details[0], fee: '1' }],
    },
  };

  const response = await app.inject({ method: 'POST', url: '/execute', payload: makerFeePayload });
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

test('a reverted receipt is not an accepted fill', () => {
  const response = buildReceiptResponse('0xabc' as `0x${string}`, {
    status: 'reverted',
    blockNumber: 42n,
  });

  // The matcher finalizes on accepted. A revert moved no funds on chain, so
  // recording it as a fill would put the book out of sync with settlement.
  assert.equal(response.accepted, false);
  assert.equal(response.receipt_status, 'reverted');
  assert.equal(response.block_number, '42');
  assert.equal(response.tx_hash, '0xabc');
});

test('a successful receipt is an accepted fill', () => {
  const response = buildReceiptResponse('0xdef' as `0x${string}`, {
    status: 'success',
    blockNumber: 43n,
  });

  assert.equal(response.accepted, true);
  assert.equal(response.receipt_status, 'success');
  assert.equal(response.block_number, '43');
});

const withdrawPayload: WithdrawRequest = {
  action: {
    subaccount_id: '19',
    nonce: '7',
    module: '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB',
    // abi.encode(wrapped USDC, 1.999575 USDC)
    data: `0x${'0'.repeat(24)}364058aff6f36e01505fb2cc870f8b6bd4835e84${(1_999_575).toString(16).padStart(64, '0')}`,
    expiry: '4102444800',
    owner: '0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA',
    signer: '0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA',
  },
  signature: `0x${'ab'.repeat(65)}`,
};

function withdrawApp(withdraw?: (request: WithdrawRequest) => Promise<ExecuteMatchResponse>) {
  return buildApp({
    config,
    executor: { execute: async (): Promise<ExecuteMatchResponse> => ({ accepted: true, tx_hash: 'dry-run' }) },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
    withdrawer: withdraw ? { withdraw } : undefined,
  });
}

test('POST /withdraw answers 503 when withdrawals are not configured', async () => {
  const app = withdrawApp();
  const response = await app.inject({ method: 'POST', url: '/withdraw', payload: withdrawPayload });
  assert.equal(response.statusCode, 503);
  await app.close();
});

test('POST /withdraw validates the request shape before submitting anything', async () => {
  let called = false;
  const app = withdrawApp(async () => {
    called = true;
    return { accepted: true, tx_hash: 'dry-run' };
  });

  for (const payload of [
    { action: withdrawPayload.action },
    { ...withdrawPayload, signature: '0xabcd' },
    { actions: [withdrawPayload.action], signatures: [withdrawPayload.signature] },
  ]) {
    const response = await app.inject({ method: 'POST', url: '/withdraw', payload });
    assert.equal(response.statusCode, 400, JSON.stringify(payload));
  }
  assert.equal(called, false);
  await app.close();
});

test('POST /withdraw reports a rejected withdrawal as 422 with the revert named', async () => {
  const app = withdrawApp(async () => {
    throw new WithdrawalRejectedError('withdrawal would revert: WERC_CannotBeNegative', 'WERC_CannotBeNegative');
  });

  const response = await app.inject({ method: 'POST', url: '/withdraw', payload: withdrawPayload });
  assert.equal(response.statusCode, 422);
  assert.deepEqual(response.json(), {
    error: 'withdrawal would revert: WERC_CannotBeNegative',
    revert: 'WERC_CannotBeNegative',
  });
  await app.close();
});

test('POST /withdraw forwards a valid withdrawal and returns its receipt', async () => {
  let received: WithdrawRequest | undefined;
  const app = withdrawApp(async (request) => {
    received = request;
    return { accepted: true, tx_hash: '0xabc', receipt_status: 'success', block_number: '42' };
  });

  const response = await app.inject({ method: 'POST', url: '/withdraw', payload: withdrawPayload });
  assert.equal(response.statusCode, 200);
  assert.deepEqual(received, withdrawPayload);
  assert.deepEqual(response.json(), { accepted: true, tx_hash: '0xabc', receipt_status: 'success', block_number: '42' });
  await app.close();
});
