import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';

import { createWalletClient, http, keccak256, toHex } from 'viem';
import { base } from 'viem/chains';

import { broadcastWithNonce, classifyBroadcastError } from './broadcast.js';
import { NonceTracker } from './nonce-tracker.js';

// A JSON-RPC node whose answers to eth_sendRawTransaction are scripted, so every error reaches broadcast.ts exactly as
// viem raises it from a real HTTP transport -- wrapped, not hand-built.
type Answer = 'ok' | 'hang' | 'drop' | { error: string; code?: number };

async function node(answers: Answer[]) {
  const sent: string[] = [];
  const server: Server = createServer((req, res) => {
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      const call = JSON.parse(body);
      sent.push(call.params[0]);
      const answer = answers.shift() ?? 'ok';
      if (answer === 'hang') return;
      if (answer === 'drop') return req.socket.destroy();
      const payload = answer === 'ok'
        ? { jsonrpc: '2.0', id: call.id, result: keccak256(call.params[0]) }
        : { jsonrpc: '2.0', id: call.id, error: { code: answer.code ?? -32000, message: answer.error } };
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify(payload));
    });
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const wallet = createWalletClient({ chain: base, transport: http(url, { timeout: 300, retryCount: 0 }) });
  return {
    sent,
    sendRaw: (raw: `0x${string}`) => wallet.sendRawTransaction({ serializedTransaction: raw }),
    close: () => new Promise<void>((r) => { server.closeAllConnections(); server.close(() => r()); }),
  };
}

/** Signing stands in for prepare+sign: the bytes encode the nonce, so the test can read which nonce each send used. */
const sign = async (nonce: number) => toHex(`tx-with-nonce-${nonce}`);
const nonceOf = (raw: string) => Number(Buffer.from(raw.slice(2), 'hex').toString().split('-').pop());

type Run = { sent: number[]; hash?: `0x${string}`; error?: unknown };

async function run(answers: Answer[], tracker: NonceTracker, signer = sign): Promise<Run> {
  const n = await node(answers);
  try {
    const result = await broadcastWithNonce({ nonces: tracker, sign: signer, sendRaw: n.sendRaw }).then(
      (hash): Omit<Run, 'sent'> => ({ hash }),
      (error: unknown): Omit<Run, 'sent'> => ({ error }),
    );
    return { ...result, sent: n.sent.map(nonceOf) };
  } finally {
    await n.close();
  }
}

test('a clean broadcast uses the nonce, and the next send takes the one after', async () => {
  const tracker = new NonceTracker(async () => 55);
  assert.deepEqual((await run(['ok'], tracker)).sent, [55]);
  assert.deepEqual((await run(['ok'], tracker)).sent, [56]);
});

test('"already known": the transaction is in the mempool -- the nonce is used and the hash returned', async () => {
  const tracker = new NonceTracker(async () => 55);
  const r = await run([{ error: 'already known' }], tracker);
  assert.equal(r.hash, keccak256(await sign(55)));
  assert.equal(await tracker.take(), 56);
});

test('a send that times out is re-sent as the same bytes, and the nonce stays used', async () => {
  const tracker = new NonceTracker(async () => 55);
  const r = await run(['hang', { error: 'already known' }], tracker);
  assert.deepEqual(r.sent, [55, 55], 'the same signed transaction, not a re-signed one');
  assert.equal(r.hash, keccak256(await sign(55)));
  assert.equal(await tracker.take(), 56);
});

test('a send that never gets an answer still leaves the nonce used: giving it back could sign a second tx for it', async () => {
  const tracker = new NonceTracker(async () => 55);
  const r = await run(['hang', 'drop', 'hang'], tracker);
  assert.deepEqual(r.sent, [55, 55, 55]);
  assert.equal(r.hash, keccak256(await sign(55)), 'the hash goes to the receipt wait, which settles the outcome');
  assert.equal(await tracker.take(), 56);
});

test('a failure before the broadcast gives the nonce back: the next send uses it, leaving no gap', async () => {
  const tracker = new NonceTracker(async () => 55);
  const failing = async () => { throw new Error('estimateGas: execution reverted'); };
  const r = await run([], tracker, failing);
  assert.ok(r.error);
  assert.deepEqual(r.sent, [], 'nothing reached the node');
  assert.deepEqual((await run(['ok'], tracker)).sent, [55]);
});

test('a node that refuses the transaction (underfunded) gives the nonce back', async () => {
  const tracker = new NonceTracker(async () => 55);
  const r = await run([{ error: 'insufficient funds for gas * price + value' }], tracker);
  assert.ok(r.error);
  assert.equal(await tracker.take(), 55);
});

test('"nonce too low": something else holds it -- this send fails and the tracker moves past it', async () => {
  const tracker = new NonceTracker(async () => 55);
  const r = await run([{ error: 'nonce too low' }], tracker);
  assert.ok(r.error);
  assert.equal(await tracker.take(), 56);
});

test('"replacement transaction underpriced" is the same: the nonce is held by a pending transaction', async () => {
  const tracker = new NonceTracker(async () => 55);
  await run([{ error: 'replacement transaction underpriced' }], tracker);
  assert.equal(await tracker.take(), 56);
});

// The production error on 2026-10-09: Alchemy's answer to the duplicate. It is a refusal, so the nonce is given back;
// with the local counter the duplicate cannot be produced in the first place.
test('Alchemy\'s "Missing or invalid parameters" is a refusal, not a transport failure', async () => {
  const tracker = new NonceTracker(async () => 55);
  const r = await run([{ error: 'Missing or invalid parameters.', code: -32602 }], tracker);
  assert.ok(r.error);
  assert.equal(classifyBroadcastError(r.error), 'rejected');
  assert.deepEqual(r.sent, [55], 'refusals are not re-sent');
});
