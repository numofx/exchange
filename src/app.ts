import Fastify, { type FastifyInstance, type FastifyReply } from 'fastify';
import { ZodError } from 'zod';
import { getAddress } from 'viem';

import type { AppConfig } from './config.js';
import type { MatchExecutor } from './executor.js';
import { executeMatchRequestSchema } from './types.js';

export function buildApp(args: {
  config: AppConfig;
  executor: Pick<MatchExecutor, 'execute'>;
  matchingAddress: `0x${string}`;
  tradeModuleAddress: `0x${string}`;
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
    matching_repo_path: args.config.matchingRepoPath,
    matching_address: getAddress(args.matchingAddress),
    trade_module_address: getAddress(args.tradeModuleAddress),
  }));

  app.post('/', async (req, reply) => handleExecute(args.executor, req.body, reply));
  app.post('/execute', async (req, reply) => handleExecute(args.executor, req.body, reply));

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

function sendError(reply: FastifyReply, error: unknown) {
  if (error instanceof ZodError) {
    return reply.code(400).send({ error: 'invalid request', details: error.flatten() });
  }

  const message = error instanceof Error ? error.message : 'unknown error';
  return reply.code(500).send({ error: message });
}
