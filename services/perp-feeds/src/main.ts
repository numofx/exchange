import { createAlerter } from './alert.js';
import { createChain } from './chain.js';
import { loadConfig } from './config.js';
import { buildProviders, IndexPublisher } from './index-publisher.js';
import { assertRpcIsLocal, parseFixedPrice, publishFixedPrice } from './local-fixed-price.js';
import { MarkPublisher } from './mark-publisher.js';

/**
 * The USDCcNGN-PERP price publishers: the index (rate-picker sources → median → 15-minute TWAP →
 * inverted to USD per NGN) and the mark and impact prices (the venue's own perp book, anchored to
 * that index). One process, one signer, one relayer to fund.
 *
 * Every loop swallows its own errors and runs again: a crashed publisher is a halted market, and
 * systemd restarting it is slower than the next tick.
 */
async function main() {
  const config = loadConfig();
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

  const index = new IndexPublisher(config, chain, buildProviders(config), alert);
  await index.load();
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
