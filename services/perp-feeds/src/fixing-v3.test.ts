import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { keccak256, toHex, type Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { ContractChain } from './chain.js';
import { ExpiryKeeper } from './expiry-keeper.js';
import { FixingKeeperV3, currentWindow, fixingV3Complete, type FixingV3 } from './fixing-v3.js';
import { loadForwardConfig } from './forward-config.js';

const EXPIRY = 1_796_050_800n; // EURC-30NOV26 v3, 15:00 UTC
const WINDOW = 1_800n;
const GAP = 120n;
const DELAY = 3_600n;
const FUTURE = '0x00000000000000000000000000000000000000F0' as Address;

const config = loadForwardConfig({
  RPC_URL: 'http://127.0.0.1:8545',
  CHAIN_ID: '84532',
  RELAYER_KEY: keccak256(toHex('relayer')),
  FORWARD_SIGNER_KEY: keccak256(toHex('forward-signer')),
  DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
  INDEX_FEED: '0x00000000000000000000000000000000000000A1',
  FORWARD_FEED: '0x00000000000000000000000000000000000000A4',
  FUTURE_ASSET: FUTURE,
  FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
  FUTURE_SUB_ID: String(EXPIRY),
  CARRY: '0',
  FUTURE_VERSION: 'v3',
  BASE_SYMBOL: 'EURC',
  DATA_STREAMS_USERNAME: 'user',
  DATA_STREAMS_SECRET: 'secret',
  FIXING_SAMPLE_INTERVAL_MS: '20000',
});

const unopened: FixingV3 = {
  round: 0,
  windowStart: 0n,
  windowEnd: 0n,
  maxSampleGap: 0n,
  firstSampleTime: 0n,
  lastSampleTime: 0n,
  largestGap: 0n,
};

function window(round: number, start: bigint, samples: { first: bigint; last: bigint; largest: bigint } | null): FixingV3 {
  return {
    round,
    windowStart: start,
    windowEnd: start + WINDOW,
    maxSampleGap: GAP,
    firstSampleTime: samples?.first ?? 0n,
    lastSampleTime: samples?.last ?? 0n,
    largestGap: samples?.largest ?? 0n,
  };
}

function run(state: { head: bigint; fixing: FixingV3; settled?: boolean; failWrites?: Set<string> }) {
  const writes: string[] = [];
  const alerts: string[] = [];
  const chain = {
    signer: privateKeyToAccount(keccak256(toHex('forward-signer'))),
    relayer: privateKeyToAccount(keccak256(toHex('relayer'))),
    chainId: 84532,
    headTimestamp: async () => state.head,
    read: async <T,>(_address: Address, _abi: unknown, functionName: string): Promise<T> => {
      const values: Record<string, unknown> = {
        futureContracts: { listed: true, settled: state.settled ?? false, expiry: EXPIRY, lastTradeTime: EXPIRY - WINDOW },
        fixings: state.fixing,
        fixingWindow: WINDOW,
        maxSampleGap: GAP,
        recoveryDelay: DELAY,
      };
      if (!(functionName in values)) throw new Error(`unexpected read ${functionName}`);
      return values[functionName] as T;
    },
    write: async (_address: Address, _abi: unknown, functionName: string) => {
      if (state.failWrites?.has(functionName)) throw new Error(`${functionName} reverted`);
      writes.push(functionName);
      return '0xabc';
    },
  } as unknown as ContractChain;
  const alert = async (key: string) => {
    alerts.push(key);
  };
  return { keeper: new FixingKeeperV3(config, chain, alert), writes, alerts, chain, alert };
}

describe('fixingV3Complete mirrors FutureAsset._fixingComplete', () => {
  it('needs a first sample, and every gap including the closing one within the limit', () => {
    const start = EXPIRY - WINDOW;
    assert.equal(fixingV3Complete(unopened), false, 'not opened');
    assert.equal(fixingV3Complete(window(0, start, null)), false, 'opened, never sampled');
    assert.equal(fixingV3Complete(window(0, start, { first: start, last: EXPIRY, largest: GAP })), true, 'every gap at the limit');
    assert.equal(fixingV3Complete(window(0, start, { first: start, last: EXPIRY - GAP, largest: 20n })), true, 'closing gap at the limit');
    assert.equal(fixingV3Complete(window(0, start, { first: start, last: EXPIRY - GAP - 1n, largest: 20n })), false, 'closing gap over');
    assert.equal(fixingV3Complete(window(0, start, { first: start, last: EXPIRY, largest: GAP + 1n })), false, 'a gap over');
  });

  it('places round 0 at expiry - fixingWindow before it is opened', () => {
    assert.deepEqual(currentWindow(unopened, EXPIRY, WINDOW), { start: EXPIRY - WINDOW, end: EXPIRY });
    assert.deepEqual(currentWindow(window(2, EXPIRY + 9_000n, null), EXPIRY, WINDOW), { start: EXPIRY + 9_000n, end: EXPIRY + 9_000n + WINDOW });
  });
});

describe('FixingKeeperV3', () => {
  it('waits before the window', async () => {
    const { keeper, writes } = run({ head: EXPIRY - WINDOW - 1n, fixing: unopened });
    assert.equal(await keeper.tick(EXPIRY - WINDOW - 1n, EXPIRY), 'before-window');
    assert.deepEqual(writes, []);
  });

  it('samples at once when round 0 has not been opened, the first sample being a gap from the start', async () => {
    const { keeper, writes } = run({ head: EXPIRY - WINDOW, fixing: unopened });
    assert.equal(await keeper.tick(EXPIRY - WINDOW, EXPIRY), 'sampled');
    assert.deepEqual(writes, ['recordFixingSample']);
  });

  it('samples every interval, not every tick', async () => {
    const start = EXPIRY - WINDOW;
    const fixing = window(0, start, { first: start, last: start + 100n, largest: 20n });
    const early = run({ head: start + 119n, fixing });
    assert.equal(await early.keeper.tick(start + 119n, EXPIRY), 'sample-not-due');
    assert.deepEqual(early.writes, []);
    const due = run({ head: start + 120n, fixing });
    assert.equal(await due.keeper.tick(start + 120n, EXPIRY), 'sampled');
  });

  it('samples at the window end itself', async () => {
    const start = EXPIRY - WINDOW;
    const { keeper } = run({ head: EXPIRY, fixing: window(0, start, { first: start, last: EXPIRY - 20n, largest: 20n }) });
    assert.equal(await keeper.tick(EXPIRY, EXPIRY), 'sampled');
  });

  it('settles a complete window once it has ended', async () => {
    const start = EXPIRY - WINDOW;
    const { keeper, writes, alerts } = run({ head: EXPIRY + 1n, fixing: window(0, start, { first: start, last: EXPIRY, largest: 20n }) });
    assert.equal(await keeper.tick(EXPIRY + 1n, EXPIRY), 'fixed');
    assert.deepEqual(writes, ['fixSettlementFromIndex']);
    assert.deepEqual(alerts, []);
  });

  it('opens a recovery window, and alerts, when the window ended incomplete', async () => {
    const start = EXPIRY - WINDOW;
    const { keeper, writes, alerts } = run({ head: EXPIRY + 1n, fixing: window(0, start, { first: start, last: EXPIRY, largest: 300n }) });
    assert.equal(await keeper.tick(EXPIRY + 1n, EXPIRY), 'recovery-opened');
    assert.deepEqual(writes, ['openRecoveryWindow']);
    assert.deepEqual(alerts, ['fixing-recovery-opened']);
  });

  it('opens a recovery window for an original window never sampled at all', async () => {
    const { keeper, writes } = run({ head: EXPIRY + 1n, fixing: unopened });
    assert.equal(await keeper.tick(EXPIRY + 1n, EXPIRY), 'recovery-opened');
    assert.deepEqual(writes, ['openRecoveryWindow']);
  });

  it('waits for a recovery window to start, then samples it at once, then settles it', async () => {
    const start = EXPIRY + 1n + DELAY;
    const waiting = run({ head: start - 1n, fixing: window(1, start, null) });
    assert.equal(await waiting.keeper.tick(start - 1n, EXPIRY), 'before-window');
    const opening = run({ head: start, fixing: window(1, start, null) });
    assert.equal(await opening.keeper.tick(start, EXPIRY), 'sampled');
    const done = run({ head: start + WINDOW + 1n, fixing: window(1, start, { first: start, last: start + WINDOW, largest: 20n }) });
    assert.equal(await done.keeper.tick(start + WINDOW + 1n, EXPIRY), 'fixed');
  });

  it('opens another round when a recovery window breaks too', async () => {
    const start = EXPIRY + 1n + DELAY;
    const { keeper, writes } = run({ head: start + WINDOW + 1n, fixing: window(1, start, { first: start + 500n, last: start + WINDOW, largest: 500n }) });
    assert.equal(await keeper.tick(start + WINDOW + 1n, EXPIRY), 'recovery-opened');
    assert.deepEqual(writes, ['openRecoveryWindow']);
  });

  it('alerts on a failed sample and keeps going', async () => {
    const { keeper, alerts } = run({ head: EXPIRY - WINDOW, fixing: unopened, failWrites: new Set(['recordFixingSample']) });
    assert.equal(await keeper.tick(EXPIRY - WINDOW, EXPIRY), 'sample-failed');
    assert.deepEqual(alerts, ['fixing-sample-failed']);
  });

  it('alerts when the recovery window cannot be opened', async () => {
    const { keeper, alerts } = run({ head: EXPIRY + 1n, fixing: unopened, failWrites: new Set(['openRecoveryWindow']) });
    assert.equal(await keeper.tick(EXPIRY + 1n, EXPIRY), 'recovery-failed');
    assert.deepEqual(alerts, ['fixing-recovery-failed']);
  });

  it('refuses a sample interval over half the gap limit', async () => {
    const { chain, alert } = run({ head: 0n, fixing: unopened });
    await new FixingKeeperV3(config, chain, alert).checkSampleInterval();
    const slow = { ...config, FIXING_SAMPLE_INTERVAL_MS: 61_000 };
    await assert.rejects(new FixingKeeperV3(slow, chain, alert).checkSampleInterval(), /at most half/);
  });

  it('is what ExpiryKeeper runs for an unsettled v3 series', async () => {
    const { chain, alert, writes } = run({ head: EXPIRY + 1n, fixing: unopened });
    const expiry = new ExpiryKeeper(config, chain, alert);
    assert.equal(await expiry.tick(), 'recovery-opened', 'not the v2 fallback alert');
    assert.deepEqual(writes, ['openRecoveryWindow']);
  });
});

describe('forward config for v3', () => {
  it('requires Data Streams credentials', () => {
    const { DATA_STREAMS_USERNAME: _u, DATA_STREAMS_SECRET: _s, ...rest } = {
      RPC_URL: 'http://127.0.0.1:8545',
      CHAIN_ID: '84532',
      RELAYER_KEY: keccak256(toHex('relayer')),
      FORWARD_SIGNER_KEY: keccak256(toHex('forward-signer')),
      DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
      INDEX_FEED: '0x00000000000000000000000000000000000000A1',
      FORWARD_FEED: '0x00000000000000000000000000000000000000A4',
      FUTURE_ASSET: FUTURE,
      FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
      FUTURE_SUB_ID: String(EXPIRY),
      CARRY: '0',
      FUTURE_VERSION: 'v3',
      DATA_STREAMS_USERNAME: 'user',
      DATA_STREAMS_SECRET: 'secret',
    };
    assert.throws(() => loadForwardConfig(rest), /v3 needs DATA_STREAMS_USERNAME and DATA_STREAMS_SECRET/);
  });
});
