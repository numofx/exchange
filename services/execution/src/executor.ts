import {
  WaitForTransactionReceiptTimeoutError,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  getAddress,
  http,
  type Abi,
  type LocalAccount,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { AppConfig } from './config.js';
import { createKmsAccount } from './kms-signer.js';
import { createSerialQueue } from './serial-queue.js';
import type { ExecuteMatchRequest, ExecuteMatchResponse, WithdrawRequest } from './types.js';
import {
  WithdrawalRejectedError,
  assertWithdrawalPolicy,
  buildWithdrawArgs,
  describeSimulationRevert,
  withdrawalRevertErrorsAbi,
} from './withdrawal.js';

export type ExecutorDependencies = {
  matchingAbi: Abi;
  matchingAddress: `0x${string}`;
  tradeModuleAddress: `0x${string}`;
  /** Signed withdrawals. Absent when this deployment does not accept them; `withdraw` then refuses. */
  withdrawal?: {
    moduleAddress: `0x${string}`;
    assetAddresses: readonly `0x${string}`[];
  };
};

export class MatchExecutor {
  private readonly account: LocalAccount;
  private readonly chain;
  private readonly publicClient;
  private readonly walletClient;
  // Settlements and withdrawals share this EOA's nonce sequence; see serial-queue.ts.
  private readonly enqueueSend = createSerialQueue();

  /**
   * Resolves the signing account, then builds the executor.
   *
   * A KMS account cannot be built in a constructor: its address comes from the key itself, which is
   * a network round trip. Done here rather than lazily so a key that is missing, the wrong spec, or
   * not permitted to the task role stops the process at boot instead of at the first settlement.
   */
  static async create(config: AppConfig, deps: ExecutorDependencies): Promise<MatchExecutor> {
    const account = config.kmsKeyId
      ? await createKmsAccount(config.kmsKeyId)
      : privateKeyToAccount(config.privateKey as `0x${string}`);
    // config.executorAddress is the placeholder when signing through KMS, because loadConfig has no
    // way to ask the key. /healthz reports it, so it is filled in before anything can read it.
    config.executorAddress = account.address;
    return new MatchExecutor(config, deps, account);
  }

  private constructor(
    private readonly config: AppConfig,
    private readonly deps: ExecutorDependencies,
    account: LocalAccount,
  ) {
    this.account = account;
    this.chain = defineChain({
      id: config.chainId,
      name: `chain-${config.chainId}`,
      nativeCurrency: { name: 'Native', symbol: 'ETH', decimals: 18 },
      rpcUrls: {
        default: { http: [config.rpcUrl] },
      },
    });
    this.publicClient = createPublicClient({ chain: this.chain, transport: http(config.rpcUrl) });
    this.walletClient = createWalletClient({ account: this.account, chain: this.chain, transport: http(config.rpcUrl) });
  }

  async execute(request: ExecuteMatchRequest): Promise<ExecuteMatchResponse> {
    assertPayloadConsistency(request, {
      tradeModuleAddress: this.deps.tradeModuleAddress,
      expectedActionOwner: this.config.expectedActionOwner,
      expectedActionSigner: this.config.expectedActionSigner,
    });

    const args = buildVerifyAndMatchArgs(request);

    const txHash = await this.enqueueSend(async () => {
      await this.publicClient.simulateContract({
        account: this.account,
        address: this.deps.matchingAddress,
        abi: this.deps.matchingAbi,
        functionName: 'verifyAndMatch',
        args,
      });

      if (this.config.dryRun) {
        return 'dry-run' as const;
      }

      return this.walletClient.writeContract({
        account: this.account,
        address: this.deps.matchingAddress,
        abi: this.deps.matchingAbi,
        functionName: 'verifyAndMatch',
        args,
        chain: this.chain,
      });
    });

    if (txHash === 'dry-run') {
      return { accepted: true, tx_hash: 'dry-run' };
    }

    if (!this.config.waitForReceipt) {
      return { accepted: true, tx_hash: txHash };
    }

    try {
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash: txHash,
        timeout: this.config.receiptTimeoutMs,
      });
      return buildReceiptResponse(txHash, receipt);
    } catch (error) {
      if (error instanceof WaitForTransactionReceiptTimeoutError) {
        // Report the unknown outcome rather than throwing. A thrown error reaches
        // the matcher as a plain failure, and the matcher retries plain failures --
        // which would broadcast a second verifyAndMatch for a transaction that is
        // still pending. Naming the outcome lets the matcher decline to retry.
        return { accepted: false, tx_hash: txHash, receipt_status: 'timeout' };
      }
      throw error;
    }
  }

  /**
   * Submits one user-signed withdrawal through `Matching.verifyAndMatch`.
   *
   * Policy is checked first, then the call is simulated with the withdrawal module's and the assets' errors in the
   * ABI: a withdrawal the chain would revert is refused with its revert named, and costs no gas. Only then is it
   * broadcast, in the same queue as settlements. The receipt wait is bounded by WITHDRAWAL_RECEIPT_TIMEOUT_MS; past
   * it the outcome is reported as unknown, never as failed, because the transaction may still mine.
   */
  async withdraw(request: WithdrawRequest): Promise<ExecuteMatchResponse> {
    const withdrawal = this.deps.withdrawal;
    if (!withdrawal) {
      throw new WithdrawalRejectedError('withdrawals are not enabled on this executor');
    }

    assertWithdrawalPolicy(request, {
      moduleAddress: withdrawal.moduleAddress,
      assetAddresses: withdrawal.assetAddresses,
      nowSeconds: Math.floor(Date.now() / 1000),
    });

    const args = buildWithdrawArgs(request);
    const abi = [...this.deps.matchingAbi, ...withdrawalRevertErrorsAbi] as Abi;

    const txHash = await this.enqueueSend(async () => {
      try {
        await this.publicClient.simulateContract({
          account: this.account,
          address: this.deps.matchingAddress,
          abi,
          functionName: 'verifyAndMatch',
          args,
        });
      } catch (error) {
        const revert = describeSimulationRevert(error);
        if (revert !== undefined) {
          throw new WithdrawalRejectedError(`withdrawal would revert: ${revert}`, revert);
        }
        throw error;
      }

      if (this.config.dryRun) {
        return 'dry-run' as const;
      }

      return this.walletClient.writeContract({
        account: this.account,
        address: this.deps.matchingAddress,
        abi,
        functionName: 'verifyAndMatch',
        args,
        chain: this.chain,
      });
    });

    if (txHash === 'dry-run') {
      return { accepted: true, tx_hash: 'dry-run' };
    }

    try {
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash: txHash,
        timeout: this.config.withdrawalReceiptTimeoutMs,
      });
      return buildReceiptResponse(txHash, receipt);
    } catch (error) {
      if (error instanceof WaitForTransactionReceiptTimeoutError) {
        return { accepted: false, tx_hash: txHash, receipt_status: 'timeout' };
      }
      throw error;
    }
  }
}

// viem resolves normally on a reverted receipt -- `status` is a field on the result,
// not a thrown error. Reporting it without acting on it is how an on-chain revert
// became an accepted fill in the matcher's database.
export function buildReceiptResponse(
  txHash: `0x${string}`,
  receipt: { status: 'success' | 'reverted'; blockNumber: bigint },
): ExecuteMatchResponse {
  return {
    accepted: receipt.status === 'success',
    tx_hash: txHash,
    receipt_status: receipt.status,
    block_number: receipt.blockNumber.toString(),
  };
}

export function buildVerifyAndMatchArgs(request: ExecuteMatchRequest) {
  const actions = request.actions.map((action) => ({
    subaccountId: BigInt(action.subaccount_id),
    nonce: BigInt(action.nonce),
    module: getAddress(action.module),
    data: action.data as `0x${string}`,
    expiry: BigInt(action.expiry),
    owner: getAddress(action.owner),
    signer: getAddress(action.signer),
  }));

  const signatures = request.signatures as `0x${string}`[];
  const actionData = encodeOrderData(request);

  return [actions, signatures, actionData] as const;
}

export function assertPayloadConsistency(
  request: ExecuteMatchRequest,
  tradeModuleAddressOrExpectations:
    | `0x${string}`
    | {
        tradeModuleAddress: `0x${string}`;
        expectedActionOwner?: `0x${string}`;
        expectedActionSigner?: `0x${string}`;
      },
): void {
  const expectations =
    typeof tradeModuleAddressOrExpectations === 'string'
      ? { tradeModuleAddress: tradeModuleAddressOrExpectations }
      : tradeModuleAddressOrExpectations;
  const expected = getAddress(expectations.tradeModuleAddress);
  const moduleAddress = getAddress(request.module_address);

  if (moduleAddress !== expected) {
    throw new Error(`module_address mismatch: expected ${expected}, got ${moduleAddress}`);
  }

  for (const [index, action] of request.actions.entries()) {
    const actionModule = getAddress(action.module);
    if (actionModule !== expected) {
      throw new Error(`actions[${index}].module mismatch: expected ${expected}, got ${actionModule}`);
    }

    if (expectations.expectedActionOwner) {
      const actionOwner = getAddress(action.owner);
      if (actionOwner !== expectations.expectedActionOwner) {
        throw new Error(`actions[${index}].owner mismatch: expected ${expectations.expectedActionOwner}, got ${actionOwner}`);
      }
    }

    if (expectations.expectedActionSigner) {
      const actionSigner = getAddress(action.signer);
      if (actionSigner !== expectations.expectedActionSigner) {
        throw new Error(`actions[${index}].signer mismatch: expected ${expectations.expectedActionSigner}, got ${actionSigner}`);
      }
    }
  }
}

function encodeOrderData(request: ExecuteMatchRequest): `0x${string}` {
  return encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'takerAccount', type: 'uint256' },
          { name: 'takerFee', type: 'uint256' },
          {
            name: 'fillDetails',
            type: 'tuple[]',
            components: [
              { name: 'filledAccount', type: 'uint256' },
              { name: 'amountFilled', type: 'uint256' },
              { name: 'price', type: 'int256' },
              { name: 'fee', type: 'uint256' },
            ],
          },
          { name: 'managerData', type: 'bytes' },
        ],
      },
    ],
    [
      {
        takerAccount: BigInt(request.order_data.taker_account),
        takerFee: BigInt(request.order_data.taker_fee),
        fillDetails: request.order_data.fill_details.map((fill) => ({
          filledAccount: BigInt(fill.filled_account),
          amountFilled: BigInt(fill.amount_filled),
          price: BigInt(fill.price),
          fee: BigInt(fill.fee),
        })),
        managerData: request.order_data.manager_data as `0x${string}`,
      },
    ],
  );
}
