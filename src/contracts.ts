import { readFileSync } from 'node:fs';
import path from 'node:path';
import type { Abi } from 'viem';

export type ContractArtifacts = {
  matchingAbi: Abi;
  tradeModuleAbi: Abi;
};

export function loadContractArtifacts(repoPath: string): ContractArtifacts {
  return {
    matchingAbi: loadAbi(path.join(repoPath, 'out', 'Matching.sol', 'Matching.json')),
    tradeModuleAbi: loadAbi(path.join(repoPath, 'out', 'TradeModule.sol', 'TradeModule.json')),
  };
}

function loadAbi(artifactPath: string): Abi {
  const artifact = JSON.parse(readFileSync(artifactPath, 'utf8')) as { abi?: Abi };
  if (!artifact.abi) {
    throw new Error(`artifact missing abi: ${artifactPath}`);
  }
  return artifact.abi;
}
