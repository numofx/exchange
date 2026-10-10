import {
  WaitForTransactionReceiptTimeoutError,
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  http,
  type Abi,
  type LocalAccount,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { AppConfig } from './config.js';
import { createKmsAccount } from '@numo/kms-signer';
import { createSerialQueue } from './serial-queue.js';
import { NonceTracker } from './nonce-tracker.js';
import { broadcastWithNonce } from './broadcast.js';
import { readAtOrAfter } from './pinned-read.js';
import { assertSignerIsOwner, type SubmittedAction } from './signer-guard.js';
import type { DepositRequest, DepositResponse, ExecuteMatchRequest, ExecuteMatchResponse, WithdrawRequest } from './types.js';
import { SponsorGate, PROVISIONAL_SPONSORED_GAS, receiptCostWei } from './sponsor-gate.js';
import {
  DepositRejectedError,
  assertDepositPolicy,
  assertPermitPolicy,
  buildDepositArgs,
  buildPermitArgs,
  permitAbi,
  wrappedAssetAbi,
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
    /** Gas sponsored withdrawals may spend per rolling hour. No floor: users can always withdraw. */
    maxGasWeiPerHour: bigint;
    alertWebhookUrl?: string;
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
  // Nonces are tracked locally, inside that queue; see nonce-tracker.ts.
  private readonly nonces: NonceTracker;
  /** Floor and gas budget for sponsored deposits; undefined unless deposits are configured. */
  readonly depositGate?: SponsorGate;
  /** Gas budget (no floor) for sponsored withdrawals; undefined unless withdrawals are configured. */
  readonly withdrawalGate?: SponsorGate;
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
    this.nonces = new NonceTracker(() => this.publicClient.getTransactionCount({ address: this.account.address, blockTag: 'pending' }));
    const readBalance = () => this.publicClient.getBalance({ address: this.account.address });
    const log = (level: string, message: string, fields: Record<string, unknown>) =>
      process.stdout.write(`${JSON.stringify({ level, msg: message, ...fields })}\n`);
    if (deps.deposit) {
      this.depositGate = new SponsorGate({
        subject: 'deposits',
        reject: (message) => new DepositRejectedError(message, undefined, 503),
        minExecutorWei: deps.deposit.minExecutorWei,
        maxGasWeiPerHour: deps.deposit.maxGasWeiPerHour,
        readBalance,
        alertWebhookUrl: deps.deposit.alertWebhookUrl,
        log,
      });
    }
    if (deps.withdrawal) {
      this.withdrawalGate = new SponsorGate({
        subject: 'withdrawals',
        reject: (message) => new WithdrawalRejectedError(message, undefined, 503),
        maxGasWeiPerHour: deps.withdrawal.maxGasWeiPerHour,
        readBalance,
        alertWebhookUrl: deps.withdrawal.alertWebhookUrl,
        log,
      });
    }
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
      /**
       * A block the simulation and estimate must see: the block of a transaction this one depends on, such as a
       * deposit's permit. Both are pinned to it rather than run at "latest"; see pinned-read.ts.
       */
      afterBlock?: bigint;
    },
  ): Promise<`0x${string}` | 'dry-run'> {
    assertSignerIsOwner(args[0]);

    return this.enqueueSend(async () => {
      try {
        await readAtOrAfter(options.afterBlock, (at) =>
          this.publicClient.simulateContract({
            account: this.account,
            address: this.deps.matchingAddress,
            abi: options.abi,
            functionName: 'verifyAndMatch',
            args,
            ...at,
          }),
        );
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
      const estimate = await readAtOrAfter(options.afterBlock, (at) =>
        this.publicClient.estimateContractGas({
          account: this.account,
          address: this.deps.matchingAddress,
          abi: options.abi,
          functionName: 'verifyAndMatch',
          args,
          ...at,
        }),
      );
      return this.broadcast({
        address: this.deps.matchingAddress,
        abi: options.abi,
        functionName: 'verifyAndMatch',
        args,
        gas: withGasHeadroom(estimate),
      });
    });
  }

  /** Sends with a locally tracked nonce. Call only inside enqueueSend. */
  private broadcast(call: { address: `0x${string}`; abi: Abi; functionName: string; args: readonly unknown[]; gas?: bigint }): Promise<`0x${string}`> {
    const data = encodeFunctionData({ abi: call.abi, functionName: call.functionName, args: call.args } as never);
    return broadcastWithNonce({
      nonces: this.nonces,
      sign: async (nonce) => {
        const prepared = await this.walletClient.prepareTransactionRequest({
          account: this.account,
          chain: this.chain,
          to: call.address,
          data,
          gas: call.gas,
          nonce,
        } as never);
        return this.walletClient.signTransaction(prepared as never) as Promise<`0x${string}`>;
      },
      sendRaw: (serializedTransaction) => this.walletClient.sendRawTransaction({ serializedTransaction }),
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

    const gate = this.withdrawalGate!;
    await gate.check();
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
      beforeSend: () => gate.assertBudget(),
    });

    if (txHash === 'dry-run') {
      return { accepted: true, tx_hash: 'dry-run' };
    }

    try {
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash: txHash,
        timeout: this.config.withdrawalReceiptTimeoutMs,
      });
      gate.record(receiptCostWei(receipt));
      return buildReceiptResponse(txHash, receipt);
    } catch (error) {
      if (error instanceof WaitForTransactionReceiptTimeoutError) {
        gate.record(PROVISIONAL_SPONSORED_GAS * (await this.publicClient.getGasPrice().catch(() => 0n)));
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

  /**
   * Submits the deposit's USDC permit when the allowance does not already cover it, and waits for it to mine. Returns
   * the permit's hash and block, or undefined when it was not needed; the deposit is simulated at that block, because
   * a node that has not imported it yet still reads the allowance as it was before.
   *
   * Already covered -- an earlier approve, or this very permit submitted first by someone else (front-run) -- means
   * the permit is skipped, not failed. A permit the token refuses (expired, a spent permit nonce, not signed by the
   * owner for the DepositModule) is a 422 naming it, unless the allowance has meanwhile become enough.
   */
  private async submitPermitIfNeeded(
    request: DepositRequest,
    module: `0x${string}`,
    data: { amount: bigint; asset: `0x${string}` },
    gate: SponsorGate,
  ): Promise<{ hash: `0x${string}`; blockNumber: bigint } | undefined> {
    const token = (await this.publicClient.readContract({ address: data.asset, abi: wrappedAssetAbi, functionName: 'wrappedAsset' })) as `0x${string}`;
    const covered = async () =>
      ((await this.publicClient.readContract({
        address: token,
        abi: permitAbi,
        functionName: 'allowance',
        args: [getAddress(request.action.owner), getAddress(module)],
      })) as bigint) >= data.amount;
    if (await covered()) return undefined;

    const args = buildPermitArgs(request, module);
    const hash = await this.enqueueSend(async () => {
      try {
        await this.publicClient.simulateContract({ account: this.account, address: token, abi: permitAbi, functionName: 'permit', args });
      } catch (error) {
        if (await covered()) return undefined;
        const reason = describeSimulationRevert(error);
        if (reason !== undefined) throw new DepositRejectedError(`permit would revert: ${reason}`, `permit: ${reason}`);
        throw error;
      }
      gate.assertBudget();
      if (this.config.dryRun) return undefined;
      return this.broadcast({ address: token, abi: permitAbi as Abi, functionName: 'permit', args });
    });
    if (hash === undefined) return undefined;
    const receipt = await this.publicClient.waitForTransactionReceipt({ hash, timeout: this.config.receiptTimeoutMs });
    // The permit is sponsored gas too: it counts against the same hourly budget as the deposit.
    gate.record(receiptCostWei(receipt));
    if (receipt.status !== 'success' && !(await covered())) {
      throw new DepositRejectedError('the permit transaction reverted and the allowance does not cover the deposit', 'permit: reverted');
    }
    return { hash, blockNumber: receipt.blockNumber };
  }

  private async submitDeposit(
    request: DepositRequest,
    deposit: NonNullable<AppConfig['deposit']>,
  ): Promise<DepositResponse> {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const data = assertDepositPolicy(request, { ...deposit, nowSeconds });
    if (request.permit) assertPermitPolicy(request.permit, data.amount, nowSeconds);
    const gate = this.depositGate!;
    await gate.check();
    const permit = request.permit ? await this.submitPermitIfNeeded(request, deposit.moduleAddress, data, gate) : undefined;

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
      beforeSend: () => gate.assertBudget(),
      afterBlock: permit?.blockNumber,
    });
    if (permit) (amounts as Record<string, string>).permit_tx_hash = permit.hash;

    if (txHash === 'dry-run') {
      return { accepted: true, tx_hash: 'dry-run', ...amounts };
    }
    try {
      const receipt = await this.publicClient.waitForTransactionReceipt({ hash: txHash, timeout: deposit.receiptTimeoutMs });
      gate.record(receiptCostWei(receipt));
      const response: DepositResponse = { ...buildReceiptResponse(txHash, receipt), ...amounts };
      if (receipt.status === 'success') {
        response.subaccount_id = creditedSubaccount(request, this.deps.matchingAddress, receipt.logs);
      }
      return response;
    } catch (error) {
      if (error instanceof WaitForTransactionReceiptTimeoutError) {
        // The outcome is unknown, but the gas may be spent: count a conservative provisional cost.
        gate.record(PROVISIONAL_SPONSORED_GAS * (await this.publicClient.getGasPrice().catch(() => 0n)));
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
