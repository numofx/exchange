import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { createAlerter } from './alert.js';
describe('createAlerter', () => {
    it('prefixes every alert it posts, so a rehearsal can never read as the real thing', async () => {
        const bodies = [];
        const fakeFetch = (async (_url, init) => {
            bodies.push(String(init?.body));
            return new Response(null, { status: 200 });
        });
        const alert = createAlerter('https://hooks.example/x', 0, Date.now, fakeFetch, '[REHEARSAL] ');
        await alert('keeper-error', 'keeper pass failed');
        assert.equal(JSON.parse(bodies[0]).text, '[perp-keeper] [REHEARSAL] keeper pass failed');
    });
});
