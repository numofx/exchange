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
  /** Subaccount under MANAGER, owned by the keeper EOA, funded with the stack's cash, that bids. */
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
  /**
   * The manager whose accounts this keeper liquidates: the perp SRM (numo-perp-keeper) or the
   * MarginEngine (numo-engine-keeper). The auction settles each account through it before an auction
   * starts and before every bid (DutchAuction calls settlePerpsWithIndex, which on the engine also
   * realises every future's VM), so nothing here is manager-specific beyond the address. SRM is the
   * perp keeper's original name for it and is still read.
   */
  MANAGER: address.optional(),
  SRM: address.optional(),
  AUCTION: address,
  CASH: address,
  PERP: address,
  /** The cNGN future, under the MarginEngine: its cap is watched in /health alongside the perp's. */
  FUTURE: address.optional(),
  SECURITY_MODULE_ACCOUNT: z.coerce.bigint(),
  /** The MarginEngine's VM pool (MARGIN_ENGINE.json poolAccount): never auctioned, never a candidate. */
  POOL_ACCOUNT: z.coerce.bigint().optional(),
  /** Block the stack was deployed at: account discovery scans logs from here. */
  START_BLOCK: z.coerce.bigint(),
  LOG_CHUNK_BLOCKS: z.coerce.bigint().default(10_000n),
  /**
   * Account discovery scans logs only this many blocks behind the head it read. The RPC is load-balanced:
   * the head comes from one node and the logs from another, and a node behind returns no logs, not an
   * error, for blocks it has not imported, so a scan up to the head can skip an AccountCreated for good.
   */
  SCAN_CONFIRMATIONS: z.coerce.bigint().nonnegative().default(3n),

  POLL_INTERVAL_MS: z.coerce.number().int().positive().default(15_000),
  /**
   * Serves GET /health with the last pass's time and outcome and whether this is a dry run, for the
   * perp enable gate (propose_perp_enable_batch.py) to confirm a live keeper. Unset: no server.
   */
  HEALTH_PORT: z.coerce.number().int().positive().optional(),
  HEALTH_HOST: z.string().default('127.0.0.1'),
  MIN_SOLVENT_DISCOUNT_BPS: z.coerce.bigint().default(200n),
  /**
   * An auction open longer than this is alerted (Slack): while it runs the owner cannot trade, so a
   * long one means the keeper is not finishing it (no cash, no discount, a sliver nobody takes).
   */
  AUCTION_OPEN_WARN_MS: z.coerce.number().int().positive().default(10 * 60_000),
  /** Smallest share of an account worth bidding on, as a percentage. */
  MIN_BID_PERCENT: z.coerce.number().positive().max(100).default(1),
  /**
   * Largest bid, in USD of margin it ties up (see KeeperRules.maxBidUsd). Unset: no cap. A launch
   * value keeps one bad auction from taking the keeper's whole book in a single bid.
   */
  MAX_BID_USD: z.coerce.number().positive().optional().transform((value) => (value === undefined ? null : parseUnits(String(value), 18))),

  /**
   * The perp stack's cNGN escrow (risk-core deployments CNGN_PERP_COLLATERAL.json `escrow`), once
   * cNGN is margin. Unset: accounts are read as cash-and-perp only, and a bid on an account that
   * does hold cNGN is still correct, just priced without the haircut below.
   */
  CNGN_ESCROW: address.optional(),
  /**
   * Haircut the keeper takes on cNGN it is paid in, in bps of its index value: it bids an insolvent
   * auction once the payout covers the deficit plus this much of the cNGN, and reads a solvent
   * portfolio's value net of it. The SRM credits cNGN at 50%; a keeper that waited for THAT
   * valuation would let the auction run to its most expensive second (see the runbook's
   * "cNGN as margin": $7,195 at the end against $2,788 bid early, on the 40% drill).
   */
  CNGN_HAIRCUT_BPS: z.coerce.bigint().nonnegative().max(10_000n).default(1_000n),
  /**
   * Most cNGN the keeper will hold across its accounts, in whole cNGN. A bid that would push it
   * past this is sized down to the room left, not skipped. Unset: no limit. Inherited cNGN is
   * reported (`keeper-cngn-inventory`) and left for an operator to sell on spot or hold.
   */
  MAX_CNGN_INVENTORY: z.coerce.number().positive().optional().transform((value) => (value === undefined ? null : parseUnits(String(value), 18))),

  MIN_SECURITY_MODULE_USD: usd.default(1000),
  MIN_KEEPER_CASH_USD: usd.default(1000),
  MIN_KEEPER_ETH: z.coerce.number().nonnegative().default(0.005).transform((value) => parseUnits(String(value), 18)),
  OI_CAP_WARN_BPS: z.coerce.bigint().default(8_000n),
});

type Parsed = z.infer<typeof envSchema>;
export type Config = Omit<Parsed, 'MANAGER' | 'SRM'> & { MANAGER: Parsed['SUB_ACCOUNTS'] };

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const { SRM, MANAGER, ...rest } = envSchema.parse(env);
  if (MANAGER && SRM && MANAGER !== SRM) throw new Error(`MANAGER ${MANAGER} and SRM ${SRM} disagree: set one`);
  const manager = MANAGER ?? SRM;
  if (!manager) throw new Error('MANAGER (or SRM) is required: the manager whose accounts this keeper liquidates');
  return { ...rest, MANAGER: manager };
}
