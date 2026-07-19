export { matchingAbi, tradeModuleAbi } from './generated/abis.js';
import { deployments, type ChainId } from './generated/deployments.js';

export { deployments, type ChainId };

export type Deployment = { matching: `0x${string}`; trade: `0x${string}` };

/** Deployed Matching + TradeModule addresses for a chain, or throws if unknown. */
export function getDeployment(chainId: number): Deployment {
  const key = String(chainId) as ChainId;
  const d = deployments[key];
  if (!d) {
    throw new Error(
      `no deployment for chainId ${chainId}; known: ${Object.keys(deployments).join(', ') || '(none)'}`,
    );
  }
  return d as Deployment;
}
