import 'dotenv/config';

import { z } from 'zod';
import { getAddress } from 'viem';

import { ONE, shapeProblem } from './vol-surface.js';

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/).transform((value) => getAddress(value));
const privateKey = z.string().regex(/^0x[0-9a-fA-F]{64}$/);
const uint = z.string().regex(/^[0-9]+$/).transform((value) => BigInt(value));
const int = z.string().regex(/^-?[0-9]+$/).transform((value) => BigInt(value));
const bool = z.union([z.literal('true'), z.literal('false')]).transform((value) => value === 'true');

const BASE_MAINNET = 8453;

/**
 * The vol publisher for cNGN options (vol-main.ts): signs a hand-set SVI surface into the options' LyraVolFeed for one
 * expiry. Its own process, signer and relayer, as the forward publisher: the vol key must not sign the index or the
 * forward (the deploy script refuses that), and a shared relayer races for nonces.
 *
 * Secrets: RPC_URL and RELAYER_KEY (SSM /numo/feeds/rpc_url and VOL_RELAYER_SSM_NAME, via run-with-ssm-vol.sh). The
 * signer is a KMS key (VOL_SIGNER_KMS_KEY_ID); a raw VOL_SIGNER_KEY is accepted only off mainnet.
 *
 * Values are from risk-core/deployments/8453/CNGN_OPTIONS_V2.json (volFeed, forwardFeed, indexFeed, manager, expiry).
 */
const envSchema = z
  .object({
    RPC_URL: z.string().url(),
    CHAIN_ID: z.coerce.number().int().positive().default(BASE_MAINNET),
    RELAYER_KEY: privateKey,
    VOL_SIGNER_KMS_KEY_ID: z.string().min(1).optional(),
    VOL_SIGNER_KEY: privateKey.optional(),
    ALERT_WEBHOOK_URL: z.string().url().optional().or(z.literal('')),
    DRY_RUN: bool.default('false'),

    DATA_SUBMITTER: address,
    VOL_FEED: address,
    /** The cNGN future's LyraForwardFeed: the surface's SVI_fwd, and what the engine prices options against. */
    FORWARD_FEED: address,
    INDEX_FEED: address,
    /** MarginEngine v2: its option threshold for market 1 is what VOL_DEGRADED_CONFIDENCE must sit under. */
    ENGINE: address,
    MARKET_ID: z.coerce.number().int().positive().default(1),
    EXPIRY: uint,

    /**
     * The hand-set surface (decided 2026-11-01). ATM vol, 18dp (400000000000000000 = 40%); the shape is relative to
     * ATM variance (vol-surface.ts): b = VOL_B_MULT x ATM variance, skew VOL_RHO (negative: the devaluation wing
     * dearer), curvature VOL_SIGMA. Changing any of these is a governance change: commit it, then copy the env file.
     */
    VOL_ATM: uint,
    VOL_B_MULT: uint.default('2000000000000000000'),
    VOL_RHO: int.default('-500000000000000000'),
    VOL_SIGMA: uint.default('100000000000000000'),

    /**
     * Degrade, not halt (decided 2026-11-01): while the index is uncertain, publish at this confidence (under the
     * engine's option threshold, so opening shorts costs more IM and nothing is liquidated for it) and at an ATM vol of
     * at least VOL_DEGRADED_ATM_FLOOR. The feed goes stale only if the publisher itself is broken.
     */
    VOL_DEGRADED_CONFIDENCE: uint.default('500000000000000000'),
    VOL_DEGRADED_ATM_FLOOR: uint,
    /** The index publisher's status file (perp-feeds' INDEX_STATUS_FILE): the peg tripwire and the last sample. */
    INDEX_STATUS_FILE: z.string().default('/var/lib/numo/perp-index-status.json'),
    /** Older than this, the index publisher is taken as silent: degrade. It writes every minute. */
    INDEX_STATUS_MAX_AGE_MS: z.coerce.number().int().positive().default(5 * 60_000),
    /** The index-step audit log (perp-feeds' INDEX_STEP_AUDIT_FILE): a published step within VOL_STEP_DEGRADE_MS degrades. */
    INDEX_STEP_AUDIT_FILE: z.string().default('/var/lib/numo/perp-index-steps.jsonl'),
    VOL_STEP_DEGRADE_MS: z.coerce.number().int().positive().default(24 * 60 * 60_000),
    /** Where this publisher writes what it last did, for the pager and an operator on the host. */
    VOL_STATUS_FILE: z.string().default('./vol-status.json'),

    /** How often to look. A publish is due every VOL_PUBLISH_INTERVAL_MS, or at once when the mode changes. */
    VOL_TICK_MS: z.coerce.number().int().positive().default(60_000),
    /** Must sit well inside the feed's heartbeat (checked at startup): a third of it at most. */
    VOL_PUBLISH_INTERVAL_MS: z.coerce.number().int().positive().default(5 * 60_000),

    TIMESTAMP_SAFETY_SEC: z.coerce.number().int().nonnegative().default(15),
    DEADLINE_SEC: z.coerce.number().int().positive().default(60),
  })
  .superRefine((env, ctx) => {
    const issue = (message: string) => ctx.addIssue({ code: z.ZodIssueCode.custom, message });
    const kms = env.VOL_SIGNER_KMS_KEY_ID !== undefined;
    const raw = env.VOL_SIGNER_KEY !== undefined;
    if (kms === raw) issue('set exactly one of VOL_SIGNER_KMS_KEY_ID and VOL_SIGNER_KEY');
    if (raw && env.CHAIN_ID === BASE_MAINNET) issue('on Base mainnet the vol signer must be a KMS key, not VOL_SIGNER_KEY');
    // a unit slip (40 for 40%) reads as 4e-17: refuse anything under 5% or over 500%
    if (env.VOL_ATM < ONE / 20n || env.VOL_ATM > 5n * ONE) issue('VOL_ATM out of [5%, 500%]: give it 18dp (400000000000000000 for 40%)');
    if (env.VOL_DEGRADED_ATM_FLOOR < env.VOL_ATM) issue('VOL_DEGRADED_ATM_FLOOR must be at least VOL_ATM: degrading never cheapens the surface');
    if (env.VOL_DEGRADED_ATM_FLOOR > 5n * ONE) issue('VOL_DEGRADED_ATM_FLOOR over 500%');
    if (env.VOL_DEGRADED_CONFIDENCE <= 0n || env.VOL_DEGRADED_CONFIDENCE >= ONE) issue('VOL_DEGRADED_CONFIDENCE must be inside (0, 1)');
    const shape = shapeProblem({ bMult: env.VOL_B_MULT, rho: env.VOL_RHO, sigma: env.VOL_SIGMA });
    if (shape) issue(shape);
  });

export type VolConfig = z.infer<typeof envSchema>;

export function loadVolConfig(env: NodeJS.ProcessEnv = process.env): VolConfig {
  return envSchema.parse(env);
}
