import 'dotenv/config';

import { z } from 'zod';
import { getAddress } from 'viem';

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/).transform((value) => getAddress(value));
const privateKey = z.string().regex(/^0x[0-9a-fA-F]{64}$/);
const uint = z.string().regex(/^[0-9]+$/).transform((value) => BigInt(value));
const bool = z.union([z.literal('true'), z.literal('false')]).transform((value) => value === 'true');

const BASE_MAINNET = 8453;

/**
 * The forward publisher for a USDC/cNGN future (forward-main.ts). Its own process, signer and
 * relayer: the forward key must not be the index key (the index band is what bounds a bad forward),
 * and a relayer shared with perp-feeds would race it for nonces across processes.
 *
 * Secrets: RPC_URL and RELAYER_KEY (SSM /numo/feeds/rpc_url and /numo/feeds/forward_relayer_key,
 * via run-with-ssm-forward.sh). The signer is a KMS key (FORWARD_SIGNER_KMS_KEY_ID, not a secret);
 * a raw FORWARD_SIGNER_KEY is accepted only off mainnet, for anvil and Sepolia rehearsals.
 */
const envSchema = z
  .object({
    RPC_URL: z.string().url(),
    CHAIN_ID: z.coerce.number().int().positive().default(BASE_MAINNET),
    RELAYER_KEY: privateKey,
    FORWARD_SIGNER_KMS_KEY_ID: z.string().min(1).optional(),
    FORWARD_SIGNER_KEY: privateKey.optional(),
    ALERT_WEBHOOK_URL: z.string().url().optional().or(z.literal('')),
    DRY_RUN: bool.default('false'),

    // From risk-core/deployments/8453/CNGN_NOV30_2026_FUTURE.json and core.json.
    DATA_SUBMITTER: address,
    INDEX_FEED: address,
    FORWARD_FEED: address,
    FUTURE_ASSET: address,
    /** The FutureManager, for closeOutExpired, and SubAccounts, to find the accounts still holding. */
    FUTURE_MANAGER: address,
    SUB_ACCOUNTS: address,
    FUTURE_SUB_ID: uint,
    /** Annual NGN-over-USD carry, 18dp: the forward without a book is index * (1 + CARRY * tau). */
    CARRY: uint,
    MARKETS_SERVICE_URL: z.string().url().default('https://api.numofx.com'),

    /** How often to check. A mark is only pushed once FutureAsset.minMarkInterval has passed. */
    FORWARD_TICK_MS: z.coerce.number().int().positive().default(60_000),
    /**
     * Notional (USDC) each side of the futures book must fill before the book sets the mark: each
     * side's price is its depth-weighted average over this. Below it, the mark is the carry forward.
     */
    FORWARD_MIN_BOOK_DEPTH_USDC: z.coerce.number().positive().default(2_000),
    /** Farthest the mark may sit from the carry forward, however the book reads. */
    FORWARD_MAX_BASIS_BPS: z.coerce.number().int().positive().max(2_000).default(300),
    /** Share of the contract's band and move limit left unused, so a mark is never at the edge. */
    FORWARD_SAFETY_BPS: z.coerce.number().int().nonnegative().max(5_000).default(50),
    /**
     * Alert when the contract's last mark is older than this, and trading is still open. Must exceed
     * the contract's minMarkInterval plus a tick, or every on-time mark alerts (checked at startup).
     */
    FORWARD_MARK_LATE_MS: z.coerce.number().int().positive().default(2 * 60 * 60_000),

    /**
     * Expiry (expiry-keeper.ts): an index sample this often in the fixing window. Must sit well
     * inside the contract's maxSampleGap (15 min), so one failed sample does not break the fixing.
     */
    FIXING_SAMPLE_INTERVAL_MS: z.coerce.number().int().positive().default(300_000),
    /** Close-outs per tick after settlement. */
    CLOSE_OUT_BATCH: z.coerce.number().int().positive().default(20),

    TIMESTAMP_SAFETY_SEC: z.coerce.number().int().nonnegative().default(15),
    DEADLINE_SEC: z.coerce.number().int().positive().default(60),
  })
  .superRefine((env, ctx) => {
    const kms = env.FORWARD_SIGNER_KMS_KEY_ID !== undefined;
    const raw = env.FORWARD_SIGNER_KEY !== undefined;
    if (kms === raw) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'set exactly one of FORWARD_SIGNER_KMS_KEY_ID and FORWARD_SIGNER_KEY' });
    }
    if (raw && env.CHAIN_ID === BASE_MAINNET) {
      ctx.addIssue({ code: z.ZodIssueCode.custom, message: 'on Base mainnet the forward signer must be a KMS key, not FORWARD_SIGNER_KEY' });
    }
  });

export type ForwardConfig = z.infer<typeof envSchema>;

export function loadForwardConfig(env: NodeJS.ProcessEnv = process.env): ForwardConfig {
  return envSchema.parse(env);
}
