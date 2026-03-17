import 'dotenv/config';

import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { z } from 'zod';

const envSchema = z.object({
  PORT: z.coerce.number().int().positive().default(8081),
  HOST: z.string().default('0.0.0.0'),
  RPC_URL: z.string().url(),
  PRIVATE_KEY: z.string().regex(/^0x[0-9a-fA-F]{64}$/),
  CHAIN_ID: z.coerce.number().int().positive(),
  MATCHING_REPO_PATH: z.string().default('../options/matching'),
  MATCHING_ADDRESS: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  TRADE_MODULE_ADDRESS: z.string().regex(/^0x[0-9a-fA-F]{40}$/).optional().or(z.literal('')),
  DRY_RUN: z.union([z.literal('true'), z.literal('false')]).default('false'),
  WAIT_FOR_RECEIPT: z.union([z.literal('true'), z.literal('false')]).default('false'),
});

export type AppConfig = {
  port: number;
  host: string;
  rpcUrl: string;
  privateKey: `0x${string}`;
  chainId: number;
  matchingRepoPath: string;
  matchingAddress?: `0x${string}`;
  tradeModuleAddress?: `0x${string}`;
  dryRun: boolean;
  waitForReceipt: boolean;
};

export function loadConfig(): AppConfig {
  const parsed = envSchema.parse(process.env);

  return {
    port: parsed.PORT,
    host: parsed.HOST,
    rpcUrl: parsed.RPC_URL,
    privateKey: parsed.PRIVATE_KEY as `0x${string}`,
    chainId: parsed.CHAIN_ID,
    matchingRepoPath: path.resolve(process.cwd(), parsed.MATCHING_REPO_PATH),
    matchingAddress: parsed.MATCHING_ADDRESS ? (parsed.MATCHING_ADDRESS as `0x${string}`) : undefined,
    tradeModuleAddress: parsed.TRADE_MODULE_ADDRESS ? (parsed.TRADE_MODULE_ADDRESS as `0x${string}`) : undefined,
    dryRun: parsed.DRY_RUN === 'true',
    waitForReceipt: parsed.WAIT_FOR_RECEIPT === 'true',
  };
}

export function loadDeploymentAddresses(repoPath: string, chainId: number): { matching: `0x${string}`; trade: `0x${string}` } {
  const deploymentPath = path.join(repoPath, 'deployments', String(chainId), 'matching.json');
  if (!existsSync(deploymentPath)) {
    throw new Error(`missing deployment file: ${deploymentPath}`);
  }

  const raw = JSON.parse(readFileSync(deploymentPath, 'utf8')) as { matching?: string; trade?: string };
  if (!raw.matching || !raw.trade) {
    throw new Error(`deployment file missing matching or trade address: ${deploymentPath}`);
  }

  return {
    matching: raw.matching as `0x${string}`,
    trade: raw.trade as `0x${string}`,
  };
}
