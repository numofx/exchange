import test from 'node:test';
import assert from 'node:assert/strict';

import type { Config } from './config.js';
import { runCommand, type CliDeps } from './cli.js';
import type { Snapshot } from './quote.js';
import { CNGN_ESCROW, USDC_ESCROW } from './venue.js';

const config = {
  BASE_RPC_URL: 'http://127.0.0.1:1',
  REBALANCE_KMS_KEY_ID: 'alias/does-not-exist',
  INDEXER_URL: 'http://127.0.0.1:1',
  COPROCESSOR_URL: 'ws://127.0.0.1:1',
  MM_SUBACCOUNT_ID: 15n,
  MAX_SNAPSHOT_AGE_SECONDS: 1800,
  SOLVER_FEE: 35_000n,
  DEADLINE_BLOCKS: 120n,
  AUCTION_MS: 30_000,
  CNGN_MIN_SHARE: 0.35,
  CNGN_FLOOR_USD: 100,
  HALT_NET_INVENTORY_USD: 800,
  bundlerUrl: 'http://127.0.0.1:1',
} as unknown as Config;

/** 18dp, as SubAccounts reports. */
const ledger = (units: number) => BigInt(Math.round(units * 1e6)) * 10n ** 12n;

function snapshot(): Snapshot {
  return {
    commitment: '0xabc',
    standardAmount: 1_000_000_000n,
    medianPrice: 1_368_315_500_000n,
    lowestPrice: 1_368_315_500_000n,
    highestPrice: 1_368_315_500_000n,
    bidCount: 2,
    snapshotTime: new Date(),
  };
}

/** A publicClient that answers getAccountBalances and nothing else. */
function readClientWith(usdc: bigint, cngn: bigint) {
  return {
    publicClient: {
      readContract: async () => [
        { asset: USDC_ESCROW, subId: 0n, balance: usdc },
        { asset: CNGN_ESCROW, subId: 0n, balance: cngn },
      ],
    },
  } as unknown as ReturnType<CliDeps['readClients']>;
}

function deps(over: Partial<CliDeps> = {}, usdc = ledger(308), cngn = ledger(478_661)): CliDeps {
  return {
    readClients: () => readClientWith(usdc, cngn),
    // The assertion this file exists for.
    signingClients: async () => {
      throw new Error('signingClients must not be constructed for a read-only command');
    },
    post: async () => {},
    fetchSnapshot: async () => snapshot(),
    ...over,
  };
}

test('check never constructs the signer', async () => {
  // The regression guarded against: a future edit hoisting client creation above the switch.
  // That typechecks and leaves CI green, and breaks the one command meant to run unattended --
  // it died in production on an expired SSO session for a credential it never uses.
  await runCommand(['check'], config, deps());
});

test('quote never constructs the signer either', async () => {
  await runCommand(['quote', '20'], config, deps());
});

test('signing commands DO construct the signer', async () => {
  // The negative control: if signingClients were never called for anything, the test above would
  // pass for the wrong reason.
  let called = false;
  const d = deps({
    signingClients: async () => {
      called = true;
      throw new Error('stop here');
    },
  });
  await assert.rejects(() => runCommand(['deposit'], config, d), /stop here/);
  assert.ok(called, 'deposit must construct the signer');
});

test('a failed check pages as loudly as a fired alert', async () => {
  // A crash into a log nobody reads is the same failure mode as an alert that reaches nobody.
  const posted: string[] = [];
  const d = deps({
    readClients: () => {
      throw new Error('RPC unreachable');
    },
    post: async (_url, text) => {
      posted.push(text);
    },
  });
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  await assert.rejects(() => runCommand(['check', '--alert'], withHook, d), /RPC unreachable/);
  assert.equal(posted.length, 1, 'a failed run must alert');
  assert.match(posted[0] ?? '', /FAILED TO RUN/);
  // The wording matters: a failed check must never be read as a clean bill of health.
  assert.match(posted[0] ?? '', /UNKNOWN, not healthy/);
});

test('a failed check still exits non-zero when the webhook is what broke', async () => {
  const d = deps({
    readClients: () => {
      throw new Error('RPC unreachable');
    },
    post: async () => {
      throw new Error('webhook 500');
    },
  });
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  // The original error survives, so the scheduler still sees a failure.
  await assert.rejects(() => runCommand(['check', '--alert'], withHook, d), /RPC unreachable/);
});

test('--alert refuses to run with no webhook configured', async () => {
  // Rather than logging and exiting 0, which is the silent-alert failure this repo keeps finding.
  await assert.rejects(() => runCommand(['check', '--alert'], config, deps()), /ALERT_WEBHOOK_URL/);
});
