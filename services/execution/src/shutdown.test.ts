import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const WITHDRAWAL = {
  action: {
    subaccount_id: '19',
    nonce: '7',
    module: '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB',
    data: `0x${'0'.repeat(24)}364058aff6f36e01505fb2cc870f8b6bd4835e84${(1_999_575).toString(16).padStart(64, '0')}`,
    expiry: '4102444800',
    owner: '0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA',
    signer: '0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA',
  },
  signature: `0x${'ab'.repeat(65)}`,
};

// A real process and a real SIGTERM: an in-flight request (standing in for a send and its receipt wait) must finish
// and be answered, new work must be refused, and the process must then exit 0 -- not be killed mid-request.
test('SIGTERM drains an in-flight request, refuses new ones, then exits cleanly', async () => {
  const here = fileURLToPath(new URL('.', import.meta.url));
  const dir = mkdtempSync(join(tmpdir(), 'shutdown-'));
  const script = join(dir, 'server.mts');
  // The executor's own app (buildApp), so this tests its close() behaviour, not a stand-in server. A slow withdrawal
  // stands in for a send and its receipt wait.
  writeFileSync(script, `
    import { buildApp } from ${JSON.stringify(join(here, 'app.ts'))};
    import { installGracefulShutdown } from ${JSON.stringify(join(here, 'shutdown.ts'))};
    const app = buildApp({
      config: { port: 0, host: '127.0.0.1', rpcUrl: 'http://127.0.0.1:1', chainId: 8453, dryRun: true, waitForReceipt: false,
        receiptTimeoutMs: 60000, withdrawalAssetAddresses: [], withdrawalReceiptTimeoutMs: 30000 },
      executor: { execute: async () => ({ accepted: true, tx_hash: 'dry-run' }) },
      matchingAddress: '0x00000000000000000000000000000000000000aa',
      tradeModuleAddress: '0x00000000000000000000000000000000000000bb',
      withdrawer: { withdraw: async () => { await new Promise((r) => setTimeout(r, 800)); return { accepted: true, tx_hash: '0x' + '11'.repeat(32) }; } },
    });
    await app.listen({ host: '127.0.0.1', port: 0 });
    installGracefulShutdown({ close: () => app.close(), closeIdleConnections: () => app.server.closeIdleConnections(), log: () => {} });
    process.stdout.write('PORT=' + String(app.server.address().port) + '\\n');
  `);
  const child = spawn(process.execPath, ['--import', 'tsx', script], { cwd: join(here, '..'), stdio: ['ignore', 'pipe', 'inherit'] });
  // The app logs JSON to stdout too; the port is the line marked PORT=.
  const port = await new Promise<number>((resolve) => {
    let out = '';
    child.stdout.on('data', (d) => {
      out += String(d);
      const m = /PORT=(\d+)/.exec(out);
      if (m) resolve(Number(m[1]));
    });
  });
  const exited = new Promise<number | null>((resolve) => child.once('exit', (code) => resolve(code)));

  const withdraw = () =>
    fetch(`http://127.0.0.1:${port}/withdraw`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(WITHDRAWAL) });
  const inFlight = withdraw();
  await new Promise((r) => setTimeout(r, 150));
  child.kill('SIGTERM');
  await new Promise((r) => setTimeout(r, 100));
  const late = await withdraw().then((r) => r.status, () => 'refused');

  const res = await inFlight;
  assert.equal(res.status, 200, 'the in-flight request was answered, not cut off');
  assert.equal((await res.json()).tx_hash, `0x${'11'.repeat(32)}`);
  assert.ok(late === 'refused' || late === 503, `new work after SIGTERM must be refused, got ${late}`);
  const started = Date.now();
  assert.equal(await exited, 0);
  // A keep-alive connection must not hold the exit for the keep-alive timeout (72s).
  assert.ok(Date.now() - started < 5_000, `exit took ${Date.now() - started}ms after the drain`);
});
