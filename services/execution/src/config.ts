import 'dotenv/config';

import { z } from 'zod';
import { getAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { getDeployment } from '@numo/abis';

const envSchema = z.object({
  PORT: z.coerce.number().int().positive().default(8081),
  HOST: z.string().default('0.0.0.0'),
  RPC_URL: z.string().url(),
  PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  CHAIN_ID: z.coerce.number().int().positive(),
  MATCHING_ADDRESS: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  TRADE_MODULE_ADDRESS: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  EXPECTED_ACTION_OWNER: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  EXPECTED_ACTION_SIGNER: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  DRY_RUN: z.union([z.literal('true'), z.literal('false')]).default('false'),
  WAIT_FOR_RECEIPT: z.union([z.literal('true'), z.literal('false')]).default('false'),
  // viem's own default is 180s. That is longer than the matcher's HTTP client will
  // wait, so the bound is stated here rather than inherited: EXECUTOR_TIMEOUT on the
  // matcher must exceed this value, or the matcher abandons a request that is still
  // in flight and retries it against a nonce that has not settled yet.
  RECEIPT_TIMEOUT_MS: z.coerce.number().int().positive().default(60_000),
  // Settlement canary. Unset SETTLEMENT_CANARY_MANAGER disables it entirely, so a chain
  // or environment without a risk manager is not forced to invent one.
  SETTLEMENT_CANARY_MANAGER: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  SETTLEMENT_CANARY_ACCOUNTS: z.string().default(''),
  SETTLEMENT_CANARY_INTERVAL_MS: z.coerce.number().int().positive().default(60_000),
  // Off by default, and the default is the considered position rather than caution: a stale
  // oracle is not fixed by replacing this container. Failing the health check would drop the
  // API out of the target group and flap tasks while the actual fault is off-box. Turn it on
  // only if you would rather the venue be visibly down than quietly unable to settle.
  SETTLEMENT_CANARY_FAILS_HEALTHCHECK: z.union([z.literal('true'), z.literal('false')]).default('false'),
  // Without this the canary logs a line and reaches nobody. There is no CloudWatch alarm on the
  // log group, so the webhook IS the alerting path, not a supplement to it.
  ALERT_WEBHOOK_URL: z.string().url().optional().or(z.literal('')),
  SETTLEMENT_CANARY_ALERT_REPEAT_CHECKS: z.coerce.number().int().nonnegative().default(30),
});

export type AppConfig = {
  port: number;
  host: string;
  rpcUrl: string;
  privateKey: `0x${string}`;
  chainId: number;
  matchingAddress?: `0x${string}`;
  tradeModuleAddress?: `0x${string}`;
  executorAddress: `0x${string}`;
  expectedActionOwner?: `0x${string}`;
  expectedActionSigner?: `0x${string}`;
  dryRun: boolean;
  waitForReceipt: boolean;
  receiptTimeoutMs: number;
  settlementCanary?: {
    manager: `0x${string}`;
    accountIds: number[];
    intervalMs: number;
    failsHealthcheck: boolean;
    alertWebhookUrl?: string;
    alertRepeatAfterChecks: number;
  };
};

export function loadConfig(): AppConfig {
  const parsed = envSchema.parse(process.env);
  const executorAddress = privateKeyToAccount(parsed.PRIVATE_KEY as `0x${string}`).address;

  return {
    port: parsed.PORT,
    host: parsed.HOST,
    rpcUrl: parsed.RPC_URL,
    privateKey: parsed.PRIVATE_KEY as `0x${string}`,
    chainId: parsed.CHAIN_ID,
    matchingAddress: parsed.MATCHING_ADDRESS ? (parsed.MATCHING_ADDRESS as `0x${string}`) : undefined,
    tradeModuleAddress: parsed.TRADE_MODULE_ADDRESS ? (parsed.TRADE_MODULE_ADDRESS as `0x${string}`) : undefined,
    executorAddress,
    expectedActionOwner: parsed.EXPECTED_ACTION_OWNER ? (getAddress(parsed.EXPECTED_ACTION_OWNER) as `0x${string}`) : undefined,
    expectedActionSigner: parsed.EXPECTED_ACTION_SIGNER ? (getAddress(parsed.EXPECTED_ACTION_SIGNER) as `0x${string}`) : undefined,
    dryRun: parsed.DRY_RUN === 'true',
    waitForReceipt: parsed.WAIT_FOR_RECEIPT === 'true',
    receiptTimeoutMs: parsed.RECEIPT_TIMEOUT_MS,
    settlementCanary: parsed.SETTLEMENT_CANARY_MANAGER
      ? {
          manager: getAddress(parsed.SETTLEMENT_CANARY_MANAGER) as `0x${string}`,
          accountIds: parseAccountIds(parsed.SETTLEMENT_CANARY_ACCOUNTS),
          intervalMs: parsed.SETTLEMENT_CANARY_INTERVAL_MS,
          failsHealthcheck: parsed.SETTLEMENT_CANARY_FAILS_HEALTHCHECK === 'true',
          alertWebhookUrl: parsed.ALERT_WEBHOOK_URL ? parsed.ALERT_WEBHOOK_URL : undefined,
          alertRepeatAfterChecks: parsed.SETTLEMENT_CANARY_ALERT_REPEAT_CHECKS,
        }
      : undefined,
  };
}

/**
 * A canary with no accounts would report healthy while checking nothing, which is worse
 * than having no canary at all -- so an empty or malformed list is a startup failure, not
 * a silently empty set.
 */
function parseAccountIds(raw: string): number[] {
  const ids = raw
    .split(',')
    .map((part) => part.trim())
    .filter((part) => part.length > 0)
    .map((part) => {
      if (!/^\d+$/.test(part)) {
        throw new Error(`SETTLEMENT_CANARY_ACCOUNTS: "${part}" is not a subaccount id`);
      }
      return Number(part);
    });

  if (ids.length === 0) {
    throw new Error('SETTLEMENT_CANARY_MANAGER is set but SETTLEMENT_CANARY_ACCOUNTS is empty');
  }
  return ids;
}

export function loadDeploymentAddresses(chainId: number): { matching: `0x${string}`; trade: `0x${string}` } {
  const d = getDeployment(chainId);
  return { matching: d.matching, trade: d.trade };
}
