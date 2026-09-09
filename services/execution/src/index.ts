import { buildApp } from './app.js';
import { SettlementCanary } from './canary.js';
import { loadConfig, loadDeploymentAddresses } from './config.js';
import { loadContractArtifacts } from './contracts.js';
import { MatchExecutor } from './executor.js';

// Probe mode, for the container health check. Runs before loadConfig on purpose:
// a health check that parses the full env can fail over a missing PRIVATE_KEY
// rather than over the server actually being unwell, which is the opposite of
// what a health check is for.
if (process.argv.includes('--healthcheck') || process.argv.includes('-healthcheck')) {
  const port = process.env.PORT ?? '8081';
  try {
    const response = await fetch(`http://127.0.0.1:${port}/healthz`, {
      signal: AbortSignal.timeout(3_000),
    });
    if (!response.ok) {
      process.stderr.write(`healthcheck: /healthz returned ${response.status}\n`);
      process.exit(1);
    }

    // The canary gates liveness only when explicitly asked to. Reading the flag from the
    // response rather than the environment keeps this probe free of loadConfig, which is
    // the point of running it before config parsing.
    const body = (await response.json()) as {
      settlement_canary?: { enabled?: boolean; ok?: boolean | null; failures?: unknown[] };
    };
    const canary = body.settlement_canary;
    if (process.env.SETTLEMENT_CANARY_FAILS_HEALTHCHECK === 'true' && canary?.enabled && canary.ok === false) {
      process.stderr.write(`healthcheck: settlement canary failing: ${JSON.stringify(canary.failures)}\n`);
      process.exit(1);
    }
    process.exit(0);
  } catch (error) {
    process.stderr.write(`healthcheck: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exit(1);
  }
}

const config = loadConfig();
const deploymentAddresses = loadDeploymentAddresses(config.chainId);
const artifacts = loadContractArtifacts();

const matchingAddress = config.matchingAddress ?? deploymentAddresses.matching;
const tradeModuleAddress = config.tradeModuleAddress ?? deploymentAddresses.trade;

const executor = new MatchExecutor(config, {
  matchingAbi: artifacts.matchingAbi,
  matchingAddress,
  tradeModuleAddress,
});

const canary = config.settlementCanary
  ? new SettlementCanary({
      rpcUrl: config.rpcUrl,
      chainId: config.chainId,
      manager: config.settlementCanary.manager,
      accountIds: config.settlementCanary.accountIds,
      intervalMs: config.settlementCanary.intervalMs,
      log: (level, message, fields) => {
        process.stdout.write(`${JSON.stringify({ level, msg: message, ...fields })}\n`);
      },
    })
  : undefined;
canary?.start();

const app = buildApp({
  config,
  executor,
  matchingAddress,
  tradeModuleAddress,
  canary,
});

app.listen({ host: config.host, port: config.port }).catch((error) => {
  app.log.error(error);
  process.exit(1);
});
