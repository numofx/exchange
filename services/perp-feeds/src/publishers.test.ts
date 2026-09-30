import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';

import type { RateProvider } from 'cngn-rate-picker';
import { keccak256, toHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { Chain } from './chain.js';
import { loadConfig } from './config.js';
import { encodeSpotData, encodeSpotDiffData } from './feed-data.js';
import { IndexPublisher } from './index-publisher.js';
import { toUsdPerNgn } from './index-aggregation.js';
import { MarkPublisher } from './mark-publisher.js';
import { toSpotDiff, type RestingOrder } from './mark-targets.js';

/**
 * The refresh path, end to end through each publisher: when a feed is republished because it is
 * getting old, the value signed is recomputed from fresh inputs through every guard, never the
 * value already on chain signed again.
 */

const E18 = 10n ** 18n;
const HEAD = 1_800_000_000n;
const INDEX = 720_000_000_000_000n;
const key = (label: string) => keccak256(toHex(label));

const feeds = {
  INDEX_FEED: '0x00000000000000000000000000000000000000a1',
  MARK_FEED: '0x00000000000000000000000000000000000000a2',
  IMPACT_ASK_FEED: '0x00000000000000000000000000000000000000a3',
  IMPACT_BID_FEED: '0x00000000000000000000000000000000000000a4',
} as const;

function config() {
  return loadConfig({
    RPC_URL: 'http://127.0.0.1:1',
    CHAIN_ID: '31337',
    FEED_SIGNER_KEY: key('perp-feeds-test-signer'),
    RELAYER_KEY: key('perp-feeds-test-relayer'),
    DATA_SUBMITTER: '0x00000000000000000000000000000000000000b1',
    PERP_ASSET: '0x00000000000000000000000000000000000000b2',
    INDEX_STATE_FILE: join(mkdtempSync(join(tmpdir(), 'perp-feeds-')), 'state.json'),
    ...feeds,
  });
}

type FakeChain = Chain & { submitted: Hex[] };

function fakeChain(state: {
  index: bigint | null;
  diffs: Record<string, { result: bigint; updatedAt: bigint } | null>;
}): FakeChain {
  const submitted: Hex[] = [];
  return {
    signer: privateKeyToAccount(key('perp-feeds-test-signer')),
    relayer: privateKeyToAccount(key('perp-feeds-test-relayer')),
    chainId: 31337,
    submitted,
    headTimestamp: async () => HEAD,
    readIndex: async () => state.index,
    readDiffFeed: async (feed: Address) => state.diffs[feed.toLowerCase()] ?? null,
    submit: async (data: Hex) => {
      submitted.push(data);
      return '0x01';
    },
  };
}

const quiet = async () => {};
const strip = (hex: Hex) => hex.slice(2);

describe('mark refresh', () => {
  // Every diff feed is at the index and 8 minutes old: past MARK_MAX_AGE_MS (7 min), no price move.
  const stale = () =>
    Object.fromEntries(
      [feeds.MARK_FEED, feeds.IMPACT_ASK_FEED, feeds.IMPACT_BID_FEED].map((feed) => [
        feed.toLowerCase(),
        { result: INDEX, updatedAt: HEAD - 480n },
      ]),
    );

  it('signs the target recomputed from the current book, not the value the feed already holds', async () => {
    const bid = (INDEX * 10_040n) / 10_000n;
    const ask = (INDEX * 10_060n) / 10_000n;
    const book: RestingOrder[] = [
      { side: 'buy', price: bid, remaining: (5_000n * E18 * E18) / bid },
      { side: 'sell', price: ask, remaining: (5_000n * E18 * E18) / ask },
    ];
    const chain = fakeChain({ index: INDEX, diffs: stale() });
    await new MarkPublisher(config(), chain, quiet, async () => book).publish();

    assert.equal(chain.submitted.length, 1);
    const newMark = (bid + ask) / 2n;
    assert.ok(chain.submitted[0]!.includes(strip(encodeSpotDiffData(toSpotDiff(newMark, INDEX)))));
    assert.ok(!chain.submitted[0]!.includes(strip(encodeSpotDiffData(0n))), 'the old zero diff was re-signed');
  });

  it('re-applies the basis clamp on refresh', async () => {
    // The book is 10% through the index; the refreshed mark is clamped to the 200bps band.
    const bid = (INDEX * 11_000n) / 10_000n;
    const ask = (INDEX * 11_010n) / 10_000n;
    const book: RestingOrder[] = [
      { side: 'buy', price: bid, remaining: (5_000n * E18 * E18) / bid },
      { side: 'sell', price: ask, remaining: (5_000n * E18 * E18) / ask },
    ];
    const chain = fakeChain({ index: INDEX, diffs: stale() });
    await new MarkPublisher(config(), chain, quiet, async () => book).publish();

    const clamped = (INDEX * 10_200n) / 10_000n;
    assert.ok(chain.submitted[0]!.includes(strip(encodeSpotDiffData(toSpotDiff(clamped, INDEX)))));
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

  function publisher(chain: Chain, samples: { price: number; at: number }[]) {
    const index = new IndexPublisher(config(), chain, [] as RateProvider[], quiet, () => nowMs);
    (index as unknown as { state: { samples: typeof samples; lastPublished: string | null } }).state = {
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
    assert.ok(chain.submitted[0]!.includes(strip(encodeSpotData(toUsdPerNgn(1380)))));
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
