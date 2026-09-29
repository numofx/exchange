import { createAlerter } from './alert.js';
import { createKeeperChain } from './chain.js';
import { loadConfig } from './config.js';
import { runOnce } from './keeper.js';

/**
 * USDCcNGN-PERP liquidation keeper: watches every account under the perp SRM, starts auctions on
 * those below maintenance margin, bids on them (solvent at a discount, insolvent for the security
 * module's payout), converts and terminates auctions as they run out or recover, and alerts on the
 * stack's solvency. Dry run (simulate, never send) until DRY_RUN=false.
 */
async function main() {
  const config = loadConfig();
  const chain = createKeeperChain(config);
  const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined);

  console.log(`[keeper] eoa=${chain.keeper.address} account=${config.KEEPER_ACCOUNT} dryRun=${config.DRY_RUN}`);

  const tick = async () => {
    try {
      await runOnce(config, chain, alert);
    } catch (error) {
      console.error(`[keeper] ${(error as Error).stack ?? error}`);
      await alert('keeper-error', `keeper pass failed: ${(error as Error).message}`);
    }
  };

  await tick();
  if (process.argv.includes('--once')) return;

  let running = false;
  setInterval(async () => {
    if (running) return;
    running = true;
    try {
      await tick();
    } finally {
      running = false;
    }
  }, config.POLL_INTERVAL_MS);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
