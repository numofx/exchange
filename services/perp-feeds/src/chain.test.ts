import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { serialized } from './chain.js';

describe('serialized submissions', () => {
  it('starts each task only after the previous one has settled, in call order', async () => {
    const submit = serialized();
    const events: string[] = [];
    let releaseFirst: () => void = () => undefined;
    const first = submit(async () => {
      events.push('first start');
      await new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      events.push('first end');
      return 'a';
    });
    const second = submit(async () => {
      events.push('second start');
      return 'b';
    });
    // The index publisher's transaction is in flight: the mark publisher's must not be sent yet.
    await new Promise((resolve) => setImmediate(resolve));
    assert.deepEqual(events, ['first start']);
    releaseFirst();
    assert.deepEqual(await Promise.all([first, second]), ['a', 'b']);
    assert.deepEqual(events, ['first start', 'first end', 'second start']);
  });

  it('keeps going after a failed task, and the failure reaches only its own caller', async () => {
    const submit = serialized();
    const failed = submit(async () => {
      throw new Error('replacement transaction underpriced');
    });
    const next = submit(async () => 'published');
    await assert.rejects(failed, /underpriced/);
    assert.equal(await next, 'published');
  });
});
