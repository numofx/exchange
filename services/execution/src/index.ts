import { buildApp } from './app.js';
import { loadConfig, loadDeploymentAddresses } from './config.js';
import { loadContractArtifacts } from './contracts.js';
import { MatchExecutor } from './executor.js';

const config = loadConfig();
const deploymentAddresses = loadDeploymentAddresses(config.matchingRepoPath, config.chainId);
const artifacts = loadContractArtifacts(config.matchingRepoPath);

const matchingAddress = config.matchingAddress ?? deploymentAddresses.matching;
const tradeModuleAddress = config.tradeModuleAddress ?? deploymentAddresses.trade;

const executor = new MatchExecutor(config, {
  matchingAbi: artifacts.matchingAbi,
  matchingAddress,
  tradeModuleAddress,
});

const app = buildApp({
  config,
  executor,
  matchingAddress,
  tradeModuleAddress,
});

app.listen({ host: config.host, port: config.port }).catch((error) => {
  app.log.error(error);
  process.exit(1);
});
