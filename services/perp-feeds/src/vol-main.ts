import { createKmsAccount } from '@numo/kms-signer';
import { privateKeyToAccount, type LocalAccount } from 'viem/accounts';
import type { Hex } from 'viem';

import { createAlerter } from './alert.js';
import { createChain } from './chain.js';
import { loadVolConfig, type VolConfig } from './vol-config.js';
import { VolPublisher } from './vol-publisher.js';

/**
 * The vol publisher for cNGN options (numo-vol-feeds.service): its own KMS signer and relayer. Each tick decides the
 * mode from the index's health (vol-publisher.ts), and publishes the hand-set surface when due or when the mode changes.
 * The loop swallows its own errors and runs again, alerting: a crashed publisher is a stale surface.
 */
async function volSigner(config: VolConfig): Promise<LocalAccount> {
  if (config.VOL_SIGNER_KMS_KEY_ID) return createKmsAccount(config.VOL_SIGNER_KMS_KEY_ID);
  return privateKeyToAccount(config.VOL_SIGNER_KEY as Hex);
}

async function main() {
  const config = loadVolConfig();
  const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined, undefined, undefined, undefined, 'vol-feeds cNGN options');
  let signer: LocalAccount;
  for (let attempt = 1; ; attempt++) {
    try {
      signer = await volSigner(config);
      break;
    } catch (error) {
      // stay up and alert rather than crash-loop under systemd, as forward-main.ts
      await alert('vol-signer-unavailable', `vol signer unavailable (attempt ${attempt}): ${(error as Error).message.slice(0, 300)}`);
      await new Promise((resolve) => setTimeout(resolve, 60_000));
    }
  }
  const chain = createChain(config, signer);
  const publisher = new VolPublisher(config, chain, alert);
  await publisher.checkStartup();
  console.log(
    `[vol] signer ${signer.address} (${config.VOL_SIGNER_KMS_KEY_ID ? 'KMS' : 'raw key'}), relayer ${chain.relayer.address}, ` +
      `feed ${config.VOL_FEED} expiry ${config.EXPIRY}${config.DRY_RUN ? ', DRY RUN' : ''}`,
  );

  for (;;) {
    try {
      const outcome = await publisher.tick();
      if (outcome === 'expired') console.log('[vol] expired: nothing more to publish (the keeper settles options)');
    } catch (error) {
      await alert('vol-tick-error', `vol tick failed: ${(error as Error).message.slice(0, 300)}`);
    }
    await new Promise((resolve) => setTimeout(resolve, config.VOL_TICK_MS));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
