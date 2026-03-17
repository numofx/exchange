import {
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
    assertPayloadConsistency(request, this.deps.tradeModuleAddress);

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

    const receipt = await this.publicClient.waitForTransactionReceipt({ hash: txHash });
    return {
      accepted: true,
      tx_hash: txHash,
      receipt_status: receipt.status,
      block_number: receipt.blockNumber.toString(),
    };
  }
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

export function assertPayloadConsistency(request: ExecuteMatchRequest, tradeModuleAddress: `0x${string}`): void {
  const expected = getAddress(tradeModuleAddress);
  const moduleAddress = getAddress(request.module_address);

  if (moduleAddress !== expected) {
    throw new Error(`module_address mismatch: expected ${expected}, got ${moduleAddress}`);
  }

  for (const [index, action] of request.actions.entries()) {
    const actionModule = getAddress(action.module);
    if (actionModule !== expected) {
      throw new Error(`actions[${index}].module mismatch: expected ${expected}, got ${actionModule}`);
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
