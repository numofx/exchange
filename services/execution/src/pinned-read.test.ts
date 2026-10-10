import test from 'node:test';
import assert from 'node:assert/strict';

import { BaseError, ContractFunctionRevertedError, InvalidParamsRpcError, RpcRequestError, parseAbi } from 'viem';

import { isMissingBlock, readAtOrAfter } from './pinned-read.js';

// Shaped as viem delivers them: the node's words are in an RpcRequestError's `details`, wrapped by the action.
const missing = (words: string) =>
  new BaseError('eth_call failed', { cause: new RpcRequestError({ body: {}, url: 'http://node', error: { code: -32000, message: words } }) });
const reverted = () =>
  new BaseError('simulation failed', {
    cause: new ContractFunctionRevertedError({
      abi: parseAbi(['function f()']),
      functionName: 'f',
      message: 'ERC20: transfer amount exceeds allowance',
    }),
  });

function scripted(answers: unknown[]) {
  const calls: { blockNumber?: bigint }[] = [];
  const read = async (at: { blockNumber?: bigint }) => {
    calls.push(at);
    const next = answers.shift();
    if (next instanceof Error) throw next;
    return next;
  };
  return { calls, read };
}

test('nothing to wait for: one read at "latest", no block named', async () => {
  const { calls, read } = scripted(['ok']);
  assert.equal(await readAtOrAfter(undefined, read), 'ok');
  assert.deepEqual(calls, [{}]);
});

test('a node without the block yet is asked again, always at that block, until one has it', async () => {
  const { calls, read } = scripted([missing('header not found'), missing('block not found'), 'ok']);
  assert.equal(await readAtOrAfter(52_427_962n, read, { delayMs: 1 }), 'ok');
  assert.deepEqual(calls, [{ blockNumber: 52_427_962n }, { blockNumber: 52_427_962n }, { blockNumber: 52_427_962n }]);
});

test('a revert at the pinned block is the answer: it is thrown at once, not retried', async () => {
  const { calls, read } = scripted([reverted(), 'ok']);
  await assert.rejects(readAtOrAfter(1n, read, { delayMs: 1 }), (error) => error instanceof BaseError && /exceeds allowance/.test(String(error.walk())));
  assert.equal(calls.length, 1);
});

test('any other failure is not retried either', async () => {
  const { calls, read } = scripted([new InvalidParamsRpcError(new BaseError('Missing or invalid parameters')), 'ok']);
  await assert.rejects(readAtOrAfter(1n, read, { delayMs: 1 }));
  assert.equal(calls.length, 1);
});

test('a block that never arrives gives up after the attempts, with the node\'s error', async () => {
  const { calls, read } = scripted(Array.from({ length: 5 }, () => missing('header not found')));
  await assert.rejects(readAtOrAfter(1n, read, { attempts: 3, delayMs: 1 }), /header not found/);
  assert.equal(calls.length, 3);
});

test('the node phrasings we retry, and that a revert is not one of them', () => {
  for (const words of ['header not found', 'block not found', 'unknown block', 'block 0x31fffa is not yet available']) {
    assert.ok(isMissingBlock(missing(words)), words);
  }
  assert.ok(!isMissingBlock(reverted()));
  assert.ok(!isMissingBlock(new Error('HTTP request failed')));
});
