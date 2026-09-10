import assert from 'node:assert/strict';
import test from 'node:test';

import { buildApp } from './app.js';
import { SettlementCanary, to18 } from './canary.js';
import type { AppConfig } from './config.js';
import type { ExecuteMatchResponse } from './types.js';

const MANAGER = '0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b' as const;

const config: AppConfig = {
  port: 8081,
  host: '127.0.0.1',
  rpcUrl: 'http://127.0.0.1:0',
  privateKey: `0x${'11'.repeat(32)}`,
  chainId: 8453,
  executorAddress: '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A',
  dryRun: true,
  waitForReceipt: false,
  receiptTimeoutMs: 60_000,
};

const CASH_ = '0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6';
const USDC_ = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const CNGN_ = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F';

/**
 * A chain where every solvency invariant holds. The margin-focused tests below delegate to this
 * for anything that is not getMargin, so a failure there means what the test name says rather
 * than "the fixture did not stub cashAsset".
 */
function healthyInvariantRead(a: { address: string; functionName: string }): unknown {
  switch (a.functionName) {
    case 'cashAsset': return CASH_;
    case 'wrappedAsset': return a.address === CASH_ ? USDC_ : CNGN_;
    case 'decimals': return 6;
    case 'balanceOf': return a.address === USDC_ ? 5_000_000n : 5_000_000_000n;
    case 'totalSupply': return 5_000_000_000_000_000_000n;
    case 'totalBorrow': return 0n;
    case 'netSettledCash': return 0n;
    case 'totalPosition': return 5_000_000_000_000_000_000_000n;
    default: throw new Error(`unexpected call ${a.functionName}`);
  }
}

function canaryWith(readContract: () => Promise<unknown>, accountIds = [15]) {
  return new SettlementCanary({
    rpcUrl: config.rpcUrl,
    chainId: config.chainId,
    manager: MANAGER,
    accountIds,
    intervalMs: 60_000,
    client: {
      getLogs: async () => [{ args: { asset: '0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493' } }],
      readContract: async (a: { address: string; functionName: string }) =>
        a.functionName === 'getMargin' ? readContract() : healthyInvariantRead(a),
    } as never,
  });
}

const CASH = '0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6';
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const WRAPPER = '0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493';
const CNGN = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F';

/** A chain where every invariant holds, overridable per-call to break exactly one of them. */
function invariantCanary(overrides: Record<string, bigint> = {}, wrappers = [WRAPPER]) {
  const v = {
    cashHeld: 5_000_000n, // 5 USDC at 6dp
    cashSupply: 5_000_000_000_000_000_000n, // 5 cash at 18dp
    cashBorrow: 0n,
    cashSettled: 0n,
    wrapperHeld: 5_000_000_000n, // 5000 cNGN at 6dp
    wrapperCredited: 5_000_000_000_000_000_000_000n, // 5000 at 18dp
    ...overrides,
  };
  return new SettlementCanary({
    rpcUrl: config.rpcUrl,
    chainId: config.chainId,
    manager: MANAGER,
    accountIds: [15],
    intervalMs: 60_000,
    announceOnStart: false,
    client: {
      getLogs: async () => wrappers.map((asset) => ({ args: { asset } })),
      readContract: async (a: { address: string; functionName: string }) => {
        switch (a.functionName) {
          case 'getMargin': return 0n;
          case 'cashAsset': return CASH;
          case 'wrappedAsset': return a.address === CASH ? USDC : CNGN;
          case 'decimals': return 6;
          case 'balanceOf': return a.address === USDC ? v.cashHeld : v.wrapperHeld;
          case 'totalSupply': return v.cashSupply;
          case 'totalBorrow': return v.cashBorrow;
          case 'netSettledCash': return v.cashSettled;
          case 'totalPosition': return v.wrapperCredited;
          default: throw new Error(`unexpected call ${a.functionName}`);
        }
      },
    } as never,
  });
}

type Sent = { url: string; text: string };

function alertingCanary(
  healthy: () => boolean,
  opts: { repeatAfter?: number; failPost?: boolean; announceOnStart?: boolean } = {},
) {
  const sent: Sent[] = [];
  const canary = new SettlementCanary({
    rpcUrl: config.rpcUrl,
    chainId: config.chainId,
    manager: MANAGER,
    accountIds: [15],
    intervalMs: 60_000,
    alertWebhookUrl: 'https://hooks.example.invalid/abc',
    alertRepeatAfterChecks: opts.repeatAfter ?? 30,
    announceOnStart: opts.announceOnStart ?? false,
    client: {
      getLogs: async () => [{ args: { asset: '0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493' } }],
      readContract: async (a: { address: string; functionName: string }) => {
        if (a.functionName !== 'getMargin') return healthyInvariantRead(a);
        if (!healthy()) throw new Error('reverted: BLF_DataTooOld()');
        return 0n;
      },
    } as never,
    postAlert: async (url: string, text: string) => {
      if (opts.failPost) throw new Error('webhook 500');
      sent.push({ url, text });
    },
  });
  return { canary, sent };
}

test('a healthy manager reports ok with no failures', async () => {
  const snapshot = await canaryWith(async () => 0n).check();

  assert.equal(snapshot.ok, true);
  assert.deepEqual(snapshot.failures, []);
  assert.equal(snapshot.consecutive_failures, 0);
  assert.equal(snapshot.manager, MANAGER);
  assert.ok(snapshot.checked_at);
});

test('a reverting getMargin is reported as a failure, with the selector kept', async () => {
  const canary = canaryWith(async () => {
    throw new Error(
      'The contract function "getMargin" reverted.\n\nError: BLF_DataTooOld()\n0x1141796d\nmore noise',
    );
  });

  const snapshot = await canary.check();
  assert.equal(snapshot.ok, false);
  assert.equal(snapshot.failures.length, 1);
  assert.equal(snapshot.failures[0]!.account_id, 15);
  assert.match(snapshot.failures[0]!.error, /getMargin|BLF_DataTooOld|0x1141796d/);
});

test('consecutive_failures counts checks and resets on recovery', async () => {
  let healthy = false;
  const canary = canaryWith(async () => {
    if (!healthy) throw new Error('reverted');
    return 0n;
  });

  await canary.check();
  await canary.check();
  assert.equal(canary.snapshot().consecutive_failures, 2);

  healthy = true;
  await canary.check();
  assert.equal(canary.snapshot().ok, true);
  assert.equal(canary.snapshot().consecutive_failures, 0);
});

test('every configured account is checked, not just the first', async () => {
  const seen: bigint[] = [];
  const canary = new SettlementCanary({
    rpcUrl: config.rpcUrl,
    chainId: config.chainId,
    manager: MANAGER,
    accountIds: [15, 16],
    intervalMs: 60_000,
    client: {
      getLogs: async () => [],
      readContract: async (a: { address: string; functionName: string; args?: unknown[] }) => {
        if (a.functionName !== 'getMargin') return healthyInvariantRead(a);
        seen.push((a.args as [bigint, boolean])[0]);
        throw new Error('reverted');
      },
    } as never,
  });

  const snapshot = await canary.check();
  assert.deepEqual(seen, [15n, 16n]);
  assert.deepEqual(snapshot.failures.map((f) => f.account_id), [15, 16]);
});

test('ok is null before the first check, so unknown never reads as healthy', () => {
  assert.equal(canaryWith(async () => 0n).snapshot().ok, null);
});

test('/healthz reports the canary but still returns 200 when it is failing', async () => {
  const canary = canaryWith(async () => {
    throw new Error('reverted');
  });
  await canary.check();

  const app = buildApp({
    config,
    executor: {
      execute: async (): Promise<ExecuteMatchResponse> => ({ accepted: true, tx_hash: 'dry-run' }),
    },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
    canary,
  });

  const response = await app.inject({ method: 'GET', url: '/healthz' });
  // 200 is the decision, not an oversight: replacing this container does not refresh an oracle.
  assert.equal(response.statusCode, 200);
  assert.equal(response.json().settlement_canary.ok, false);

  await app.close();
});

test('a failure sends exactly one alert, not one per check', async () => {
  const { canary, sent } = alertingCanary(() => false);

  await canary.check();
  await canary.check();
  await canary.check();

  assert.equal(sent.length, 1, 'edge-triggered: an alert every interval is the same as none');
  assert.match(sent[0]!.text, /NUMO SETTLEMENT HALTED/);
  assert.match(sent[0]!.text, /BLF_DataTooOld/);
  assert.match(sent[0]!.text, /subaccount 15/);
});

test('recovery sends a second alert so silence is never ambiguous', async () => {
  let healthy = false;
  const { canary, sent } = alertingCanary(() => healthy);

  await canary.check();
  healthy = true;
  await canary.check();

  assert.equal(sent.length, 2);
  assert.match(sent[1]!.text, /RECOVERED/);
});

test('a sustained outage re-alerts, so one dropped webhook is not silence forever', async () => {
  const { canary, sent } = alertingCanary(() => false, { repeatAfter: 3 });

  for (let i = 0; i < 7; i++) await canary.check();

  // checks 1 (broke), 3 and 6 (repeats)
  assert.equal(sent.length, 3);
});

test('a webhook that is down does not stop the canary checking', async () => {
  const { canary, sent } = alertingCanary(() => false, { failPost: true });

  const snapshot = await canary.check();

  assert.equal(sent.length, 0);
  assert.equal(snapshot.ok, false, 'the check itself still completed and recorded the failure');
});

test('no webhook configured means no alert attempt and no crash', async () => {
  const canary = canaryWith(async () => {
    throw new Error('reverted');
  });
  const snapshot = await canary.check();
  assert.equal(snapshot.ok, false);
});

// Found by a production drill: a canary failure fixed by a redeploy produced no recovery
// message at all, because recovery is a within-process transition and the replacement process
// starts with ok = null. The operator saw HALTED then silence. Since redeploying IS the usual
// repair, that gap swallowed the common case.
test('a healthy start-up announces, so a redeploy-shaped recovery is never silent', async () => {
  const { canary, sent } = alertingCanary(() => true, { announceOnStart: true });

  await canary.check();

  assert.equal(sent.length, 1);
  assert.match(sent[0]!.text, /CANARY STARTED/);
  assert.match(sent[0]!.text, /subaccount\(s\) 15/);
});

test('start-up announcement happens once, not on every subsequent healthy check', async () => {
  const { canary, sent } = alertingCanary(() => true, { announceOnStart: true });

  await canary.check();
  await canary.check();
  await canary.check();

  assert.equal(sent.length, 1);
});

test('a failing start-up sends the halt alert, not the start-up notice', async () => {
  const { canary, sent } = alertingCanary(() => false, { announceOnStart: true });

  await canary.check();

  assert.equal(sent.length, 1);
  assert.match(sent[0]!.text, /SETTLEMENT HALTED/);
});

// 6dp tokens against 18dp ledgers: comparing raw numbers would make a fully-backed wrapper
// look 1e12 short, so the scaling IS the check.
test('to18 restates a 6dp balance at ledger scale', () => {
  assert.equal(to18(5_000_000_000n, 6), 5_000_000_000_000_000_000_000n);
  assert.equal(to18(1n, 18), 1n);
  assert.throws(() => to18(1n, 24), /refusing to round down/);
});

test('a fully backed venue reports ok with no invariant failures', async () => {
  const snapshot = await invariantCanary().check();
  assert.equal(snapshot.ok, true);
  assert.deepEqual(snapshot.invariant_failures, []);
});

test('cash held below cash supply is caught', async () => {
  const snapshot = await invariantCanary({ cashHeld: 2n }).check();
  assert.equal(snapshot.ok, false);
  assert.match(snapshot.invariant_failures.join(' '), /UNDER-BACKED/);
});

test('manager-printed cash is caught even when the balance looks fine', async () => {
  // The exact live shape: netSettledCash non-zero means cash exists that no deposit put there.
  const snapshot = await invariantCanary({ cashSettled: 1_000_000_000_000_000_000n }).check();
  assert.equal(snapshot.ok, false);
  assert.match(snapshot.invariant_failures.join(' '), /netSettledCash/);
});

test('borrowed cash is caught', async () => {
  const snapshot = await invariantCanary({ cashBorrow: 1n }).check();
  assert.equal(snapshot.ok, false);
  assert.match(snapshot.invariant_failures.join(' '), /totalBorrow/);
});

// Tokens sent straight to the wrapper, bypassing deposit(): balance moves, credited position
// does not. Verified against a real Base fork as well as here.
test('a wrapper holding more than it credited is caught', async () => {
  const snapshot = await invariantCanary({ wrapperHeld: 5_250_000_000n }).check();
  assert.equal(snapshot.ok, false);
  assert.match(snapshot.invariant_failures.join(' '), /BACKING MISMATCH/);
  assert.match(snapshot.invariant_failures.join(' '), /without deposit\(\)/);
});

test('a wrapper crediting more than it holds is caught', async () => {
  const snapshot = await invariantCanary({ wrapperHeld: 1n }).check();
  assert.equal(snapshot.ok, false);
  assert.match(snapshot.invariant_failures.join(' '), /BACKING MISMATCH/);
});

test('a backing failure alerts under its own headline, not the halt one', async () => {
  const sent: string[] = [];
  const canary = invariantCanary({ wrapperHeld: 5_250_000_000n });
  (canary as unknown as { options: Record<string, unknown> }).options.alertWebhookUrl = 'https://x.invalid';
  (canary as unknown as { postAlert: unknown }).postAlert = async (_u: string, t: string) => {
    sent.push(t);
  };

  await canary.check();

  assert.equal(sent.length, 1);
  assert.match(sent[0]!, /COLLATERAL BACKING FAILURE/);
  assert.doesNotMatch(sent[0]!, /SETTLEMENT HALTED/);
});

test('/healthz reports the canary as disabled when none is wired', async () => {
  const app = buildApp({
    config,
    executor: {
      execute: async (): Promise<ExecuteMatchResponse> => ({ accepted: true, tx_hash: 'dry-run' }),
    },
    matchingAddress: '0x00000000000000000000000000000000000000aa',
    tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
  });

  const body = (await app.inject({ method: 'GET', url: '/healthz' })).json();
  assert.equal(body.settlement_canary.enabled, false);
  assert.equal(body.settlement_canary.ok, null);

  await app.close();
});
