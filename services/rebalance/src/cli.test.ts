import test from 'node:test';
import assert from 'node:assert/strict';

import type { Config } from './config.js';
import { runCommand, type CliDeps } from './cli.js';
import type { FetchQuote } from './orderbook.js';
import type { FetchMarkets } from './spot.js';

// The unified stack's spot contracts, as /v1/markets serves them.
const CNGN_ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98';
const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272';
const MANAGER = '0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4';
const markets: FetchMarkets = async () => [
  { contract_type: 'spot', base_asset_symbol: 'cNGN', asset_address: CNGN_ESCROW, quote_asset_address: CASH, margin_manager_address: MANAGER },
];

const config = {
  BASE_RPC_URL: 'http://127.0.0.1:1',
  REBALANCE_KMS_KEY_ID: 'alias/does-not-exist',
  INDEXER_URL: 'http://127.0.0.1:1',
  COPROCESSOR_URL: 'ws://127.0.0.1:1',
  MM_SUBACCOUNT_ID: 26n,
  VENUE_API_URL: 'http://127.0.0.1:1',
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

/** The orderbook at 1368.3155 cNGN per USDC, deep enough for anything a test asks. */
const quoteAt: FetchQuote = async (_url, amountIn) => ({
  amountIn,
  amountOut: (amountIn * 13_683_155n) / 10_000n,
  rate: 1368.3155,
  slippageBps: 5,
  maxFillableIn: 10n ** 12n,
});

/** A publicClient for a subaccount under MANAGER holding `usdc` cash and `cngn` escrow. */
function readClientWith(usdc: bigint, cngn: bigint) {
  return {
    publicClient: {
      readContract: async (a: { functionName: string }) => {
        switch (a.functionName) {
          case 'manager': return MANAGER;
          case 'assetDetails': return { isWhitelisted: true, assetType: 3, marketId: 1n };
          case 'cashAsset': return CASH;
          case 'getAccountBalances': return [
            { asset: CASH, subId: 0n, balance: usdc },
            { asset: CNGN_ESCROW, subId: 0n, balance: cngn },
          ];
          default: throw new Error(`unexpected call ${a.functionName}`);
        }
      },
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
    fetchQuote: quoteAt,
    fetchMarkets: markets,
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

// The heartbeat wrapper pages a due rebalance at LOW priority off exit 1, and a failed run at
// HIGH priority off exit 2 (the entry point). So 1 must mean "due" and nothing else.
test('check --exit-code returns 1 when a rebalance is due', async () => {
  const code = await runCommand(['check', '--exit-code'], config, deps({}, ledger(600), ledger(1_000)));
  assert.equal(code, 1);
});

test('check --exit-code returns 0 on a healthy book', async () => {
  const code = await runCommand(['check', '--exit-code'], config, deps());
  assert.equal(code, 0);
});

test('without --exit-code a due rebalance still exits 0', async () => {
  const code = await runCommand(['check'], config, deps({}, ledger(600), ledger(1_000)));
  assert.equal(code, 0);
});
