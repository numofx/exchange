import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { keccak256, toHex, type Address } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { ContractChain } from './chain.js';
import { ExpiryKeeper, fixingComplete } from './expiry-keeper.js';
import { loadForwardConfig } from './forward-config.js';

const EXPIRY = 1_796_047_200n;
const WINDOW = 3_600n;
const GAP = 900n;
const FALLBACK = 86_400n;
const FUTURE = '0x00000000000000000000000000000000000000F0' as Address;
/** The ledger FutureAsset.subAccounts() reports: the only SubAccounts the keeper reads. */
const LEDGER = '0x00000000000000000000000000000000000000B1' as Address;
/** Accounts sit under two managers here, so the sweep must call each account's own. */
const MANAGER_OF = (id: bigint): Address =>
  (id % 2n === 0n ? '0x00000000000000000000000000000000000000C2' : '0x00000000000000000000000000000000000000C3') as Address;

const config = loadForwardConfig({
  RPC_URL: 'http://127.0.0.1:8545',
  CHAIN_ID: '84532',
  RELAYER_KEY: keccak256(toHex('relayer')),
  FORWARD_SIGNER_KEY: keccak256(toHex('forward-signer')),
  DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
  INDEX_FEED: '0x00000000000000000000000000000000000000A1',
  FORWARD_FEED: '0x00000000000000000000000000000000000000A4',
  FUTURE_ASSET: FUTURE,
  FUTURE_SUB_ID: String(EXPIRY),
  CARRY: '0',
  CLOSE_OUT_BATCH: '2',
});

type State = {
  head: bigint;
  settled: boolean;
  firstSampleTime: bigint;
  lastSampleTime: bigint;
  largestGap: bigint;
  balances: bigint[]; // by account id - 1
  failWrites?: Set<string>;
};

function run(state: State, cfg = config) {
  const writes: { fn: string; args: readonly unknown[]; to: Address }[] = [];
  const readsFrom: Address[] = [];
  const alerts: string[] = [];
  const chain: ContractChain = {
    signer: privateKeyToAccount(keccak256(toHex('forward-signer'))),
    relayer: privateKeyToAccount(keccak256(toHex('relayer'))),
    chainId: 84532,
    headTimestamp: async () => state.head,
    readIndex: async () => 1n,
    readDiffFeed: async () => null,
    submit: async () => '0x',
    read: async <T,>(address: Address, _abi: unknown, functionName: string, args: readonly unknown[] = []): Promise<T> => {
      readsFrom.push(address);
      // thunks: each answer is computed only for the function asked, since some need args the others lack
      const values: Record<string, () => unknown> = {
        futureContracts: () => ({ listed: true, settled: state.settled, expiry: EXPIRY, lastTradeTime: EXPIRY - WINDOW }),
        fixingWindow: () => WINDOW,
        maxSampleGap: () => GAP,
        fallbackDelay: () => FALLBACK,
        fixings: () => ({
          firstSampleTime: state.firstSampleTime,
          lastSampleTime: state.lastSampleTime,
          largestGap: state.largestGap,
          maxSampleGap: GAP,
        }),
        subAccounts: () => LEDGER,
        lastAccountId: () => BigInt(state.balances.length),
        getBalance: () => state.balances[Number(args[0] as bigint) - 1],
        manager: () => MANAGER_OF(args[0] as bigint),
      };
      return values[functionName]() as T;
    },
    write: async (address, _abi, functionName, args = []) => {
      if (state.failWrites?.has(functionName)) throw new Error(`${functionName} reverted`);
      writes.push({ fn: functionName, args, to: address });
      return '0x01';
    },
  };
  const keeper = new ExpiryKeeper(cfg, chain, async (key) => void alerts.push(key));
  return { keeper, writes, alerts, readsFrom };
}

function state(overrides: Partial<State> = {}): State {
  return { head: EXPIRY - WINDOW - 1n, settled: false, firstSampleTime: 0n, lastSampleTime: 0n, largestGap: 0n, balances: [], ...overrides };
}

describe('expiry keeper: fixing', () => {
  it('does nothing before the fixing window', async () => {
    const { keeper, writes } = run(state());
    assert.equal(await keeper.tick(), 'before-window');
    assert.deepEqual(writes, []);
  });

  it('records the first sample as soon as the window opens', async () => {
    const { keeper, writes } = run(state({ head: EXPIRY - WINDOW }));
    assert.equal(await keeper.tick(), 'sampled');
    assert.deepEqual(writes.map((w) => w.fn), ['recordFixingSample']);
  });

  it('samples again only once the interval has passed', async () => {
    const t = EXPIRY - WINDOW + 100n;
    assert.equal(await run(state({ head: t + 299n, firstSampleTime: t, lastSampleTime: t })).keeper.tick(), 'sample-not-due');
    assert.equal(await run(state({ head: t + 300n, firstSampleTime: t, lastSampleTime: t })).keeper.tick(), 'sampled');
  });

  it('alerts when a sample fails, and tries again next tick', async () => {
    const { keeper, alerts } = run(state({ head: EXPIRY - WINDOW, failWrites: new Set(['recordFixingSample']) }));
    assert.equal(await keeper.tick(), 'sample-failed');
    assert.ok(alerts.includes('fixing-sample-failed'));
  });

  it('fixes the settlement price after expiry when the fixing is complete', async () => {
    const { keeper, writes } = run(state({ head: EXPIRY, firstSampleTime: EXPIRY - WINDOW, lastSampleTime: EXPIRY - 60n, largestGap: 300n }));
    assert.equal(await keeper.tick(), 'fixed');
    assert.deepEqual(writes.map((w) => w.fn), ['fixSettlementFromIndex']);
  });

  it('alerts, and does not try, when the fixing is incomplete', async () => {
    const gap = state({ head: EXPIRY + 60n, firstSampleTime: EXPIRY - WINDOW, lastSampleTime: EXPIRY - 60n, largestGap: GAP + 1n });
    const { keeper, writes, alerts } = run(gap);
    assert.equal(await keeper.tick(), 'fixing-incomplete');
    assert.deepEqual(alerts, ['fixing-incomplete']);
    assert.deepEqual(writes, []);
  });

  it('alerts that the vault fallback is open once its delay has passed', async () => {
    const { keeper, alerts } = run(state({ head: EXPIRY + FALLBACK }));
    assert.equal(await keeper.tick(), 'fixing-incomplete');
    assert.deepEqual(alerts, ['fixing-fallback-due']);
  });

  it('refuses a sample interval that one failed sample could break', async () => {
    const tooSlow = loadForwardConfig({ ...process.env, ...envOf(config), FIXING_SAMPLE_INTERVAL_MS: String(Number(GAP) * 1000 / 2 + 1000) });
    await assert.rejects(() => run(state(), tooSlow).keeper.checkSampleInterval(), /at most half/);
    await run(state()).keeper.checkSampleInterval();
  });
});

describe('expiry keeper: close-out', () => {
  it('closes out every account still holding, in batches', async () => {
    const first = run(state({ settled: true, balances: [0n, 5n, -5n, 0n, 2n] }));
    assert.equal(await first.keeper.tick(), 'closing-out', 'three holders, a batch of two');
    assert.deepEqual(first.writes.map((w) => [w.fn, w.args[0]]), [['closeOutExpired', 2n], ['closeOutExpired', 3n]]);

    const last = run(state({ settled: true, balances: [0n, 0n, 0n, 0n, 2n] }));
    assert.equal(await last.keeper.tick(), 'closed-out');
    assert.deepEqual(last.writes.map((w) => w.args[0]), [5n]);
  });

  it('reads the ledger from the future and closes each account out on its own manager', async () => {
    const { keeper, writes, readsFrom } = run(state({ settled: true, balances: [0n, 5n, -5n] }));
    await keeper.tick();
    assert.deepEqual(writes.map((w) => [w.args[0], w.to]), [[2n, MANAGER_OF(2n)], [3n, MANAGER_OF(3n)]]);
    // nothing but the future and the ledger it names is ever read
    assert.deepEqual([...new Set(readsFrom)].sort(), [FUTURE, LEDGER].sort());
  });

  it('is done when nobody holds the series', async () => {
    const { keeper, writes } = run(state({ settled: true, balances: [0n, 0n] }));
    assert.equal(await keeper.tick(), 'done');
    assert.deepEqual(writes, []);
  });

  it('alerts on a close-out that fails and carries on with the rest', async () => {
    const { keeper, alerts } = run(state({ settled: true, balances: [1n], failWrites: new Set(['closeOutExpired']) }));
    assert.equal(await keeper.tick(), 'closing-out');
    assert.deepEqual(alerts, ['close-out-failed-1']);
  });
});

describe('fixing completeness, as the contract decides it', () => {
  const base = { firstSampleTime: EXPIRY - WINDOW, lastSampleTime: EXPIRY - 60n, largestGap: 300n, maxSampleGap: GAP };
  it('is complete with every gap inside the limit', () => assert.equal(fixingComplete(base, EXPIRY), true));
  it('is not with no samples', () => assert.equal(fixingComplete({ ...base, firstSampleTime: 0n }, EXPIRY), false));
  it('is not with a gap over the limit', () => assert.equal(fixingComplete({ ...base, largestGap: GAP + 1n }, EXPIRY), false));
  it('is not when the window ends unsampled', () =>
    assert.equal(fixingComplete({ ...base, lastSampleTime: EXPIRY - GAP - 1n }, EXPIRY), false));
});

function envOf(cfg: typeof config): Record<string, string> {
  return {
    RPC_URL: cfg.RPC_URL,
    CHAIN_ID: String(cfg.CHAIN_ID),
    RELAYER_KEY: cfg.RELAYER_KEY,
    FORWARD_SIGNER_KEY: cfg.FORWARD_SIGNER_KEY!,
    DATA_SUBMITTER: cfg.DATA_SUBMITTER,
    INDEX_FEED: cfg.INDEX_FEED,
    FORWARD_FEED: cfg.FORWARD_FEED,
    FUTURE_ASSET: cfg.FUTURE_ASSET,
    FUTURE_SUB_ID: String(cfg.FUTURE_SUB_ID),
    CARRY: String(cfg.CARRY),
  };
}
