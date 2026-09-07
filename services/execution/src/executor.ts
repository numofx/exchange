import {
  WaitForTransactionReceiptTimeoutError,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  getAddress,
  http,
  type Abi,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { AppConfig } from './config.js';
import type { ExecuteMatchRequest, ExecuteMatchResponse } from './types.js';

export type ExecutorDependencies = {
  matchingAbi: Abi;
  matchingAddress: `0x${string}`;
  tradeModuleAddress: `0x${string}`;
};

export class MatchExecutor {
  private readonly account;
  private readonly chain;
  private readonly publicClient;
  private readonly walletClient;

  constructor(
    private readonly config: AppConfig,
    private readonly deps: ExecutorDependencies,
  ) {
    this.account = privateKeyToAccount(config.privateKey);
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

    await this.publicClient.simulateContract({
      account: this.account,
      address: this.deps.matchingAddress,
      abi: this.deps.matchingAbi,
      functionName: 'verifyAndMatch',
      args,
    });

    if (this.config.dryRun) {
      return { accepted: true, tx_hash: 'dry-run' };
    }

    const txHash = await this.walletClient.writeContract({
      account: this.account,
      address: this.deps.matchingAddress,
      abi: this.deps.matchingAbi,
      functionName: 'verifyAndMatch',
      args,
      chain: this.chain,
    });

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
