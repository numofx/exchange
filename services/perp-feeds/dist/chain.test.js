import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createChain, serialized } from './chain.js';
describe('relayer account', () => {
    it('tracks its own nonce, so a lagging RPC node cannot hand the previous nonce out again', () => {
        const chain = createChain({
            CHAIN_ID: 31337,
            RPC_URL: 'http://127.0.0.1:8599',
            RELAYER_KEY: '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d',
            FEED_SIGNER_KEY: '0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a',
            DATA_SUBMITTER: '0x0000000000000000000000000000000000000001',
        });
        assert.ok(chain.relayer.nonceManager, 'relayer has no nonce manager');
    });
});
describe('serialized submissions', () => {
    it('starts each task only after the previous one has settled, in call order', async () => {
        const submit = serialized();
        const events = [];
        let releaseFirst = () => undefined;
        const first = submit(async () => {
            events.push('first start');
            await new Promise((resolve) => {
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
