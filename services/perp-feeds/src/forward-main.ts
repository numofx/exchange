import { createKmsAccount } from '@numo/kms-signer';
import { privateKeyToAccount, type LocalAccount } from 'viem/accounts';
import type { Hex } from 'viem';

import { createAlerter, type Alerter } from './alert.js';
import { createChain } from './chain.js';
import { loadForwardConfig, type ForwardConfig } from './forward-config.js';
import { ForwardPublisher } from './forward-publisher.js';
import { ExpiryKeeper } from './expiry-keeper.js';

/**
 * The keeper for a dated future, one unit per series (numo-future-feeds.service for v1's
 * USDC-cNGN-30NOV26, numo-future-feeds-v2@<series>.service for each v2 series): its own signer,
 * held in KMS, and its own relayer. Each tick runs the forward publisher (forward-publisher.ts: marks
 * until last trade), then the VM pool's deficit cover and the expiry keeper (expiry-keeper.ts: losers
 * settled while the pool's net is below zero; fixing samples, the fixing, and close-out). Their writes
 * share the one relayer queue, so they never race for a nonce.
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

/**
 * One pass of the VM pool's deficit cover. A failure (most often a stale spot feed, which settlement
 * needs too) alerts and leaves the loop running: the next tick tries again.
 */
export async function coverDeficit(expiry: Pick<ExpiryKeeper, 'coverPoolDeficit'>, alert: Alerter): Promise<void> {
  try {
    await expiry.coverPoolDeficit();
  } catch (error) {
    await alert('pool-deficit-error', `VM pool deficit check failed: ${(error as Error).message.slice(0, 300)}`);
  }
}

/** What heads this instance's alerts: v1 keeps the tag it always had, a v2 series names its base. */
export function alertTag(config: Pick<ForwardConfig, 'FUTURE_VERSION' | 'BASE_SYMBOL'>): string {
  return config.FUTURE_VERSION === 'v2' ? `future-feeds ${config.BASE_SYMBOL} v2` : 'perp-feeds';
}

async function main() {
  const config = loadForwardConfig();
  const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined, undefined, undefined, undefined, alertTag(config));
  const signer = await obtainSigner(config, alert);
  const chain = createChain(config, signer);
  const publisher = new ForwardPublisher(config, chain, alert);
  await publisher.checkLateThreshold();
  await publisher.checkUnits();
  // TODO(#258): v2's VM pool is cash only and its VM is USDC; the v1 deficit cover would misread it.
  // Until the v2 expiry keeper lands, a v2 instance only marks (nothing holds a v2 series before enable).
  const expiry = config.FUTURE_VERSION === 'v1' ? new ExpiryKeeper(config, chain, alert) : null;
  if (expiry) await expiry.checkSampleInterval();
  else console.warn('[expiry] v2: the VM pool cover, fixing and close-out are not run by this build');
  console.log(
    `[forward] signer ${signer.address} (${config.FORWARD_SIGNER_KMS_KEY_ID ? 'KMS' : 'raw key'}), relayer ${chain.relayer.address}, ` +
      `${config.BASE_SYMBOL} future ${config.FUTURE_VERSION} ${config.FUTURE_ASSET} #${config.FUTURE_SUB_ID}${config.DRY_RUN ? ', DRY RUN' : ''}`,
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
    if (expiry) {
      // Every tick, not only after a mark: a mark moves no money, a winner settling does, at any minute.
      await coverDeficit(expiry, alert);
      try {
        const outcome = await expiry.tick();
        if (outcome !== 'before-window' && outcome !== 'sample-not-due' && outcome !== 'done') console.log(`[expiry] ${outcome}`);
      } catch (error) {
        await alert('expiry-tick-error', `expiry tick failed: ${(error as Error).message.slice(0, 300)}`);
      }
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
