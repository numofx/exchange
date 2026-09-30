import 'dotenv/config';

import { z } from 'zod';
import { getAddress, parseUnits } from 'viem';

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/).transform((value) => getAddress(value));
const bool = z.union([z.literal('true'), z.literal('false')]).transform((value) => value === 'true');
const usd = z.coerce.number().nonnegative().transform((value) => parseUnits(String(value), 18));

const envSchema = z.object({
  RPC_URL: z.string().url(),
  CHAIN_ID: z.coerce.number().int().positive().default(8453),
  /** EOA that owns KEEPER_ACCOUNT and pays gas. From SSM /numo/keeper/keeper_key. */
  KEEPER_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  /** Subaccount under the perp SRM, funded with the stack's cash, that bids. */
  KEEPER_ACCOUNT: z.coerce.bigint(),
  ALERT_WEBHOOK_URL: z.string().url().optional().or(z.literal('')),
  /** Prepended to every alert, e.g. "[REHEARSAL] " (scripts/local-venue/rehearse-mainnet.sh). */
  ALERT_PREFIX: z.string().default(''),
  /**
   * On by default. Dry run reads everything, decides everything and SIMULATES every transaction
   * against the chain, then sends nothing. Turn it off only once its decisions have been watched.
   */
  DRY_RUN: bool.default('true'),

  // From risk-core/deployments/8453/CNGN_PERP_STACK.json (and core.json for subAccounts).
  SUB_ACCOUNTS: address,
  SRM: address,
  AUCTION: address,
  CASH: address,
  PERP: address,
  SECURITY_MODULE_ACCOUNT: z.coerce.bigint(),
  /** Block the stack was deployed at: account discovery scans logs from here. */
  START_BLOCK: z.coerce.bigint(),
  LOG_CHUNK_BLOCKS: z.coerce.bigint().default(10_000n),

  POLL_INTERVAL_MS: z.coerce.number().int().positive().default(15_000),
  /**
   * Serves GET /health with the last pass's time and outcome and whether this is a dry run, for the
   * perp enable gate (propose_perp_enable_batch.py) to confirm a live keeper. Unset: no server.
   */
  HEALTH_PORT: z.coerce.number().int().positive().optional(),
  HEALTH_HOST: z.string().default('127.0.0.1'),
  MIN_SOLVENT_DISCOUNT_BPS: z.coerce.bigint().default(200n),
  /** Smallest share of an account worth bidding on, as a percentage. */
  MIN_BID_PERCENT: z.coerce.number().positive().max(100).default(1),
  /**
   * Largest bid, in USD of margin it ties up (see KeeperRules.maxBidUsd). Unset: no cap. A launch
   * value keeps one bad auction from taking the keeper's whole book in a single bid.
   */
  MAX_BID_USD: z.coerce.number().positive().optional().transform((value) => (value === undefined ? null : parseUnits(String(value), 18))),

  MIN_SECURITY_MODULE_USD: usd.default(1000),
  MIN_KEEPER_CASH_USD: usd.default(1000),
  MIN_KEEPER_ETH: z.coerce.number().nonnegative().default(0.005).transform((value) => parseUnits(String(value), 18)),
  OI_CAP_WARN_BPS: z.coerce.bigint().default(8_000n),
});

export type Config = z.infer<typeof envSchema>;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  return envSchema.parse(env);
}
