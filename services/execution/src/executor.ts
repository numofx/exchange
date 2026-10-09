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
import { createKmsAccount } from '@numo/kms-signer';
import { createSerialQueue } from './serial-queue.js';
import { assertSignerIsOwner, type SubmittedAction } from './signer-guard.js';
import type { DepositRequest, DepositResponse, ExecuteMatchRequest, ExecuteMatchResponse, WithdrawRequest } from './types.js';
import {
  DepositBudget,
  DepositRejectedError,
  assertDepositPolicy,
  buildDepositArgs,
  creditedSubaccount,
  depositActionHash,
  depositRevertErrorsAbi,
  depositUnitsToLedger,
  formatDepositUnits,
} from './deposit.js';
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
  /**
   * Modules settled alongside the main one: the USDCcNGN-PERP module, which settles in its own
   * stack's cash. A request may name any one of them, but every action in it must name that same one.
   */
  additionalTradeModules?: readonly `0x${string}`[];
  /** Signed withdrawals. Absent when this deployment does not accept them; `withdraw` then refuses. */
  withdrawal?: {
    moduleAddress: `0x${string}`;
    assetAddresses: readonly `0x${string}`[];
  };
  /** Sponsored deposits. Absent unless DEPOSITS_ENABLED; `deposit` then refuses. */
  deposit?: NonNullable<AppConfig['deposit']>;
};

export class MatchExecutor {
  private readonly account: LocalAccount;
  private readonly chain;
  private readonly publicClient;
  private readonly walletClient;
  // Settlements, withdrawals and deposits share this EOA's nonce sequence; see serial-queue.ts.
  private readonly enqueueSend = createSerialQueue();
  private depositBudget?: DepositBudget;
  /**
   * Deposits by action hash, so a retried request (a client timeout, a double click) gets the same result instead of
   * a second broadcast. Kept for two hours: an action expires within one, after which it could not be resubmitted
   * anyway. Per executor task, which is a singleton.
   */
  private readonly depositsByHash = new Map<`0x${string}`, { at: number; result: Promise<DepositResponse> }>();

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

  /**
   * The one place an action reaches `Matching.verifyAndMatch`.
   *
   * Both callers -- settlement and withdrawal -- route through here so the signer guard is applied
   * once at the boundary rather than once per handler. A seventh module, or a third caller, inherits
   * it by construction instead of needing to remember it.
   *
   * The guard runs BEFORE the queue: a refusal costs no queue slot and no simulation. Everything
   * that differs between the two callers -- the ABI, and what a failed simulation means -- is passed
   * in, so this method decides nothing about them.
   */
  private async submitVerifyAndMatch(
    args: readonly [readonly SubmittedAction[], readonly `0x${string}`[], `0x${string}`],
    options: {
      abi: Abi;
      onSimulationError?: (error: unknown) => never;
      /** Runs after a successful simulation, before anything is broadcast. May throw to stop the send. */
      beforeSend?: () => void;
    },
  ): Promise<`0x${string}` | 'dry-run'> {
    assertSignerIsOwner(args[0]);

    return this.enqueueSend(async () => {
      try {
        await this.publicClient.simulateContract({
          account: this.account,
          address: this.deps.matchingAddress,
          abi: options.abi,
          functionName: 'verifyAndMatch',
          args,
        });
      } catch (error) {
        options.onSimulationError?.(error);
        throw error;
      }

      options.beforeSend?.();

      if (this.config.dryRun) {
        return 'dry-run' as const;
      }

      // The estimate runs against the latest block, the transaction lands in a later one, and the
      // two can take different paths: the perp's CashAsset skips interest accrual when it was
      // already touched this block -- as it was by the previous settlement -- and runs it in full a
      // block later, ~48% more gas once anything is borrowed (CngnPerpStackFork
      // .testDepositGasDependsOnWhetherTheCashWasTouchedThisBlock). An exact estimate then reverts
      // out of gas on the next settlement.
      const estimate = await this.publicClient.estimateContractGas({
        account: this.account,
        address: this.deps.matchingAddress,
        abi: options.abi,
        functionName: 'verifyAndMatch',
        args,
      });
      return this.walletClient.writeContract({
        account: this.account,
        address: this.deps.matchingAddress,
        abi: options.abi,
        functionName: 'verifyAndMatch',
        args,
        chain: this.chain,
        gas: withGasHeadroom(estimate),
      });
    });
  }

  async execute(request: ExecuteMatchRequest): Promise<ExecuteMatchResponse> {
    assertPayloadConsistency(request, {
      tradeModuleAddress: this.deps.tradeModuleAddress,
      additionalTradeModules: this.deps.additionalTradeModules,
      expectedActionOwner: this.config.expectedActionOwner,
      expectedActionSigner: this.config.expectedActionSigner,
    });

    const args = buildVerifyAndMatchArgs(request);

    const txHash = await this.submitVerifyAndMatch(args, { abi: this.deps.matchingAbi });

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

    const txHash = await this.submitVerifyAndMatch(args, {
      abi,
      onSimulationError: (error) => {
        const revert = describeSimulationRevert(error);
        if (revert !== undefined) {
          throw new WithdrawalRejectedError(`withdrawal would revert: ${revert}`, revert);
        }
        throw error;
      },
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

  /**
   * Submits one user-signed deposit through `Matching.verifyAndMatch`, the venue paying gas.
   *
   * Policy first (deposit.ts), then a simulation with the module's and the CashAsset's errors in the ABI, so a deposit
   * the chain would revert is refused by name and costs nothing. The hourly budget is spent only after the simulation
   * passes. Idempotent on the action hash: the same signed request returns the same result and is never sent twice.
   */
  deposit(request: DepositRequest): Promise<DepositResponse> {
    const deposit = this.deps.deposit;
    if (!deposit) {
      return Promise.reject(new DepositRejectedError('deposits are not enabled on this executor', undefined, 503));
    }
    const hash = depositActionHash(request);
    const now = Date.now();
    for (const [key, entry] of this.depositsByHash) {
      if (now - entry.at > 2 * 3_600_000) this.depositsByHash.delete(key);
    }
    const existing = this.depositsByHash.get(hash);
    if (existing) {
      return existing.result;
    }
    const result = this.submitDeposit(request, deposit);
    this.depositsByHash.set(hash, { at: now, result });
    // A refusal or an RPC failure sent nothing, so the same request may be tried again; only a broadcast is final.
    result.catch(() => this.depositsByHash.delete(hash));
    return result;
  }

  private async submitDeposit(
    request: DepositRequest,
    deposit: NonNullable<AppConfig['deposit']>,
  ): Promise<DepositResponse> {
    const data = assertDepositPolicy(request, { ...deposit, nowSeconds: Math.floor(Date.now() / 1000) });
    this.depositBudget ??= new DepositBudget(deposit.maxPerHour);

    const amounts = {
      amount_usdc: formatDepositUnits(data.amount),
      amount_units: data.amount.toString(),
      credited_cash_e18: depositUnitsToLedger(data.amount).toString(),
    };
    const txHash = await this.submitVerifyAndMatch(buildDepositArgs(request), {
      abi: [...this.deps.matchingAbi, ...depositRevertErrorsAbi] as Abi,
      onSimulationError: (error) => {
        const revert = describeSimulationRevert(error);
        if (revert !== undefined) {
          throw new DepositRejectedError(`deposit would revert: ${revert}`, revert);
        }
        throw error;
      },
      beforeSend: () => this.depositBudget!.take(),
    });

    if (txHash === 'dry-run') {
      return { accepted: true, tx_hash: 'dry-run', ...amounts };
    }
    try {
      const receipt = await this.publicClient.waitForTransactionReceipt({ hash: txHash, timeout: deposit.receiptTimeoutMs });
      const response: DepositResponse = { ...buildReceiptResponse(txHash, receipt), ...amounts };
      if (receipt.status === 'success') {
        response.subaccount_id = creditedSubaccount(request, this.deps.matchingAddress, receipt.logs);
      }
      return response;
    } catch (error) {
      if (error instanceof WaitForTransactionReceiptTimeoutError) {
        return { accepted: false, tx_hash: txHash, receipt_status: 'timeout', ...amounts };
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
        additionalTradeModules?: readonly `0x${string}`[];
        expectedActionOwner?: `0x${string}`;
        expectedActionSigner?: `0x${string}`;
      },
): void {
  const expectations =
    typeof tradeModuleAddressOrExpectations === 'string'
      ? { tradeModuleAddress: tradeModuleAddressOrExpectations }
      : tradeModuleAddressOrExpectations;
  const allowed = [expectations.tradeModuleAddress, ...(expectations.additionalTradeModules ?? [])].map((address) =>
    getAddress(address),
  );
  const moduleAddress = getAddress(request.module_address);

  if (!allowed.includes(moduleAddress)) {
    throw new Error(`module_address mismatch: expected one of ${allowed.join(', ')}, got ${moduleAddress}`);
  }
  // Every action names the request's own module: one fill never spans the spot and perp modules.
  const expected = moduleAddress;

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

/** Gas headroom over the estimate, in percent: the same 50% the perp keeper sends with. */
export const GAS_HEADROOM_PCT = 150n;
/**
 * And never less than this much over it. The accrual path costs a roughly fixed ~59k gas, not a
 * share of the call, so a percentage alone is thinnest on the smallest transactions.
 */
export const GAS_HEADROOM_MIN = 100_000n;

export function withGasHeadroom(estimate: bigint): bigint {
  const scaled = (estimate * GAS_HEADROOM_PCT) / 100n;
  return scaled > estimate + GAS_HEADROOM_MIN ? scaled : estimate + GAS_HEADROOM_MIN;
}
