import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { describe, it } from 'node:test';

import { keccak256, toHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { ContractChain } from './chain.js';
import { loadForwardConfig } from './forward-config.js';
import { StreamsPoster, signedReportSource, type StreamsReport } from './streams-poster.js';

const INDEX = '0x00000000000000000000000000000000000000A1' as Address;
const ADAPTER = '0x00000000000000000000000000000000000000AD' as Address;
const EURC: Hex = '0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb';
const USDC: Hex = '0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992';
const HEAD = 1_794_720_000n;

const config = loadForwardConfig({
  RPC_URL: 'http://127.0.0.1:8545',
  CHAIN_ID: '84532',
  RELAYER_KEY: keccak256(toHex('relayer')),
  FORWARD_SIGNER_KEY: keccak256(toHex('forward-signer')),
  DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
  INDEX_FEED: INDEX,
  FORWARD_FEED: '0x00000000000000000000000000000000000000A4',
  FUTURE_ASSET: '0x00000000000000000000000000000000000000F0',
  FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
  FUTURE_SUB_ID: '1796050800',
  CARRY: '0',
  FUTURE_VERSION: 'v3',
  BASE_SYMBOL: 'EURC',
  DATA_STREAMS_USERNAME: 'user',
  DATA_STREAMS_SECRET: 'secret',
  STREAMS_REFRESH_S: '20',
  FORWARD_TICK_MS: '10000',
});

function report(feed: Hex, at: bigint): StreamsReport {
  return { feedID: feed, observationsTimestamp: Number(at), fullReport: `0x${feed.slice(2, 10)}${at.toString(16)}` as Hex };
}

function run(state: { observed: [bigint, bigint]; failFetch?: boolean; failWrite?: boolean; maxAge?: bigint }) {
  const writes: { to: Address; fn: string; args: readonly unknown[] }[] = [];
  const reads: string[] = [];
  const alerts: string[] = [];
  const fetched: Hex[] = [];
  const chain = {
    signer: privateKeyToAccount(keccak256(toHex('forward-signer'))),
    relayer: privateKeyToAccount(keccak256(toHex('relayer'))),
    chainId: 84532,
    headTimestamp: async () => HEAD,
    read: async <T,>(address: Address, _abi: unknown, fn: string, args: readonly unknown[] = []): Promise<T> => {
      reads.push(`${address}.${fn}`);
      if (address === INDEX && fn === 'adapter') return ADAPTER as T;
      if (address === INDEX && fn === 'indexMaxAge') return (state.maxAge ?? 60n) as T;
      if (address === ADAPTER && fn === 'baseFeedId') return EURC as T;
      if (address === ADAPTER && fn === 'quoteFeedId') return USDC as T;
      if (address === ADAPTER && fn === 'latest') {
        const at = args[0] === EURC ? state.observed[0] : state.observed[1];
        return [10n ** 18n, at] as T;
      }
      throw new Error(`unexpected read ${address}.${fn}`);
    },
    write: async (to: Address, _abi: unknown, fn: string, args: readonly unknown[] = []) => {
      if (state.failWrite) throw new Error('postReports reverted');
      writes.push({ to, fn, args });
      return '0xabc';
    },
  } as unknown as ContractChain;
  const source = async (feed: Hex) => {
    fetched.push(feed);
    if (state.failFetch) throw new Error('Data Streams 503');
    return report(feed, HEAD - 1n);
  };
  const alert = async (key: string) => {
    alerts.push(key);
  };
  return { poster: new StreamsPoster(config, chain, alert, source), writes, reads, alerts, fetched, chain, alert, source };
}

describe('StreamsPoster', () => {
  it('does nothing while both stored reports are inside the refresh age', async () => {
    const { poster, writes, fetched } = run({ observed: [HEAD - 19n, HEAD - 5n] });
    assert.equal(await poster.tick(), 'fresh');
    assert.deepEqual(writes, []);
    assert.deepEqual(fetched, [], 'not even fetched');
  });

  it('posts both newest reports, base then quote, to the adapter the index feed names, once either is old', async () => {
    const { poster, writes, fetched } = run({ observed: [HEAD - 5n, HEAD - 20n] });
    assert.equal(await poster.tick(), 'posted');
    assert.deepEqual(fetched, [EURC, USDC]);
    assert.equal(writes.length, 1);
    assert.equal(writes[0].to, ADAPTER);
    assert.equal(writes[0].fn, 'postReports');
    assert.deepEqual(writes[0].args, [[report(EURC, HEAD - 1n).fullReport, report(USDC, HEAD - 1n).fullReport]]);
  });

  it('posts when nothing has ever been posted', async () => {
    const { poster } = run({ observed: [0n, 0n] });
    assert.equal(await poster.tick(), 'posted');
  });

  it('counts a report stamped ahead of the block as fresh, as EurcIndexFeed does', async () => {
    const { poster } = run({ observed: [HEAD + 2n, HEAD - 1n] });
    assert.equal(await poster.tick(), 'fresh');
  });

  it('alerts on a failed post, and also on a stale index once a report has aged past indexMaxAge', async () => {
    const young = run({ observed: [HEAD - 30n, HEAD - 30n], failFetch: true });
    assert.equal(await young.poster.tick(), 'failed');
    assert.deepEqual(young.alerts, ['streams-post-failed'], 'not stale yet: 30s of a 60s limit');

    const old = run({ observed: [HEAD - 5n, HEAD - 61n], failWrite: true });
    assert.equal(await old.poster.tick(), 'failed');
    assert.deepEqual(old.alerts, ['streams-post-failed', 'index-stale']);
  });

  it('reads its wiring once', async () => {
    const { poster, reads } = run({ observed: [HEAD, HEAD] });
    await poster.tick();
    await poster.tick();
    assert.equal(reads.filter((r) => r.endsWith('.adapter')).length, 1);
  });

  it('refuses a refresh and tick that could let a report age out after one failed post', async () => {
    const { chain, alert, source } = run({ observed: [HEAD, HEAD] });
    await new StreamsPoster(config, chain, alert, source).checkCadence(); // 20 + 2 x 10 = 40 <= 60
    const slow = { ...config, FORWARD_TICK_MS: 30_000 }; // 20 + 60 = 80 > 60
    await assert.rejects(new StreamsPoster(slow, chain, alert, source).checkCadence(), /must fit inside/);
  });
});

describe('signedReportSource', () => {
  it('signs GET <path> <sha256 of the empty body> <user> <ms timestamp> with the secret, and sends a plain user agent', async () => {
    let seen: { url: string; headers: Record<string, string> } | undefined;
    const fetchImpl = (async (url: string, init: { headers: Record<string, string> }) => {
      seen = { url, headers: init.headers };
      return new Response(JSON.stringify({ report: report(EURC, HEAD) }), { status: 200 });
    }) as unknown as typeof fetch;
    const got = await signedReportSource('https://api.example', 'alice', 's3cret', fetchImpl, () => 1_700_000_000_123)(EURC);
    assert.equal(got.feedID, EURC);
    const path = `/api/v1/reports/latest?feedID=${EURC}`;
    assert.equal(seen?.url, `https://api.example${path}`);
    const empty = createHash('sha256').update('').digest('hex');
    assert.equal(empty, 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    const expected = createHmac('sha256', 's3cret').update(`GET ${path} ${empty} alice 1700000000123`).digest('hex');
    assert.equal(seen?.headers['X-Authorization-Signature-SHA256'], expected);
    assert.equal(seen?.headers.Authorization, 'alice');
    assert.equal(seen?.headers['X-Authorization-Timestamp'], '1700000000123');
    assert.equal(seen?.headers['User-Agent'], 'data-streams-client/1.0');
  });

  it('refuses an error status, and a report for another feed', async () => {
    const failing = (async () => new Response('forbidden', { status: 403 })) as unknown as typeof fetch;
    await assert.rejects(signedReportSource('https://api.example', 'a', 'b', failing)(EURC), /Data Streams 403/);
    const wrong = (async () => new Response(JSON.stringify({ report: report(USDC, HEAD) }), { status: 200 })) as unknown as typeof fetch;
    await assert.rejects(signedReportSource('https://api.example', 'a', 'b', wrong)(EURC), /without a report for it/);
  });
});
