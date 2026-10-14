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
/** The MarginEngine, and what it names for the VM pool: its account, the cash, the cNGN escrow, the spot feed. */
const ENGINE = '0x00000000000000000000000000000000000000E9' as Address;
const POOL = 31n;
const CASH = '0x00000000000000000000000000000000000000CA' as Address;
const ESCROW = '0x00000000000000000000000000000000000000CE' as Address;
const SPOT_FEED = '0x00000000000000000000000000000000000000F5' as Address;
const ONE = 10n ** 18n;
/** USDC per cNGN, 18dp: 0.0007. */
const SPOT = 7n * 10n ** 14n;
const cngn = (n: number) => BigInt(n) * ONE;
const usd = (n: number) => BigInt(Math.round(n * 100)) * 10n ** 16n;
/** Accounts sit under two managers here, so a settlement or close-out must call each account's own. */
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
  FUTURE_MANAGER: ENGINE,
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
  pending?: bigint[]; // VM getPendingVM reports, by account id - 1
  cngnHeld?: bigint[]; // each account's cNGN escrow balance, by account id - 1
  pool?: { cash: bigint; cngn: bigint }; // the VM pool's USDC cash (18dp USD) and cNGN
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
        getBalance: () => balanceOf(state, args[0] as bigint, args[1] as Address),
        accId: () => POOL,
        cashAsset: () => CASH,
        assetDetails: () => ({ isWhitelisted: true, assetType: 4, marketId: 1n }),
        assetMap: () => ESCROW,
        getMarketFeeds: () => [SPOT_FEED, '0x0000000000000000000000000000000000000000', '0x0000000000000000000000000000000000000000'],
        getSpot: () => [SPOT, ONE],
        manager: () => MANAGER_OF(args[0] as bigint),
        getPendingVM: () => state.pending?.[Number(args[0] as bigint) - 1] ?? 0n,
      };
      return values[functionName]() as T;
    },
    write: async (address, _abi, functionName, args = []) => {
      if (state.failWrites?.has(functionName)) throw new Error(`${functionName} reverted`);
      writes.push({ fn: functionName, args, to: address });
      if (functionName === 'settleAccount') settle(state, args[0] as bigint);
      return '0x01';
    },
  };
  const keeper = new ExpiryKeeper(cfg, chain, async (key) => void alerts.push(key));
  return { keeper, writes, alerts, readsFrom };
}

function balanceOf(state: State, id: bigint, asset: Address): bigint {
  const i = Number(id) - 1;
  if (asset === FUTURE) return state.balances[i];
  if (id === POOL) return asset === CASH ? (state.pool?.cash ?? 0n) : (state.pool?.cngn ?? 0n);
  return asset === ESCROW ? (state.cngnHeld?.[i] ?? 0n) : 0n;
}

/** What MarginEngine.settleAccount does to a loser and the pool: its cNGN first, the rest in cash at the spot feed. */
function settle(state: State, id: bigint) {
  const i = Number(id) - 1;
  const vm = state.pending?.[i] ?? 0n;
  if (vm >= 0n || !state.pending) return;
  const held = state.cngnHeld?.[i] ?? 0n;
  const owed = -vm;
  const fromCngn = owed < held ? owed : held;
  state.pool ??= { cash: 0n, cngn: 0n };
  state.pool.cngn += fromCngn;
  state.pool.cash += ((owed - fromCngn) * SPOT) / ONE;
  if (state.cngnHeld) state.cngnHeld[i] = held - fromCngn;
  state.pending[i] = 0n;
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

describe('expiry keeper: VM pool deficit', () => {
  it('settles nobody while the pool is at or above zero', async () => {
    const { keeper, writes, alerts } = run(state({ balances: [1n, -1n], pending: [cngn(5_000), cngn(-5_000)], pool: { cash: 0n, cngn: 0n } }));
    assert.deepEqual(await keeper.coverPoolDeficit(), { netUsd: 0n, settled: 0, failed: 0, stranded: false });
    assert.deepEqual(writes, []);
    assert.deepEqual(alerts, []);
  });

  it('counts the pool\'s cNGN at the spot feed: cNGN covering a USDC debt is no deficit', async () => {
    // -$7 in cash, 10,000 cNGN at 0.0007 = $7: net zero, though the cash alone is below it
    const { keeper, writes } = run(state({ balances: [-1n], pending: [cngn(-9_000)], pool: { cash: usd(-7), cngn: cngn(10_000) } }));
    assert.equal((await keeper.coverPoolDeficit()).settled, 0);
    assert.deepEqual(writes, []);
  });

  it('settles the losers paying the most USDC first, and stops once the net is back', async () => {
    // 1: owes 10,000 cNGN, holds none ($7 in USDC). 2: owes 20,000, holds 20,000 ($0). 3: owes 15,000, holds 5,000
    // ($7, and owes more than 1, so first on the tie). 4: a winner. Pool: -$5. Settling 3 alone brings in $7 and
    // 5,000 cNGN ($3.50): net $5.50.
    const s = state({
      balances: [1n, 2n, 1n, -4n],
      pending: [cngn(-10_000), cngn(-20_000), cngn(-15_000), cngn(45_000)],
      cngnHeld: [0n, cngn(20_000), cngn(5_000), 0n],
      pool: { cash: usd(-5), cngn: 0n },
    });
    const { keeper, writes } = run(s);
    const outcome = await keeper.coverPoolDeficit();
    assert.deepEqual(writes.map((w) => [w.fn, w.args[0]]), [['settleAccount', 3n]]);
    assert.deepEqual(outcome, { netUsd: usd(5.5), settled: 1, failed: 0, stranded: false });
  });

  it('settles on to the losers paying in cNGN when the USDC payers are not enough, never a winner', async () => {
    const s = state({
      balances: [1n, 2n, -3n],
      pending: [cngn(-10_000), cngn(-20_000), cngn(30_000)],
      cngnHeld: [0n, cngn(20_000), 0n],
      pool: { cash: usd(-20), cngn: 0n },
    });
    const { keeper, writes } = run(s);
    const outcome = await keeper.coverPoolDeficit();
    // $7 from 1 in USDC, then 20,000 cNGN ($14) from 2: net $1
    assert.deepEqual(writes.map((w) => w.args[0]), [1n, 2n]);
    assert.equal(outcome.netUsd, usd(1));
  });

  it('settles at most SETTLE_PER_TICK a tick, and the next tick carries on', async () => {
    const capped = loadForwardConfig({ ...envOf(config), SETTLE_PER_TICK: '2' });
    const s = state({
      balances: [1n, 1n, 1n, 1n, -4n],
      pending: [cngn(-10_000), cngn(-10_000), cngn(-10_000), cngn(-10_000), cngn(40_000)],
      pool: { cash: usd(-28), cngn: 0n },
    });
    const first = run(s, capped);
    assert.deepEqual(await first.keeper.coverPoolDeficit(), { netUsd: usd(-14), settled: 2, failed: 0, stranded: false });
    const second = run(s, capped);
    assert.deepEqual(await second.keeper.coverPoolDeficit(), { netUsd: 0n, settled: 2, failed: 0, stranded: false });
    assert.deepEqual([...first.writes, ...second.writes].map((w) => w.args[0]), [1n, 2n, 3n, 4n]);
  });

  it('alerts once when no loser is left to settle, and again only after the net has recovered', async () => {
    const s = state({ balances: [1n], pending: [cngn(10_000)], pool: { cash: usd(-3), cngn: 0n } });
    const { keeper, writes, alerts } = run(s);
    assert.equal((await keeper.coverPoolDeficit()).stranded, true);
    assert.equal((await keeper.coverPoolDeficit()).stranded, true);
    assert.deepEqual(alerts, ['future-pool-deficit-stranded'], 'once per episode, not every tick');
    s.pool = { cash: 0n, cngn: 0n }; // topped up
    assert.equal((await keeper.coverPoolDeficit()).stranded, false);
    s.pool = { cash: usd(-2), cngn: 0n };
    await keeper.coverPoolDeficit();
    assert.deepEqual(alerts, ['future-pool-deficit-stranded', 'future-pool-deficit-stranded']);
    assert.deepEqual(writes, []);
  });

  it("settles each loser on its own manager and alerts a failed settlement, carrying on with the rest", async () => {
    const s = state({ balances: [1n, 1n], pending: [cngn(-10_000), cngn(-5_000)], pool: { cash: usd(-20), cngn: 0n } });
    const ok = run(s);
    await ok.keeper.coverPoolDeficit();
    assert.deepEqual(ok.writes.map((w) => [w.args[0], w.to]), [[1n, MANAGER_OF(1n)], [2n, MANAGER_OF(2n)]]);

    const failing = run(state({ balances: [1n, 1n], pending: [cngn(-10_000), cngn(-5_000)], pool: { cash: usd(-20), cngn: 0n }, failWrites: new Set(['settleAccount']) }));
    assert.deepEqual(await failing.keeper.coverPoolDeficit(), { netUsd: usd(-20), settled: 0, failed: 2, stranded: false });
    assert.deepEqual(failing.alerts, ['settle-failed-1', 'settle-failed-2']);
  });

  it('treats a net within $1 of zero as covered: rounding and interest dust are not a deficit, nor an alert', async () => {
    const dust = run(state({ balances: [-1n, 1n], pending: [cngn(-9_000), cngn(9_000)], pool: { cash: -usd(1), cngn: 0n } }));
    assert.equal((await dust.keeper.coverPoolDeficit()).settled, 0);
    assert.deepEqual([dust.writes, dust.alerts], [[], []]);
    const past = run(state({ balances: [1n], pending: [cngn(9_000)], pool: { cash: -usd(1) - 1n, cngn: 0n } }));
    assert.equal((await past.keeper.coverPoolDeficit()).stranded, true);
  });

  it('leaves a settled series to close-out', async () => {
    const { keeper, writes, readsFrom } = run(state({ settled: true, balances: [1n], pending: [cngn(-1)], pool: { cash: usd(-5), cngn: 0n } }));
    assert.deepEqual(await keeper.coverPoolDeficit(), { netUsd: null, settled: 0, failed: 0, stranded: false });
    assert.deepEqual(writes, []);
    assert.deepEqual([...new Set(readsFrom)], [FUTURE]);
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
    FUTURE_MANAGER: cfg.FUTURE_MANAGER,
    FUTURE_SUB_ID: String(cfg.FUTURE_SUB_ID),
    CARRY: String(cfg.CARRY),
  };
}
