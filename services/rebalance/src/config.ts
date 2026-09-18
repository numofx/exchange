/**
 * Configuration for the cNGN rebalance.
 *
 * The RPC must be the venue's keyed endpoint. The public `https://mainnet.base.org` rate-limits
 * the Hyperbridge SDK's own initialisation calls outright — it fails on `decimals()` before an
 * order is ever built — so there is no usable default and this refuses to start without one.
 */
import { z } from 'zod';

const schema = z.object({
  /** Keyed Base RPC. Also serves as the bundler unless BUNDLER_URL overrides it. */
  BASE_RPC_URL: z.string().url(),
  /**
   * ERC-4337 bundler. `executeBest` submits the winning solver's bid as a UserOperation, so
   * without one it places the order, fails instantly with "Bundler URL not configured", and
   * leaves the input escrowed until the deadline. Alchemy serves its Rundler bundler on the same
   * URL as the RPC, so defaulting to BASE_RPC_URL is correct there — confirm with
   * `eth_supportedEntryPoints` on any other provider before trusting it.
   */
  BUNDLER_URL: z.string().url().optional(),
  /** KMS key that signs. Never the executor key: this one holds float, that one settles trades. */
  REBALANCE_KMS_KEY_ID: z.string().min(1).default('alias/numo-exchange-rebalance'),
  INDEXER_URL: z.string().url().default('https://nexus.indexer.polytope.technology/'),
  COPROCESSOR_URL: z.string().min(1).default('wss://nexus.rpc.polytope.technology'),
  /** Subaccount the proceeds are deposited into — the market maker's. */
  MM_SUBACCOUNT_ID: z.coerce.bigint().default(15n),
  /**
   * Refuse to trade on a snapshot older than this. The SDK has no such guard — it checks only
   * that the timestamp parses, which is how its V1 feed served a 40-day-old price without
   * complaint. The live V2 feed updates about every 5 minutes.
   */
  MAX_SNAPSHOT_AGE_SECONDS: z.coerce.number().int().positive().default(1800),
  /**
   * `order.fees`, in fee-token units. Set explicitly so the SDK skips its gas estimate, which
   * wants a bundler for a quote we can make cheaply from observation: same-chain Base orders have
   * been costing ~29,000 units. Gas-driven, so this is independent of order size — about 17bps on
   * a $20 order and under 1bp on $500. A fee set too low attracts no solver.
   */
  SOLVER_FEE: z.coerce.bigint().default(35_000n),
  /**
   * Deadline, in Base blocks from placement. The input sits escrowed until a solver fills or this
   * passes, so it is how long the money is tied up on a miss. HyperFX's own UI uses 58 (~2 min).
   */
  DEADLINE_BLOCKS: z.coerce.bigint().default(120n),
  /** Auction window handed to executeBest. */
  AUCTION_MS: z.coerce.number().int().positive().default(30_000),
});

export type Config = z.infer<typeof schema> & { bundlerUrl: string };

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const lines = parsed.error.issues.map((i) => `  ${i.path.join('.')}: ${i.message}`);
    throw new Error(`invalid rebalance config:\n${lines.join('\n')}`);
  }
  return { ...parsed.data, bundlerUrl: parsed.data.BUNDLER_URL ?? parsed.data.BASE_RPC_URL };
}
