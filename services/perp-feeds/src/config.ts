import 'dotenv/config';

import { z } from 'zod';
import { getAddress, type Address } from 'viem';

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/).transform((value) => getAddress(value));
const privateKey = z.string().regex(/^0x[0-9a-fA-F]{64}$/);
const bool = z.union([z.literal('true'), z.literal('false')]).transform((value) => value === 'true');

/**
 * Names match run-with-ssm.sh, which exports RPC_URL, FEED_SIGNER_KEY, RELAYER_KEY and
 * ALERT_WEBHOOK_URL from SSM /numo/feeds/*: the perp publishers revive that signer rather than
 * minting a second key to fund and watch.
 */
const envSchema = z.object({
  RPC_URL: z.string().url(),
  CHAIN_ID: z.coerce.number().int().positive().default(8453),
  FEED_SIGNER_KEY: privateKey,
  RELAYER_KEY: privateKey,
  ALERT_WEBHOOK_URL: z.string().url().optional().or(z.literal('')),
  DRY_RUN: bool.default('false'),

  // Addresses, from risk-core/deployments/8453/CNGN_PERP_STACK.json and core.json.
  DATA_SUBMITTER: address,
  PERP_ASSET: address,
  INDEX_FEED: address,
  MARK_FEED: address,
  IMPACT_ASK_FEED: address,
  IMPACT_BID_FEED: address,
  MARKETS_SERVICE_URL: z.string().url().default('https://api.numofx.com'),

  // Index: a sample every minute, a 15-minute TWAP, republished every 5 minutes against a
  // 20-minute heartbeat, so one missed publish is survivable and three are not.
  INDEX_SAMPLE_INTERVAL_MS: z.coerce.number().int().positive().default(60_000),
  INDEX_PUBLISH_INTERVAL_MS: z.coerce.number().int().positive().default(300_000),
  INDEX_TWAP_WINDOW_MS: z.coerce.number().int().positive().default(900_000),
  INDEX_MIN_WINDOW_SAMPLES: z.coerce.number().int().positive().default(10),
  /** Three missed samples: past this, the index is not republished from older ones. */
  INDEX_MAX_SAMPLE_AGE_MS: z.coerce.number().int().positive().default(180_000),
  INDEX_MIN_SOURCES: z.coerce.number().int().min(3).default(3),
  INDEX_MAX_SOURCE_DEVIATION_BPS: z.coerce.number().positive().default(150),
  INDEX_MAX_JUMP_BPS: z.coerce.number().int().positive().default(300),
  /**
   * `--accept-index-step` (index-step.ts): the confirmed level must sit within this of the sources'
   * own window TWAP, and the step may be no larger than INDEX_STEP_MAX_BPS. Every accepted step is
   * appended to INDEX_STEP_AUDIT_FILE. KEEPER_HEALTH_URL is the keeper's /health, which must pass.
   */
  INDEX_STEP_MATCH_BPS: z.coerce.number().int().positive().default(100),
  INDEX_STEP_MAX_BPS: z.coerce.number().int().positive().default(5_000),
  INDEX_STEP_AUDIT_FILE: z.string().default('./perp-index-steps.jsonl'),
  KEEPER_HEALTH_URL: z.string().url().optional().or(z.literal('')),
  INDEX_STATE_FILE: z.string().default('./perp-index-state.json'),
  QUIDAX_API_URL: z.string().url().default('https://openapi.quidax.io/exchange-open-api/api/v1'),
  /** Where each sample's source readings and tripwire state are written, for the pager's peg-guard page. */
  INDEX_STATUS_FILE: z.string().default('./perp-index-status.json'),

  // The peg tripwire (peg.ts): a TWAP of Quidax cngnngn book mids over PEG_TWAP_WINDOW_MS. Past
  // PEG_GUARD_BPS from parity every sample is refused and the pager pages; it is not a source.
  PEG_TWAP_WINDOW_MS: z.coerce.number().int().positive().default(900_000),
  PEG_MAX_SPREAD_BPS: z.coerce.number().positive().default(50),
  PEG_GUARD_BPS: z.coerce.number().positive().default(100),
  PROVIDER_TIMEOUT_MS: z.coerce.number().int().positive().default(8_000),

  // Mark and impacts: checked every minute, published on a 10bps move or before half the 15-minute
  // mark heartbeat has passed, whichever is first.
  MARK_INTERVAL_MS: z.coerce.number().int().positive().default(60_000),
  MARK_UPDATE_THRESHOLD_BPS: z.coerce.number().int().nonnegative().default(10),
  MARK_MAX_AGE_MS: z.coerce.number().int().positive().default(420_000),
  MARK_MAX_BASIS_BPS: z.coerce.number().int().positive().max(600).default(200),
  IMPACT_NOTIONAL_USD: z.coerce.number().positive().default(1_000),

  // Feed timestamps are signed this far behind the chain head: the feed rejects future timestamps.
  TIMESTAMP_SAFETY_SEC: z.coerce.number().int().nonnegative().default(15),
  DEADLINE_SEC: z.coerce.number().int().positive().default(60),
});

export type Config = z.infer<typeof envSchema> & { markets: { perp: Address } };

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = envSchema.parse(env);
  return { ...parsed, markets: { perp: parsed.PERP_ASSET } };
}
