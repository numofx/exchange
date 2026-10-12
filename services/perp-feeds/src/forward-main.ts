import { createKmsAccount } from '@numo/kms-signer';
import { privateKeyToAccount, type LocalAccount } from 'viem/accounts';
import type { Hex } from 'viem';

import { createAlerter, type Alerter } from './alert.js';
import { createChain } from './chain.js';
import { loadForwardConfig, type ForwardConfig } from './forward-config.js';
import { ForwardPublisher } from './forward-publisher.js';
import { ExpiryKeeper } from './expiry-keeper.js';

/**
 * The keeper for a USDC/cNGN future, run as its own unit (numo-future-feeds.service): its own signer,
 * held in KMS, and its own relayer. Each tick runs the forward publisher (forward-publisher.ts: marks
 * until last trade), a VM sweep after each mark it lands, and then the expiry keeper (expiry-keeper.ts:
 * fixing samples, the fixing, and close-out). Their writes share the one relayer queue, so they never
 * race for a nonce.
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

export async function sweep(expiry: Pick<ExpiryKeeper, 'sweep'>, alert: Alerter): Promise<void> {
  try {
    const swept = await expiry.sweep();
    console.log(`[sweep] ${swept.settled} settled, ${swept.failed} failed`);
  } catch (error) {
    await alert('sweep-error', `VM sweep failed: ${(error as Error).message.slice(0, 300)}`);
  }
}

async function main() {
  const config = loadForwardConfig();
  const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined);
  const signer = await obtainSigner(config, alert);
  const chain = createChain(config, signer);
  const publisher = new ForwardPublisher(config, chain, alert);
  await publisher.checkLateThreshold();
  const expiry = new ExpiryKeeper(config, chain, alert);
  await expiry.checkSampleInterval();
  // A stop between a mark and its sweep (a deploy, a crash) leaves that VM unrealised until the next
  // mark, and after last trade there is none: sweep once on the way up.
  await sweep(expiry, alert);
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
      // A new mark is new VM: realise it now, payers first, so the pool's reserve is not what pays it.
      if (outcome === 'published') await sweep(expiry, alert);
    } catch (error) {
      await alert('forward-tick-error', `forward tick failed: ${(error as Error).message.slice(0, 300)}`);
    }
    try {
      const outcome = await expiry.tick();
      if (outcome !== 'before-window' && outcome !== 'sample-not-due' && outcome !== 'done') console.log(`[expiry] ${outcome}`);
    } catch (error) {
      await alert('expiry-tick-error', `expiry tick failed: ${(error as Error).message.slice(0, 300)}`);
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
