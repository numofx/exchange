import { createAlerter } from './alert.js';
import { createChain } from './chain.js';
import { loadConfig } from './config.js';
import { IndexPublisher } from './index-publisher.js';
import { buildIndexSources } from './index-sources.js';
import { fetchPegTicker, pegMid, pegReading } from './peg.js';
import { acceptIndexStep, fetchKeeperHealth, parseStepArgs } from './index-step.js';
import { assertRpcIsLocal, localPegTicker, localSources, parseFixedPrice, parseLocalSources, publishFixedPrice } from './local-fixed-price.js';
import { MarkPublisher } from './mark-publisher.js';

/**
 * The USDCcNGN-PERP price publishers: the index (rate-picker sources → median → 15-minute TWAP →
 * inverted to USDC per cNGN) and the mark and impact prices (the venue's own perp book, anchored to
 * that index). One process, one signer, one relayer to fund.
 *
 * Every loop swallows its own errors and runs again: a crashed publisher is a halted market, and
 * systemd restarting it is slower than the next tick.
 */
/**
 * `--probe-sources`: reads the peg tripwire and every source once and prints what each said (NGN
 * per USDT, which the index takes as cNGN per USDT at parity). Signs and sends nothing. Run it
 * on the host the publisher will run on: a source reachable from a laptop may be geo-blocked from
 * the ops box, and the reverse.
 */
async function probeSources(config: ReturnType<typeof loadConfig>) {
  const now = Date.now();
  let peg;
  try {
    const mid = pegMid(await fetchPegTicker(config.QUIDAX_API_URL, AbortSignal.timeout(config.PROVIDER_TIMEOUT_MS)), config.PEG_MAX_SPREAD_BPS);
    peg = mid.ok
      ? pegReading([{ price: mid.mid, at: now }], now, { windowMs: config.PEG_TWAP_WINDOW_MS, maxSpreadBps: config.PEG_MAX_SPREAD_BPS, guardBps: config.PEG_GUARD_BPS })
      : ({ state: 'blind', reason: mid.reason } as const);
  } catch (error) {
    peg = { state: 'blind', reason: (error as Error).message } as const;
  }
  console.log(peg.state === 'watching'
    ? `tripwire     ok    cNGN at ${peg.ngnPerCngn} NGN (${peg.deviationBps.toFixed(1)}bps from parity${peg.tripped ? ', WOULD TRIP' : ''}); not a source`
    : `tripwire     BLIND ${peg.reason} (the index continues at parity)`);
  const sources = buildIndexSources(config);
  let answered = 0;
  for (const source of sources) {
    const started = Date.now();
    try {
      const reading = await source.read({ signal: AbortSignal.timeout(config.PROVIDER_TIMEOUT_MS), fetch });
      answered += 1;
      console.log(`${source.name.padEnd(12)} ok    ${reading.cngnPerUsdt.toFixed(4)} NGN/USDT (= cNGN/USDT at parity)  ${Date.now() - started}ms`);
    } catch (error) {
      console.log(`${source.name.padEnd(12)} FAIL  ${(error as Error).message.slice(0, 160)}  ${Date.now() - started}ms`);
    }
  }
  const verdict = answered >= config.INDEX_MIN_SOURCES ? 'enough' : 'NOT ENOUGH: the index will refuse every sample';
  console.log(`${answered} of ${sources.length} sources answered; the index needs ${config.INDEX_MIN_SOURCES} (${verdict})`);
  if (answered < config.INDEX_MIN_SOURCES) process.exitCode = 1;
}

async function main() {
  const config = loadConfig();
  if (process.argv.includes('--probe-sources')) {
    await probeSources(config);
    return;
  }
  const chain = createChain(config);
  const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined);

  console.log(`[perp-feeds] signer=${chain.signer.address} relayer=${chain.relayer.address} dryRun=${config.DRY_RUN}`);

  const once = process.argv.includes('--once');
  const fixedPrice = parseFixedPrice(process.argv);
  if (fixedPrice !== null) {
    // Checked before anything is signed: this mode bypasses every guard below.
    await assertRpcIsLocal(config);
    await publishFixedPrice(config, chain, fixedPrice);
    if (!once) {
      every(config.MARK_INTERVAL_MS, () =>
        publishFixedPrice(config, chain, fixedPrice).catch((error) => console.error(`[local-fixed-price] ${error}`)),
      );
    }
    return;
  }

  const localPrice = parseLocalSources(process.argv);
  if (localPrice !== null) await assertRpcIsLocal(config);
  const index =
    localPrice === null
      ? new IndexPublisher(config, chain, buildIndexSources(config), alert)
      : new IndexPublisher(config, chain, localSources(localPrice), alert, Date.now, localPegTicker);
  await index.load();

  // One publish past the jump guard, then exit: the reopening procedure in the README.
  const step = parseStepArgs(process.argv);
  if (step !== null) {
    // Run with the publisher stopped (it shares INDEX_STATE_FILE). One fresh sample first, under the
    // usual source-agreement guard, so the window's newest sample is now.
    await index.sample();
    const { tx, plan } = await acceptIndexStep({
      config,
      chain,
      alert,
      samples: index.samples(),
      lastPublished: index.lastPublished(),
      request: step,
      readKeeperHealth: () => fetchKeeperHealth(config.KEEPER_HEALTH_URL || undefined),
    });
    if (tx !== null) await index.recordPublished(plan.next);
    return;
  }
  const mark = new MarkPublisher(config, chain, alert);

  const guarded = (name: string, task: () => Promise<void>) => async () => {
    try {
      await task();
    } catch (error) {
      console.error(`[${name}] ${(error as Error).stack ?? error}`);
      await alert(`${name}-error`, `${name} failed: ${(error as Error).message}`);
    }
  };

  const sample = guarded('index-sample', () => index.sample());
  const publishIndex = guarded('index-publish', () => index.publish());
  const publishMark = guarded('mark-publish', () => mark.publish());

  await sample();
  if (once) {
    await publishIndex();
    await publishMark();
    return;
  }

  every(config.INDEX_SAMPLE_INTERVAL_MS, sample);
  every(config.INDEX_PUBLISH_INTERVAL_MS, publishIndex);
  every(config.MARK_INTERVAL_MS, publishMark);
}

/** Runs `task` every `intervalMs`, never overlapping itself. */
function every(intervalMs: number, task: () => Promise<void>) {
  let running = false;
  setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await task();
    } finally {
      running = false;
    }
  }, intervalMs);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
