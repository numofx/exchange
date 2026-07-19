import type { Abi } from 'viem';
import { matchingAbi, tradeModuleAbi } from '@numo/abis';

export type ContractArtifacts = {
  matchingAbi: Abi;
  tradeModuleAbi: Abi;
};

export function loadContractArtifacts(): ContractArtifacts {
  return {
    matchingAbi: matchingAbi as unknown as Abi,
    tradeModuleAbi: tradeModuleAbi as unknown as Abi,
  };
}
