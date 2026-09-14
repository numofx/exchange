import { BaseError, ContractFunctionRevertedError, decodeAbiParameters, getAddress, parseAbi } from 'viem';

import type { WithdrawRequest } from './types.js';

/**
 * Custom errors a withdrawal can revert with below Matching: the withdrawal module and its base, the wrapped
 * asset it pays out of, that asset's manager whitelist, and the account's risk manager. Matching's own `M_*` and
 * `OV_*` errors are already in its ABI. Listed so a rejected withdrawal is reported by name rather than as a bare
 * selector; `withdrawal.test.ts` pins every selector against the contracts.
 */
export const withdrawalRevertErrorsAbi = parseAbi([
  'error BM_NonceAlreadyUsed()',
  'error BM_OnlyMatching()',
  'error WM_InvalidFromAccount()',
  'error WM_InvalidWithdrawalActionLength()',
  'error WERC_CannotBeNegative()',
  'error WERC_InvalidSubId()',
  'error WERC_OnlyAccountOwner()',
  'error MW_UnknownManager()',
  'error BM_AccountUnderLiquidation()',
  'error BM_AdjustmentsPaused()',
  'error BM_AssetCapExceeded()',
  'error SRM_NoNegativeCash()',
  'error SRM_PortfolioBelowMargin()',
]);

/** A withdrawal this executor will not submit, because it breaks policy or the chain would revert it. No gas spent. */
export class WithdrawalRejectedError extends Error {
  constructor(
    message: string,
    /** The revert the simulation hit, by name when known. Absent for a policy rejection. */
    readonly revert?: string,
  ) {
    super(message);
    this.name = 'WithdrawalRejectedError';
  }
}

export type WithdrawalPolicy = {
  moduleAddress: `0x${string}`;
  /** The wrapped assets the module may pay out of. Anything else is refused before it is simulated. */
  assetAddresses: readonly `0x${string}`[];
  nowSeconds: number;
};

const WITHDRAWAL_DATA_PATTERN = /^0x[0-9a-fA-F]{128}$/;
const ADDRESS_WORD_PADDING = '0'.repeat(24);

/**
 * `abi.encode(WithdrawalData{address asset; uint256 assetAmount})`: exactly two static words and nothing else.
 * `assetAmount` is in the token's native decimals (6 for both wrapped USDC and cNGN).
 */
export function decodeWithdrawalData(data: string): { asset: `0x${string}`; amount: bigint } {
  if (!WITHDRAWAL_DATA_PATTERN.test(data)) {
    throw new WithdrawalRejectedError('action.data must be abi.encode(address asset, uint256 amount): exactly 64 bytes');
  }
  // Solidity's abi.decode reverts on an address word with dirty high bits; refuse it here rather than simulate it.
  if (data.slice(2, 26) !== ADDRESS_WORD_PADDING) {
    throw new WithdrawalRejectedError('action.data asset word is not a left-padded address');
  }
  const [asset, amount] = decodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], data as `0x${string}`);
  return { asset: getAddress(asset), amount };
}

/**
 * The checks made before a withdrawal is simulated. The chain enforces the signature, the owner's custody of the
 * subaccount and the nonce; these refuse what this executor should not spend a simulation, or a queue slot, on.
 */
export function assertWithdrawalPolicy(request: WithdrawRequest, policy: WithdrawalPolicy): void {
  const { action } = request;

  const expectedModule = getAddress(policy.moduleAddress);
  const actionModule = getAddress(action.module);
  if (actionModule !== expectedModule) {
    throw new WithdrawalRejectedError(`action.module must be the withdrawal module ${expectedModule}, got ${actionModule}`);
  }
  if (BigInt(action.subaccount_id) === 0n) {
    throw new WithdrawalRejectedError('action.subaccount_id must not be 0');
  }
  // Tokens always go to the owner. Until session keys are checked off-chain too, only the owner may sign.
  if (getAddress(action.owner) !== getAddress(action.signer)) {
    throw new WithdrawalRejectedError('action.signer must be action.owner; session-key withdrawals are not supported');
  }
  // ActionVerifier reverts only once block.timestamp is past the expiry, so an expiry of exactly now is still valid.
  if (BigInt(action.expiry) < BigInt(policy.nowSeconds)) {
    throw new WithdrawalRejectedError('action has expired');
  }

  const { asset, amount } = decodeWithdrawalData(action.data);
  if (!policy.assetAddresses.some((allowed) => getAddress(allowed) === asset)) {
    throw new WithdrawalRejectedError(`asset ${asset} is not withdrawable through this executor`);
  }
  if (amount === 0n) {
    throw new WithdrawalRejectedError('withdrawal amount must be greater than 0');
  }
}

/** `verifyAndMatch` arguments for one withdrawal. The module ignores `actionData`, so it is empty. */
export function buildWithdrawArgs(request: WithdrawRequest) {
  const { action } = request;
  return [
    [
      {
        subaccountId: BigInt(action.subaccount_id),
        nonce: BigInt(action.nonce),
        module: getAddress(action.module),
        data: action.data as `0x${string}`,
        expiry: BigInt(action.expiry),
        owner: getAddress(action.owner),
        signer: getAddress(action.signer),
      },
    ],
    [request.signature as `0x${string}`],
    '0x',
  ] as const;
}

/**
 * The revert a failed simulation carries: the custom error's name when the ABI knows it, the reason string for a
 * `require` or `Error(string)`, or the bare selector otherwise. Undefined when the failure was not a revert at all
 * (an RPC error or a timeout), which is not a statement about the withdrawal and must not be reported as one.
 */
export function describeSimulationRevert(error: unknown): string | undefined {
  if (!(error instanceof BaseError)) {
    return undefined;
  }
  const reverted = error.walk((cause) => cause instanceof ContractFunctionRevertedError);
  if (!(reverted instanceof ContractFunctionRevertedError)) {
    return undefined;
  }
  const errorName = reverted.data?.errorName;
  if (errorName !== undefined && errorName !== 'Error' && errorName !== 'Panic') {
    return errorName;
  }
  return reverted.reason ?? reverted.signature ?? 'execution reverted';
}
