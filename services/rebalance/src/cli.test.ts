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

test('the entry-point guard survives a symlinked invocation path', async () => {
  // Without realpath resolution this returns false and the CLI silently does nothing: argv[1] is
  // the symlink, import.meta.url is the resolved target. A `bin` entry or a symlinked unit path
  // produces exactly that shape, and the failure is a clean exit 0 with no output.
  const { mkdtempSync, writeFileSync, symlinkSync, rmSync, realpathSync } = await import('node:fs');
  const { tmpdir } = await import('node:os');
  const { join } = await import('node:path');
  const { pathToFileURL } = await import('node:url');
  const { isEntryPoint } = await import('./cli.js');

  const dir = mkdtempSync(join(tmpdir(), 'entrypoint-'));
  try {
    const real = join(dir, 'cli.js');
    const link = join(dir, 'linked-cli');
    writeFileSync(real, '');
    symlinkSync(real, link);
    // Node always gives import.meta.url as the REAL path, so the fixture must too -- on macOS
    // tmpdir() sits under a symlinked /var, and a hand-built URL would not match.
    const moduleUrl = pathToFileURL(realpathSync(real)).href;

    assert.equal(isEntryPoint(moduleUrl, real), true, 'direct path must fire');
    assert.equal(isEntryPoint(moduleUrl, link), true, 'symlinked path must fire');
    assert.equal(isEntryPoint(moduleUrl, join(dir, 'other.js')), false, 'a different file must not');
    assert.equal(isEntryPoint(moduleUrl, undefined), false, 'no argv[1] must not');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('--heartbeat posts on a HEALTHY run, so silence cannot pass for healthy', async () => {
  // The gap this closes: a healthy --alert run posts nothing, which is indistinguishable from a
  // timer that stopped firing, a host that went away, or credentials that lapsed.
  const posted: string[] = [];
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  await runCommand(['check', '--heartbeat'], withHook, deps({ post: async (_u, t) => { posted.push(t); } }));
  assert.equal(posted.length, 1, 'a healthy heartbeat run must still post');
  assert.match(posted[0] ?? '', /heartbeat/);
  // It carries the numbers, so the heartbeat is evidence rather than just a ping.
  assert.match(posted[0] ?? '', /cNGN 53%|healthy/);
});

test('--alert alone stays silent on a healthy run', async () => {
  const posted: string[] = [];
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  await runCommand(['check', '--alert'], withHook, deps({ post: async (_u, t) => { posted.push(t); } }));
  assert.equal(posted.length, 0, 'alert-only must not page when nothing is wrong');
});

test('--heartbeat still pages loudly when the run fails', async () => {
  const posted: string[] = [];
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  const d = deps({
    readClients: () => { throw new Error('RPC unreachable'); },
    post: async (_u, t) => { posted.push(t); },
  });
  await assert.rejects(() => runCommand(['check', '--heartbeat'], withHook, d), /RPC unreachable/);
  assert.match(posted[0] ?? '', /FAILED TO RUN/);
});

test('--heartbeat refuses to run with no webhook configured', async () => {
  await assert.rejects(() => runCommand(['check', '--heartbeat'], config, deps()), /reach nobody/);
});

test('--test marks a drill so nobody investigates a healthy venue', async () => {
  const posted: string[] = [];
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  await runCommand(['check', '--heartbeat', '--test'], withHook, deps({ post: async (_u, t) => { posted.push(t); } }));
  assert.match(posted[0] ?? '', /^\[TEST\] /);
});

test('--test marks a forced FAILURE drill too', async () => {
  const posted: string[] = [];
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  const d = deps({
    readClients: () => { throw new Error('forced'); },
    post: async (_u, t) => { posted.push(t); },
  });
  await assert.rejects(() => runCommand(['check', '--alert', '--test'], withHook, d));
  assert.match(posted[0] ?? '', /^\[TEST\] cNGN rebalance check FAILED TO RUN/);
});

test('a failed check confirms locally that the page went out', async () => {
  // The healthy path printed 'heartbeat posted'; the failure path printed nothing, so the run
  // that matters most gave no sign the alert had been delivered. Observed in the 2026-09-22 drill.
  const lines: string[] = [];
  const err = console.error;
  console.error = (m?: unknown) => { lines.push(String(m)); };
  try {
    const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
    const d = deps({ readClients: () => { throw new Error('RPC unreachable'); }, post: async () => {} });
    await assert.rejects(() => runCommand(['check', '--alert'], withHook, d));
  } finally {
    console.error = err;
  }
  assert.ok(lines.some((l) => l === 'failure alert posted'), `expected a delivery confirmation, got ${JSON.stringify(lines)}`);
});

test('the failure reason carries no doubled punctuation', async () => {
  // viem messages already end in '.', and "HTTP request failed.." reached the ops channel.
  const posted: string[] = [];
  const withHook = { ...config, ALERT_WEBHOOK_URL: 'https://hook.example/x' } as Config;
  const d = deps({
    readClients: () => { throw new Error('HTTP request failed.'); },
    post: async (_u, t) => { posted.push(t); },
  });
  await assert.rejects(() => runCommand(['check', '--alert'], withHook, d));
  assert.match(posted[0] ?? '', /HTTP request failed\. Inventory is UNKNOWN/);
  assert.doesNotMatch(posted[0] ?? '', /\.\./);
});
