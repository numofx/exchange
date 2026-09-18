/** Shared client construction: one place that knows the signer is a KMS account. */
import { KMSClient } from '@aws-sdk/client-kms';
import { createKmsAccount } from '@numo/kms-signer';
import { createPublicClient, createWalletClient, http } from 'viem';
import { base } from 'viem/chains';
import type { Config } from './config.js';

export async function createClients(config: Config) {
  const account = await createKmsAccount(config.REBALANCE_KMS_KEY_ID, new KMSClient({}));
  const transport = http(config.BASE_RPC_URL);
  return {
    account,
    publicClient: createPublicClient({ chain: base, transport }),
    walletClient: createWalletClient({ account, chain: base, transport }),
  };
}

/**
 * Derived from the function rather than written out with viem's own `PublicClient`/`WalletClient`
 * names. @hyperbridge/sdk pins its own viem (2.47.6 alongside our 2.55.4), so naming those types
 * here makes tsc see "two different types with this name" and reject its own return value.
 */
export type Clients = Awaited<ReturnType<typeof createClients>>;

/**
 * Wait until a written value is OBSERVABLE, not merely mined.
 *
 * Read replicas lag the chain: a read straight after a receipt can be served pre-block. This cost
 * three separate wrong conclusions in one session — a refund of 19.92 USDC printed as `+0`, an
 * approve that succeeded made the very next simulate revert "ERC20: insufficient allowance", and a
 * read pinned to the receipt's own block answered "Unknown block" on a deposit that had landed.
 * After any write, poll for the state rather than trusting the receipt.
 */
export async function waitFor(
  read: () => Promise<boolean>,
  { tries = 20, delayMs = 500, what = 'state' }: { tries?: number; delayMs?: number; what?: string } = {},
): Promise<void> {
  for (let i = 0; i < tries; i++) {
    try { if (await read()) return; } catch { /* replica may not have the block yet */ }
    await new Promise((r) => setTimeout(r, delayMs));
  }
  throw new Error(`${what} not observable after ${tries} tries; the transaction may still have succeeded`);
}
