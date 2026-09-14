import test from 'node:test';
import assert from 'node:assert/strict';

import { createSerialQueue } from './serial-queue.js';

function nextTurn() {
  return new Promise<void>((resolve) => setImmediate(resolve));
}

test('queued tasks run one at a time, in order', async () => {
  const enqueue = createSerialQueue();
  const events: string[] = [];
  let releaseFirst: () => void = () => {};

  const first = enqueue(async () => {
    events.push('first:start');
    await new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    events.push('first:end');
    return 1;
  });
  const second = enqueue(async () => {
    events.push('second:start');
    return 2;
  });

  await nextTurn();
  // The second send must not start while the first still holds the nonce.
  assert.deepEqual(events, ['first:start']);

  releaseFirst();
  assert.equal(await first, 1);
  assert.equal(await second, 2);
  assert.deepEqual(events, ['first:start', 'first:end', 'second:start']);
});

test('a failed task does not block the tasks behind it', async () => {
  const enqueue = createSerialQueue();

  const failed = enqueue(async () => {
    throw new Error('simulation reverted');
  });
  const next = enqueue(async () => 'sent');

  await assert.rejects(failed, /simulation reverted/);
  assert.equal(await next, 'sent');
});
