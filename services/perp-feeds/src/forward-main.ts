import { createKmsAccount } from '@numo/kms-signer';
import { privateKeyToAccount, type LocalAccount } from 'viem/accounts';
import type { Hex } from 'viem';

import { createAlerter, type Alerter } from './alert.js';
import { createChain } from './chain.js';
import { loadForwardConfig, type ForwardConfig } from './forward-config.js';
import { ForwardPublisher } from './forward-publisher.js';

/**
 * The forward publisher for a USDC/cNGN future, run as its own unit (numo-future-feeds.service):
 * its own signer, held in KMS, and its own relayer. See forward-publisher.ts for what each tick does.
 *
 * The loop swallows its own errors and runs again: a crashed publisher is a stale mark, and systemd
 * restarting it is slower than the next tick.
 */
export async function forwardSigner(config: ForwardConfig): Promise<LocalAccount> {
  if (config.FORWARD_SIGNER_KMS_KEY_ID) return createKmsAccount(config.FORWARD_SIGNER_KMS_KEY_ID);
  return privateKeyToAccount(config.FORWARD_SIGNER_KEY as Hex);
}

/**
 * The signer, retried until KMS answers. Building a KMS account reads the key's public key, so a
 * missing kms:GetPublicKey grant, a wrong key id or a disabled key fails here. Crashing would leave
 * systemd restarting the unit every few seconds with nothing but the journal to say why; instead it
 * stays up and alerts (the alerter's cooldown holds, since the process does not restart).
 */
export async function obtainSigner(
  config: ForwardConfig,
  alert: Alerter,
  create: (config: ForwardConfig) => Promise<LocalAccount> = forwardSigner,
  retryMs = 60_000,
  maxAttempts = Infinity,
): Promise<LocalAccount> {
  for (let attempt = 1; ; attempt++) {
    try {
      return await create(config);
    } catch (error) {
      await alert('forward-signer-unavailable', `forward signer unavailable (attempt ${attempt}): ${(error as Error).message.slice(0, 300)}`);
      if (attempt >= maxAttempts) throw error;
      await new Promise((resolve) => setTimeout(resolve, retryMs));
    }
  }
}

async function main() {
  const config = loadForwardConfig();
  const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined);
  const signer = await obtainSigner(config, alert);
  const chain = createChain(config, signer);
  const publisher = new ForwardPublisher(config, chain, alert);
  await publisher.checkLateThreshold();
  console.log(
    `[forward] signer ${signer.address} (${config.FORWARD_SIGNER_KMS_KEY_ID ? 'KMS' : 'raw key'}), relayer ${chain.relayer.address}, ` +
      `future ${config.FUTURE_ASSET} #${config.FUTURE_SUB_ID}${config.DRY_RUN ? ', DRY RUN' : ''}`,
  );

  for (;;) {
    try {
      const outcome = await publisher.tick();
      // After settlement there is nothing to mark, but the unit keeps running: exiting would only be
      // restarted by systemd. The quiet states (waiting, closed, settled) are not logged every tick.
      if (outcome !== 'waiting' && outcome !== 'settled' && outcome !== 'closed') console.log(`[forward] ${outcome}`);
    } catch (error) {
      await alert('forward-tick-error', `forward tick failed: ${(error as Error).message.slice(0, 300)}`);
    }
    await new Promise((resolve) => setTimeout(resolve, config.FORWARD_TICK_MS));
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
