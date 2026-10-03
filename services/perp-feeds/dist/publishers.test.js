import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { formatUnits, keccak256, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { loadConfig } from './config.js';
import { encodeSpotData, encodeSpotDiffData } from './feed-data.js';
import { IndexPublisher, pushIndexStatus } from './index-publisher.js';
import { toUsdPerNgn } from './index-aggregation.js';
import { MarkPublisher } from './mark-publisher.js';
import { toSpotDiff } from './mark-targets.js';
/**
 * The refresh path, end to end through each publisher: when a feed is republished because it is
 * getting old, the value signed is recomputed from fresh inputs through every guard, never the
 * value already on chain signed again.
 */
const E18 = 10n ** 18n;
const HEAD = 1800000000n;
const INDEX = 720000000000000n;
const key = (label) => keccak256(toHex(label));
const feeds = {
    INDEX_FEED: '0x00000000000000000000000000000000000000a1',
    MARK_FEED: '0x00000000000000000000000000000000000000a2',
    IMPACT_ASK_FEED: '0x00000000000000000000000000000000000000a3',
    IMPACT_BID_FEED: '0x00000000000000000000000000000000000000a4',
};
function config() {
    return loadConfig({
        RPC_URL: 'http://127.0.0.1:1',
        CHAIN_ID: '31337',
        FEED_SIGNER_KEY: key('perp-feeds-test-signer'),
        RELAYER_KEY: key('perp-feeds-test-relayer'),
        DATA_SUBMITTER: '0x00000000000000000000000000000000000000b1',
        PERP_ASSET: '0x00000000000000000000000000000000000000b2',
        INDEX_STATE_FILE: join(mkdtempSync(join(tmpdir(), 'perp-feeds-')), 'state.json'),
        INDEX_STATUS_FILE: join(mkdtempSync(join(tmpdir(), 'perp-feeds-status-')), 'status.json'),
        SOURCE_RETRY_DELAY_MS: '0',
        ...feeds,
    });
}
function fakeChain(state) {
    const submitted = [];
    return {
        signer: privateKeyToAccount(key('perp-feeds-test-signer')),
        relayer: privateKeyToAccount(key('perp-feeds-test-relayer')),
        chainId: 31337,
        submitted,
        headTimestamp: async () => HEAD,
        readIndex: async () => state.index,
        readDiffFeed: async (feed) => state.diffs[feed.toLowerCase()] ?? null,
        submit: async (data) => {
            submitted.push(data);
            return '0x01';
        },
    };
}
const quiet = async () => { };
const strip = (hex) => hex.slice(2);
describe('mark refresh', () => {
    // Every diff feed is at the index and 8 minutes old: past MARK_MAX_AGE_MS (7 min), no price move.
    const stale = () => Object.fromEntries([feeds.MARK_FEED, feeds.IMPACT_ASK_FEED, feeds.IMPACT_BID_FEED].map((feed) => [
        feed.toLowerCase(),
        { result: INDEX, updatedAt: HEAD - 480n },
    ]));
    it('signs the target recomputed from the current book, not the value the feed already holds', async () => {
        const bid = (INDEX * 10040n) / 10000n;
        const ask = (INDEX * 10060n) / 10000n;
        const book = [
            { side: 'buy', price: bid, remaining: (5000n * E18 * E18) / bid },
            { side: 'sell', price: ask, remaining: (5000n * E18 * E18) / ask },
        ];
        const chain = fakeChain({ index: INDEX, diffs: stale() });
        await new MarkPublisher(config(), chain, quiet, async () => book).publish();
        assert.equal(chain.submitted.length, 1);
        const newMark = (bid + ask) / 2n;
        assert.ok(chain.submitted[0].includes(strip(encodeSpotDiffData(toSpotDiff(newMark, INDEX)))));
        assert.ok(!chain.submitted[0].includes(strip(encodeSpotDiffData(0n))), 'the old zero diff was re-signed');
    });
    it('re-applies the basis clamp on refresh', async () => {
        // The book is 10% through the index; the refreshed mark is clamped to the 200bps band.
        const bid = (INDEX * 11000n) / 10000n;
        const ask = (INDEX * 11010n) / 10000n;
        const book = [
            { side: 'buy', price: bid, remaining: (5000n * E18 * E18) / bid },
            { side: 'sell', price: ask, remaining: (5000n * E18 * E18) / ask },
        ];
        const chain = fakeChain({ index: INDEX, diffs: stale() });
        await new MarkPublisher(config(), chain, quiet, async () => book).publish();
        const clamped = (INDEX * 10200n) / 10000n;
        assert.ok(chain.submitted[0].includes(strip(encodeSpotDiffData(toSpotDiff(clamped, INDEX)))));
    });
    it('publishes nothing when the index it would anchor to is stale', async () => {
        const chain = fakeChain({ index: null, diffs: stale() });
        await new MarkPublisher(config(), chain, quiet, async () => []).publish();
        assert.equal(chain.submitted.length, 0);
    });
});
describe('index refresh', () => {
    const MINUTE = 60_000;
    const nowMs = Number(HEAD) * 1000;
    function publisher(chain, samples) {
        const index = new IndexPublisher(config(), chain, [], quiet, () => nowMs);
        index.state = {
            samples,
            lastPublished: toUsdPerNgn(1374).toString(),
        };
        return index;
    }
    it('publishes the TWAP of fresh samples, not the last published value', async () => {
        const samples = Array.from({ length: 12 }, (_, i) => ({ price: 1380, at: nowMs - (12 - i) * MINUTE + 30_000 }));
        const chain = fakeChain({ index: toUsdPerNgn(1374), diffs: {} });
        await publisher(chain, samples).publish();
        assert.equal(chain.submitted.length, 1);
        assert.ok(chain.submitted[0].includes(strip(encodeSpotData(toUsdPerNgn(1380)))));
    });
    it('refuses when no source has confirmed the price recently, however full the window', async () => {
        const samples = Array.from({ length: 12 }, (_, i) => ({ price: 1374, at: nowMs - (15 - i) * MINUTE + 30_000 }));
        const chain = fakeChain({ index: toUsdPerNgn(1374), diffs: {} });
        await publisher(chain, samples).publish();
        assert.equal(chain.submitted.length, 0);
    });
    it('re-runs the jump guard against the chain on every refresh', async () => {
        const samples = Array.from({ length: 12 }, (_, i) => ({ price: 1450, at: nowMs - (12 - i) * MINUTE + 30_000 }));
        const chain = fakeChain({ index: toUsdPerNgn(1374), diffs: {} });
        await publisher(chain, samples).publish();
        assert.equal(chain.submitted.length, 0);
    });
});
describe('index sample and the peg guard', () => {
    const three = ['a', 'b', 'c'].map((name) => ({ name, read: async () => ({ source: name, cngnPerUsdt: 1374 }) }));
    it('accepts a sample at parity and writes what it saw', async () => {
        const cfg = config();
        const index = new IndexPublisher(cfg, fakeChain({ index: null, diffs: {} }), three, quiet, () => Number(HEAD) * 1000, async () => ({ buy: 0.9999, sell: 1.0001 }));
        await index.sample();
        assert.equal(index.samples().length, 1);
        const status = JSON.parse(readFileSync(cfg.INDEX_STATUS_FILE, 'utf8'));
        assert.equal(status.pegGuardTripped, false);
        assert.equal(status.sample.ok, true);
    });
    it('refuses the sample, alerts, and records the trip when cNGN leaves parity', async () => {
        const cfg = config();
        const alerts = [];
        const index = new IndexPublisher(cfg, fakeChain({ index: null, diffs: {} }), three, async (key) => void alerts.push(key), () => Number(HEAD) * 1000, async () => ({ buy: 0.984, sell: 0.985 }));
        await index.sample();
        assert.equal(index.samples().length, 0, 'no sample taken past the peg guard');
        assert.deepEqual(alerts, ['peg-guard']);
        const status = JSON.parse(readFileSync(cfg.INDEX_STATUS_FILE, 'utf8'));
        assert.equal(status.pegGuardTripped, true);
        assert.match(status.sample.reason, /peg guard/);
    });
    it('retries a failed source once within the sample, and goes without it after a second failure', async () => {
        const calls = { flaky: 0, dead: 0 };
        const flaky = { name: 'flaky', read: async () => {
                calls.flaky += 1;
                if (calls.flaky === 1)
                    throw new Error('api.textilecredit.com returned 502');
                return { source: 'flaky', cngnPerUsdt: 1374 };
            } };
        const parity = async () => ({ buy: 0.9999, sell: 1.0001 });
        const recovered = new IndexPublisher(config(), fakeChain({ index: null, diffs: {} }), [three[0], three[1], flaky], quiet, () => Number(HEAD) * 1000, parity);
        await recovered.sample();
        assert.equal(calls.flaky, 2);
        assert.equal(recovered.samples().length, 1, 'one transient failure no longer costs the sample');
        const dead = { name: 'dead', read: async () => {
                calls.dead += 1;
                throw new Error('api.textilecredit.com returned 502');
            } };
        const refused = new IndexPublisher(config(), fakeChain({ index: null, diffs: {} }), [three[0], three[1], dead], quiet, () => Number(HEAD) * 1000, parity);
        await refused.sample();
        assert.equal(calls.dead, 2, 'exactly one retry');
        assert.equal(refused.samples().length, 0);
    });
    it('keeps sampling at parity when the tripwire is blind, and says so', async () => {
        const cfg = config();
        const alerts = [];
        const index = new IndexPublisher(cfg, fakeChain({ index: null, diffs: {} }), three, async (key) => void alerts.push(key), () => Number(HEAD) * 1000, async () => {
            throw new Error('Quidax cngnngn ticker HTTP 503');
        });
        await index.sample();
        assert.equal(index.samples().length, 1, 'a blind tripwire is not a reason to stop the index');
        assert.deepEqual(alerts, ['peg-blind']);
        const status = JSON.parse(readFileSync(cfg.INDEX_STATUS_FILE, 'utf8'));
        assert.equal(status.pegGuardTripped, false);
        assert.equal(status.peg.state, 'blind');
    });
});
describe('pushIndexStatus', () => {
    const calls = [];
    const fakeFetch = (async (url, init) => {
        calls.push({ url: String(url), init: init ?? {} });
        return new Response(null, { status: 204 });
    });
    it('reports a good sample in the engine orientation with the token, and a failed one as blind', async () => {
        const cfg = { INDEX_STATUS_PUSH_URL: 'https://api.example/v1/internal/index-status', INDEX_STATUS_TOKEN: 't0k3n' };
        await pushIndexStatus(cfg, { atMs: 1_800_000_000_000, cngnPerUsdt: 1374 }, fakeFetch);
        await pushIndexStatus(cfg, { atMs: 1_800_000_060_000, cngnPerUsdt: null }, fakeFetch);
        assert.equal(calls.length, 2);
        const good = JSON.parse(String(calls[0].init.body));
        assert.equal(good.sample_ok, true);
        assert.equal(good.usdc_per_cngn, formatUnits(toUsdPerNgn(1374), 18));
        assert.equal(calls[0].init.headers['x-numo-index-token'], 't0k3n');
        const blind = JSON.parse(String(calls[1].init.body));
        assert.deepEqual(blind, { at_ms: 1_800_000_060_000, usdc_per_cngn: '', sample_ok: false });
    });
    it('does nothing without a push url, and survives a refused report', async () => {
        await pushIndexStatus({ INDEX_STATUS_PUSH_URL: '', INDEX_STATUS_TOKEN: '' }, { atMs: 1, cngnPerUsdt: 1374 }, fakeFetch);
        assert.equal(calls.length, 2);
        const refusing = (async () => new Response('no', { status: 401 }));
        await pushIndexStatus({ INDEX_STATUS_PUSH_URL: 'https://api.example/x', INDEX_STATUS_TOKEN: 'bad' }, { atMs: 1, cngnPerUsdt: 1374 }, refusing);
    });
});
