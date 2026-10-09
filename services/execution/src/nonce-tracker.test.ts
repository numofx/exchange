import test from 'node:test';
import assert from 'node:assert/strict';

import { NonceTracker } from './nonce-tracker.js';

// The RPC is load-balanced: right after a broadcast, the node that answers can still report the old pending count.
test('a stale pending count after a broadcast does not hand the same nonce out twice', async () => {
  const nonces = new NonceTracker(async () => 55);
  const first = await nonces.take();
  nonces.confirm(first);
  assert.equal(first, 55);
  assert.equal(await nonces.take(), 56);
});

test('a chain ahead of the local count wins: a transaction sent from the same key elsewhere is respected', async () => {
  let pending = 55;
  const nonces = new NonceTracker(async () => pending);
  nonces.confirm(await nonces.take());
  pending = 60;
  assert.equal(await nonces.take(), 60);
});

test('only a confirmed broadcast advances the nonce', async () => {
  const nonces = new NonceTracker(async () => 55);
  assert.equal(await nonces.take(), 55);
  assert.equal(await nonces.take(), 55);
});
