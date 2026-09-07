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
  };
}

export function loadDeploymentAddresses(chainId: number): { matching: `0x${string}`; trade: `0x${string}` } {
  const d = getDeployment(chainId);
  return { matching: d.matching, trade: d.trade };
}
