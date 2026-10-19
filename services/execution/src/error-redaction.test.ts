import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import type { AddressInfo } from 'node:net';

import { createPublicClient, encodeErrorResult, http as httpTransport, parseAbi } from 'viem';

import { buildApp, publicErrorMessage } from './app.js';
import type { AppConfig } from './config.js';

// An Alchemy RPC URL carries its API key in the path. viem puts the URL in a transport error's message, and a 500's
// body is stored by markets-service on deposit records anyone can read: the key must reach the log and never the body.
const KEY = 'alch_TESTKEY_must_not_leak_0123456789';

// matching/revert.go in markets-service classifies a failed settlement by these, on the 500's body.
const revertSignaturePattern = /reverted with the following signature:(?:\\n|\s)*(0x[0-9a-fA-F]{8})/;
const revertNamePattern = /Error: ([A-Z]+_[A-Za-z0-9]+)\(/;

const abi = parseAbi(['function verifyAndMatch(uint256 x)', 'error TM_FeeTooHigh()']);

async function deadPort(): Promise<number> {
  const server = http.createServer();
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

/** The error viem throws when the RPC cannot be reached: its message holds the keyed URL. */
async function transportError(): Promise<Error> {
  const client = createPublicClient({ transport: httpTransport(`http://127.0.0.1:${await deadPort()}/v2/${KEY}`, { retryCount: 0 }) });
  try {
    await client.getBlockNumber();
  } catch (error) {
    return error as Error;
  }
  throw new Error('the dead endpoint answered');
}

/** The error viem throws when a simulated call reverts with `data`, from an RPC whose URL holds the key. */
async function revertError(data: `0x${string}`): Promise<Error> {
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      const { id } = JSON.parse(body) as { id: number };
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code: 3, message: 'execution reverted', data } }));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address() as AddressInfo;
  try {
    const client = createPublicClient({ transport: httpTransport(`http://127.0.0.1:${port}/v2/${KEY}`, { retryCount: 0 }) });
    await client.simulateContract({
      address: '0x0000000000000000000000000000000000000001',
      abi,
      functionName: 'verifyAndMatch',
      args: [1n],
      account: '0x0000000000000000000000000000000000000002',
    });
  } catch (error) {
    return error as Error;
  } finally {
    server.close();
  }
  throw new Error('the call did not revert');
}

const config = {
  port: 0, host: '127.0.0.1', rpcUrl: 'http://127.0.0.1:1', chainId: 8453,
  executorAddress: '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A', dryRun: true, waitForReceipt: false,
  receiptTimeoutMs: 60_000, withdrawalAssetAddresses: [], withdrawalReceiptTimeoutMs: 30_000,
} as unknown as AppConfig;

const action = {
  subaccount_id: '0', nonce: '7', module: '0x00000000000000000000000000000000000000bb',
  data: `0x${'00'.repeat(96)}`, expiry: '1999999999',
  owner: '0x0000000000000000000000000000000000000003', signer: '0x0000000000000000000000000000000000000003',
};
const depositPayload = { action, signature: `0x${'ab'.repeat(65)}` };
const executePayload = {
  market: 'USDC-cNGN-30NOV26',
  asset_address: '0x0000000000000000000000000000000000000001',
  module_address: '0x00000000000000000000000000000000000000bb',
  maker_order_id: 'maker-1',
  taker_order_id: 'taker-1',
  actions: [action, { ...action, subaccount_id: '11', nonce: '8' }],
  signatures: ['0xaaaa', '0xbbbb'],
  order_data: { taker_account: '0', taker_fee: '0', fill_details: [{ filled_account: '11', amount_filled: '100', price: '1', fee: '0' }], manager_data: '0x' },
};

function appThrowing(error: Error) {
  const lines: string[] = [];
  const app = buildApp({
    config,
    executor: { execute: async () => { throw error; } },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
    depositor: { deposit: async () => { throw error; } },
    logStream: { write: (line: string) => void lines.push(line) },
  });
  return { app, lines };
}

test('the premise: a viem transport error carries the keyed RPC URL in its message', async () => {
  const error = await transportError();
  assert.ok(error.message.includes(KEY), error.message);
});

test('a transport error on POST /deposit is a 500 that logs the URL and never returns it', async () => {
  const { app, lines } = appThrowing(await transportError());
  const response = await app.inject({ method: 'POST', url: '/deposit', payload: depositPayload });
  await app.close();

  assert.equal(response.statusCode, 500, response.body);
  assert.ok(!response.body.includes(KEY) && !response.body.includes('/v2/') && !response.body.includes('127.0.0.1'), response.body);
  assert.match(response.json().error, /HTTP request failed/);
  assert.ok(lines.join('').includes(KEY), 'the full error, URL included, must be in the server log');
});

test('a revert on POST /execute keeps the text the matcher classifies on', async () => {
  for (const [data, check] of [
    [encodeErrorResult({ abi, errorName: 'TM_FeeTooHigh' }), (body: string) => assert.equal(revertNamePattern.exec(body)?.[1], 'TM_FeeTooHigh', body)],
    ['0x786025f5', (body: string) => assert.equal(revertSignaturePattern.exec(body)?.[1], '0x786025f5', body)],
  ] as const) {
    const { app } = appThrowing(await revertError(data));
    const response = await app.inject({ method: 'POST', url: '/execute', payload: executePayload });
    await app.close();
    assert.equal(response.statusCode, 500, response.body);
    assert.ok(!response.body.includes(KEY), response.body);
    check(response.json().error);
  }
});

test('publicErrorMessage drops the URL and request-body lines and replaces any other URL', () => {
  const error = new Error([
    'HTTP request failed.',
    '',
    `URL: https://base-mainnet.g.alchemy.com/v2/${KEY}`,
    'Request body: {"method":"eth_call"}',
    '',
    `Details: request to wss://base-mainnet.g.alchemy.com/v2/${KEY} failed`,
  ].join('\n'));
  const message = publicErrorMessage(error);
  assert.ok(!message.includes(KEY) && !message.includes('alchemy'), message);
  assert.ok(!message.includes('Request body'), message);
  assert.match(message, /^HTTP request failed\./);
  assert.match(message, /Details: request to <url> failed/);
  assert.equal(publicErrorMessage('not an error'), 'unknown error');
});
