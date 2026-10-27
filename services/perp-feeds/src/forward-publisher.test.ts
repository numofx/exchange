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
  FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
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
  minMarkInterval?: bigint;
  contractSize?: bigint;
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
        minMarkInterval: state.minMarkInterval ?? 3_600n,
        contractSize: state.contractSize ?? 1_000n * ONE,
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
  it('alerts at a last mark one second past the 2-hour threshold, not at exactly 2 hours', async () => {
    const head = EXPIRY - 30n * 86_400n;
    const onTime = run(base({ head, lastMarkTime: head - 7_200n }));
    assert.equal(await onTime.publisher.tick(), 'published');
    assert.ok(!onTime.alerts.includes('forward-mark-late'), 'exactly 2 hours is not late');

    const late = run(base({ head, lastMarkTime: head - 7_201n }));
    assert.equal(await late.publisher.tick(), 'published');
    assert.ok(late.alerts.includes('forward-mark-late'), '2 hours and a second is');
  });

  it('refuses at startup a late threshold an on-time mark would trip', async () => {
    // 2 hours against a 1-hour interval and a 1-minute tick: fine
    await run(base()).publisher.checkLateThreshold();
    // exactly interval + tick: an on-time mark seen one tick late would alert
    await assert.rejects(() => run(base(), { ...config, FORWARD_MARK_LATE_MS: 3_660_000 }).publisher.checkLateThreshold(), /must exceed/);
    // a contract whose interval is itself 2 hours
    await assert.rejects(() => run(base({ minMarkInterval: 7_200n })).publisher.checkLateThreshold(), /must exceed/);
  });

  it('alerts, and sends nothing, when the signer fails (KMS refusing or down)', async () => {
    const fake = fakeChain(base());
    fake.chain.signer = {
      ...fake.chain.signer,
      signTypedData: async () => {
        throw new Error('AccessDeniedException: not authorized to perform kms:Sign');
      },
    };
    const alerts: string[] = [];
    const publisher = new ForwardPublisher(config, fake.chain, async (key) => void alerts.push(key), async () => []);
    assert.equal(await publisher.tick(), 'sign-failed');
    assert.deepEqual(alerts, ['forward-sign-failed']);
    assert.deepEqual(fake.calls, []);
  });

  it('marks to carry, not to a dust book', async () => {
    const dust = [
      { side: 'buy' as const, price: (INDEX * 102n) / 100n, remaining: ONE / 1000n },
      { side: 'sell' as const, price: (INDEX * 103n) / 100n, remaining: ONE / 1000n },
    ];
    const fake = fakeChain(base());
    const publisher = new ForwardPublisher(config, fake.chain, async () => {}, async () => dust);
    const logs: string[] = [];
    const original = console.log;
    console.log = (line: string) => void logs.push(line);
    try {
      assert.equal(await publisher.tick(), 'published');
    } finally {
      console.log = original;
    }
    assert.ok(logs.some((line) => line.includes('(carry')), `marked to carry: ${logs.join(' | ')}`);
  });

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

describe('forward publisher, v2', () => {
  // a v2 series on a base other than cNGN: USDC per EURC, a 1,000 EURC contract, EUR at a forward premium
  const EURC_INDEX = 1_162_500_000_000_000_000n;
  const v2Config = { ...config, FUTURE_VERSION: 'v2' as const, BASE_SYMBOL: 'EURC', CARRY: -(15n * ONE) / 1000n };
  const v2State = (overrides: Partial<State> = {}) =>
    base({ markPrice: EURC_INDEX, index: EURC_INDEX, contractSize: 1_000n * ONE, ...overrides });

  function signedDiff(submitted: Hex): bigint {
    const [updates] = decodeAbiParameters(
      [{ type: 'tuple[]', components: [{ name: 'receiver', type: 'address' }, { name: 'data', type: 'bytes' }] }],
      submitted,
    );
    const [feedData] = decodeAbiParameters(
      [{ type: 'tuple', components: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }, { name: 'signers', type: 'address[]' }, { name: 'signatures', type: 'bytes[]' }] }],
      updates[0].data,
    );
    const [, , , diff] = decodeAbiParameters([{ type: 'uint64' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'int96' }, { type: 'uint64' }], feedData.data);
    return diff;
  }

  it('signs the forward less the index as is, uninverted: a premium on a negative carry', async () => {
    const { publisher, calls, submitted } = run(v2State(), v2Config);
    assert.equal(await publisher.tick(), 'published');
    assert.deepEqual(calls, ['submit', 'pullMark']);
    const diff = signedDiff(submitted[0]);
    assert.ok(diff > 0n, `EUR at a forward premium: diff ${diff}`);
    // 30 days at -1.5% is ~0.12%: a v1 inversion would have been a diff the size of the index
    assert.ok(diff * 100n < EURC_INDEX, `diff ${diff} is a fraction of the index`);
  });

  it('checks the contract is in the units of its version at startup', async () => {
    await run(v2State(), v2Config).publisher.checkUnits();
    await run(base()).publisher.checkUnits();
    // a v2 contract run as v1, and a v1 contract run as v2
    await assert.rejects(() => run(v2State()).publisher.checkUnits(), /FUTURE_VERSION=v1 does not match/);
    await assert.rejects(() => run(base(), v2Config).publisher.checkUnits(), /FUTURE_VERSION=v2 does not match/);
    // no index: not checked, not refused
    await run(v2State({ index: null }), { ...v2Config }).publisher.checkUnits();
  });
});
