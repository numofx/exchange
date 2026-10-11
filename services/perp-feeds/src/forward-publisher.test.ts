import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { decodeAbiParameters, keccak256, toHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { ContractChain } from './chain.js';
import { loadForwardConfig } from './forward-config.js';
import { ForwardPublisher } from './forward-publisher.js';
import { invert, ONE } from './forward-targets.js';

const FUTURE = '0x00000000000000000000000000000000000000F0' as Address;
const FORWARD_FEED = '0x00000000000000000000000000000000000000F1' as Address;
const EXPIRY = 1_796_047_200n;
const LAST_TRADE = EXPIRY - 3_600n;
const INDEX = 1400n * ONE;

const config = loadForwardConfig({
  RPC_URL: 'http://127.0.0.1:8545',
  CHAIN_ID: '84532',
  RELAYER_KEY: keccak256(toHex('relayer')),
  FORWARD_SIGNER_KEY: keccak256(toHex('forward-signer')),
  DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
  INDEX_FEED: '0x00000000000000000000000000000000000000A1',
  FORWARD_FEED,
  FUTURE_ASSET: FUTURE,
  FUTURE_MANAGER: '0x00000000000000000000000000000000000000A2',
  SUB_ACCOUNTS: '0x00000000000000000000000000000000000000A3',
  FUTURE_SUB_ID: String(EXPIRY),
  CARRY: '0',
});

type State = {
  head: bigint;
  lastMarkTime: bigint;
  markPrice: bigint;
  settled: boolean;
  index: bigint | null;
  forwardFeed: Address;
  band: bigint;
};

function fakeChain(state: State) {
  const calls: string[] = [];
  const submitted: Hex[] = [];
  const chain: ContractChain = {
    signer: privateKeyToAccount(keccak256(toHex('forward-signer'))),
    relayer: privateKeyToAccount(keccak256(toHex('relayer'))),
    chainId: 84532,
    headTimestamp: async () => state.head,
    readIndex: async () => state.index,
    readDiffFeed: async () => null,
    submit: async (data) => {
      calls.push('submit');
      submitted.push(data);
      return '0xaa';
    },
    read: async <T,>(_address: Address, _abi: unknown, functionName: string): Promise<T> => {
      const values: Record<string, unknown> = {
        futureContracts: {
          listed: true,
          settled: state.settled,
          expiry: EXPIRY,
          lastTradeTime: LAST_TRADE,
          lastMarkTime: state.lastMarkTime,
          markPrice: state.markPrice,
          cumulativeVMPerContract: 0n,
        },
        minMarkInterval: 3_600n,
        maxMarkDeviation: ONE / 20n,
        markIndexBand: state.band,
        forwardFeed: state.forwardFeed,
      };
      return values[functionName] as T;
    },
    write: async (_address, _abi, functionName) => {
      calls.push(functionName);
      return '0xbb';
    },
  };
  return { chain, calls, submitted };
}

function base(overrides: Partial<State> = {}): State {
  return {
    head: EXPIRY - 30n * 86_400n,
    lastMarkTime: EXPIRY - 30n * 86_400n - 3_600n,
    markPrice: INDEX,
    settled: false,
    index: invert(INDEX),
    forwardFeed: FORWARD_FEED,
    band: ONE / 10n,
    ...overrides,
  };
}

function run(state: State, cfg = config) {
  const fake = fakeChain(state);
  const alerts: string[] = [];
  const publisher = new ForwardPublisher(cfg, fake.chain, async (key) => void alerts.push(key), async () => []);
  return { publisher, alerts, ...fake };
}

describe('forward publisher', () => {
  it('publishes the forward, then pulls the mark, in that order', async () => {
    const { publisher, calls, submitted } = run(base());
    assert.equal(await publisher.tick(), 'published');
    assert.deepEqual(calls, ['submit', 'pullMark']);

    // the relayed update is for the future's forward feed, and carries this expiry
    const [updates] = decodeAbiParameters(
      [{ type: 'tuple[]', components: [{ name: 'receiver', type: 'address' }, { name: 'data', type: 'bytes' }] }],
      submitted[0],
    );
    assert.equal(updates[0].receiver.toLowerCase(), FORWARD_FEED.toLowerCase());
    const [feedData] = decodeAbiParameters(
      [{ type: 'tuple', components: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }, { name: 'signers', type: 'address[]' }, { name: 'signatures', type: 'bytes[]' }] }],
      updates[0].data,
    );
    const [expiry] = decodeAbiParameters([{ type: 'uint64' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'int96' }, { type: 'uint64' }], feedData.data);
    assert.equal(expiry, EXPIRY);
    assert.equal(feedData.signers[0], privateKeyToAccount(keccak256(toHex('forward-signer'))).address, 'signed by the forward key');
  });

  it('waits out the contract minimum interval', async () => {
    const { publisher, calls } = run(base({ lastMarkTime: EXPIRY - 30n * 86_400n - 60n }));
    assert.equal(await publisher.tick(), 'waiting');
    assert.deepEqual(calls, []);
  });

  it('stops at last trade', async () => {
    const { publisher, calls } = run(base({ head: LAST_TRADE }));
    assert.equal(await publisher.tick(), 'closed');
    assert.deepEqual(calls, []);
  });

  it('stops once settled', async () => {
    const { publisher, calls } = run(base({ settled: true }));
    assert.equal(await publisher.tick(), 'settled');
    assert.deepEqual(calls, []);
  });

  it('alerts when the last mark is late, and still marks', async () => {
    const { publisher, alerts } = run(base({ lastMarkTime: EXPIRY - 31n * 86_400n }));
    assert.equal(await publisher.tick(), 'published');
    assert.ok(alerts.includes('forward-mark-late'));
  });

  it('refuses, and alerts, without an index', async () => {
    const { publisher, alerts, calls } = run(base({ index: null }));
    assert.equal(await publisher.tick(), 'no-index');
    assert.ok(alerts.includes('forward-no-index'));
    assert.deepEqual(calls, []);
  });

  it('refuses when the future reads a different forward feed', async () => {
    const { publisher, alerts, calls } = run(base({ forwardFeed: '0x00000000000000000000000000000000000000F2' }));
    assert.equal(await publisher.tick(), 'misconfigured');
    assert.ok(alerts.includes('forward-feed-mismatch'));
    assert.deepEqual(calls, []);
  });

  it('refuses, and alerts, when no single move reaches the band', async () => {
    const { publisher, alerts, calls } = run(base({ markPrice: (INDEX * 108n) / 100n, band: ONE / 100n }));
    assert.equal(await publisher.tick(), 'unreachable');
    assert.ok(alerts.includes('forward-unreachable'));
    assert.deepEqual(calls, []);
  });

  it('sends nothing in dry-run', async () => {
    const { publisher, calls } = run(base(), { ...config, DRY_RUN: true });
    assert.equal(await publisher.tick(), 'dry-run');
    assert.deepEqual(calls, []);
  });

  it('alerts when the pull reverts', async () => {
    const fake = fakeChain(base());
    fake.chain.write = async () => {
      throw new Error('pullMark reverted: 0xcc');
    };
    const alerts: string[] = [];
    const publisher = new ForwardPublisher(config, fake.chain, async (key) => void alerts.push(key), async () => []);
    assert.equal(await publisher.tick(), 'pull-failed');
    assert.ok(alerts.includes('forward-pull-failed'));
  });
});
