import assert from 'node:assert/strict';
import test from 'node:test';

import { buildApp } from './app.js';
import { SettlementCanary } from './canary.js';
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

function canaryWith(readContract: () => Promise<unknown>, accountIds = [15]) {
  return new SettlementCanary({
    rpcUrl: config.rpcUrl,
    chainId: config.chainId,
    manager: MANAGER,
    accountIds,
    intervalMs: 60_000,
    client: { readContract } as never,
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
      readContract: async () => {
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
  const canary = canaryWith(async (...args: unknown[]) => {
    seen.push((args[0] as { args: [bigint, boolean] }).args[0]);
    throw new Error('reverted');
  }, [15, 16]);

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
