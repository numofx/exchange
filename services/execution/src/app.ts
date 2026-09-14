import Fastify, { type FastifyInstance, type FastifyReply } from 'fastify';
import { ZodError } from 'zod';
import { getAddress } from 'viem';

import type { AppConfig } from './config.js';
import { DISABLED_CANARY, type SettlementCanary } from './canary.js';
import type { MatchExecutor } from './executor.js';
import { executeMatchRequestSchema, withdrawRequestSchema } from './types.js';
import { WithdrawalRejectedError } from './withdrawal.js';

export function buildApp(args: {
  config: AppConfig;
  executor: Pick<MatchExecutor, 'execute'>;
  matchingAddress: `0x${string}`;
  tradeModuleAddress: `0x${string}`;
  canary?: Pick<SettlementCanary, 'snapshot'>;
  /** Submits signed withdrawals. Absent when they are not configured; POST /withdraw then answers 503. */
  withdrawer?: Pick<MatchExecutor, 'withdraw'>;
  withdrawal?: { moduleAddress: `0x${string}`; assetAddresses: readonly `0x${string}`[] };
}): FastifyInstance {
  const app = Fastify({ logger: true });

  app.get('/healthz', async () => ({
    status: 'ok',
    chain_id: args.config.chainId,
    dry_run: args.config.dryRun,
    wait_for_receipt: args.config.waitForReceipt,
    executor_address: getAddress(args.config.executorAddress),
    expected_action_owner: args.config.expectedActionOwner ? getAddress(args.config.expectedActionOwner) : null,
    expected_action_signer: args.config.expectedActionSigner ? getAddress(args.config.expectedActionSigner) : null,
    matching_address: getAddress(args.matchingAddress),
    trade_module_address: getAddress(args.tradeModuleAddress),
    withdrawal_module_address: args.withdrawal ? getAddress(args.withdrawal.moduleAddress) : null,
    withdrawal_assets: args.withdrawal ? args.withdrawal.assetAddresses.map((asset) => getAddress(asset)) : [],
    // Reported, not enforced. /healthz stays 200 on a canary failure unless
    // SETTLEMENT_CANARY_FAILS_HEALTHCHECK says otherwise -- see canary.ts for why.
    settlement_canary: args.canary?.snapshot() ?? DISABLED_CANARY,
  }));

  app.post('/', async (req, reply) => handleExecute(args.executor, req.body, reply));
  app.post('/execute', async (req, reply) => handleExecute(args.executor, req.body, reply));
  app.post('/withdraw', async (req, reply) => handleWithdraw(args.withdrawer, req.body, reply));

  return app;
}

async function handleExecute(executor: Pick<MatchExecutor, 'execute'>, body: unknown, reply: FastifyReply) {
  try {
    const request = executeMatchRequestSchema.parse(body);
    const result = await executor.execute(request);
    return reply.code(200).send(result);
  } catch (error) {
    return sendError(reply, error);
  }
}

/**
 * 200 with the receipt (or `receipt_status: 'timeout'` when the outcome is not yet known), 422 for a withdrawal that
 * breaks policy or would revert — with `revert` naming the revert — and 503 when withdrawals are not configured.
 */
async function handleWithdraw(withdrawer: Pick<MatchExecutor, 'withdraw'> | undefined, body: unknown, reply: FastifyReply) {
  if (!withdrawer) {
    return reply.code(503).send({ error: 'withdrawals are not enabled on this executor' });
  }
  try {
    const request = withdrawRequestSchema.parse(body);
    const result = await withdrawer.withdraw(request);
    return reply.code(200).send(result);
  } catch (error) {
    if (error instanceof WithdrawalRejectedError) {
      return reply.code(422).send(error.revert === undefined ? { error: error.message } : { error: error.message, revert: error.revert });
    }
    return sendError(reply, error);
  }
}

function sendError(reply: FastifyReply, error: unknown) {
  if (error instanceof ZodError) {
    return reply.code(400).send({ error: 'invalid request', details: error.flatten() });
  }

  const message = error instanceof Error ? error.message : 'unknown error';
  return reply.code(500).send({ error: message });
}
