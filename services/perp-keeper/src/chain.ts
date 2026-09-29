import {
  decodeEventLog,
  pad,
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  parseAbi,
  parseAbiItem,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';

import type { Config } from './config.js';
import type { AccountView } from './decide.js';
import type { StackHealth } from './health.js';

export const auctionAbi = parseAbi([
  'function startAuction(uint256 accountId, uint256 scenarioId)',
  'function convertToInsolventAuction(uint256 accountId)',
  'function terminateAuction(uint256 accountId)',
  'function bid(uint256 accountId, uint256 bidderId, uint256 percentOfAccount, int256 priceLimit, uint256 expectedLastTradeId) returns (uint256, uint256, uint256)',
  'function getMarginAndMarkToMarket(uint256 accountId, uint256 scenarioId) view returns (int256 mm, int256 bm, int256 mtm)',
  'function getAuction(uint256 accountId) view returns ((uint256 accountId, uint256 scenarioId, bool insolvent, bool ongoing, uint256 cachedMM, uint256 startTime, uint256 reservedCash))',
  'function getAuctionStatus(uint256 accountId) view returns (bool canTerminate, int256 markToMarket, int256 maintenanceMargin, int256 bufferMargin)',
  'function getCurrentBidPrice(uint256 accountId) view returns (int256)',
  'function getMaxProportion(uint256 accountId, uint256 scenarioId) view returns (uint256)',
  'function totalInsolventMM() view returns (uint256)',
  // Every custom error on the auction path (DutchAuction, SRM/BaseManager, CashAsset,
  // SecurityModule, feeds, perp), so a revert decodes to a name instead of a bare selector.
  'error BLF_DataExpired()',
  'error BLF_DataTooOld()',
  'error BLF_DuplicatedSigner()',
  'error BLF_InvalidRequiredSigners()',
  'error BLF_InvalidSignature()',
  'error BLF_InvalidSigner()',
  'error BLF_InvalidTimestamp()',
  'error BLF_NotEnoughSigners()',
  'error BLF_SignatureSignersLengthMismatch()',
  'error BM_AccountUnderLiquidation()',
  'error BM_AdjustmentsPaused()',
  'error BM_AssetCapExceeded()',
  'error BM_GuardianOnly()',
  'error BM_InvalidBidPortion()',
  'error BM_InvalidLiquidation()',
  'error BM_InvalidMaxAccountSize()',
  'error BM_MinOIFeeTooHigh()',
  'error BM_NotImplemented()',
  'error BM_OnlyAccounts()',
  'error BM_OnlyLiquidationModule()',
  'error BM_UnauthorizedCall()',
  'error CA_DonateBalanceNotAuthorized()',
  'error CA_ForceWithdrawNegativeBalance()',
  'error CA_ForceWithdrawNotAuthorized()',
  'error CA_InterestAccrualStale(uint256 lastUpdatedAt, uint256 currentTimestamp)',
  'error CA_InvalidSubId()',
  'error CA_NotAccount()',
  'error CA_NotLiquidationModule()',
  'error CA_OnlyAccountOwner()',
  'error CA_SmFeeInvalid(uint256 fee)',
  'error CA_UnknownManager()',
  'error CA_WithdrawBlockedByOngoingAuction()',
  'error DA_AccountIsAboveMaintenanceMargin()',
  'error DA_AccountIsBelowMaintenanceMargin()',
  'error DA_AmountIsZero()',
  'error DA_AuctionAlreadyInInsolvencyMode()',
  'error DA_AuctionAlreadyStarted()',
  'error DA_AuctionCannotTerminate()',
  'error DA_AuctionNotStarted()',
  'error DA_AuctionShouldBeTerminated()',
  'error DA_BidderInsolvent()',
  'error DA_CannotBidWithDifferentManager()',
  'error DA_InsufficientCash()',
  'error DA_InvalidBidderPortfolio()',
  'error DA_InvalidBufferMarginParameter()',
  'error DA_InvalidLastTradeId()',
  'error DA_InvalidParameter()',
  'error DA_InvalidPercentage()',
  'error DA_InvalidWithdrawBlockThreshold()',
  'error DA_NotOngoingAuction()',
  'error DA_NotWhitelistedManager()',
  'error DA_OngoingSolventAuction()',
  'error DA_OnlyManager()',
  'error DA_PriceLimitExceeded()',
  'error DA_ReservedCashGreaterThanMtM()',
  'error DA_ScenarioIdNotWorse()',
  'error DA_SenderNotOwner()',
  'error DA_SolventAuctionEnded()',
  'error PA_InvalidConvergencePeriod()',
  'error PA_InvalidImpactPrices()',
  'error PA_InvalidRateBounds()',
  'error PA_InvalidStaticInterestRate()',
  'error PA_InvalidSubId()',
  'error PA_WrongManager()',
  'error SM_BalanceBelowPCRMStaticCashOffset(uint256 cashBalance, uint256 staticCashOffset)',
  'error SM_NotWhitelisted()',
  'error SRM_InvalidBaseDiscountFactor()',
  'error SRM_InvalidDepegParams()',
  'error SRM_InvalidOptionMarginParams()',
  'error SRM_InvalidOracleContingencyParams()',
  'error SRM_InvalidPerpMarginParams()',
  'error SRM_MarketNotCreated()',
  'error SRM_NoForwardPrice()',
  'error SRM_NoNegativeCash()',
  'error SRM_NotAccounts()',
  'error SRM_NotWhitelistManager()',
  'error SRM_PortfolioBelowMargin()',
  'error SRM_TooManyAssets()',
  'error SRM_UnsupportedAsset()',
]);

/** Gas sent as a percentage of the estimate. */
const GAS_HEADROOM_PCT = 150n;

const subAccountsAbi = parseAbi([
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function createAccount(address owner, address manager) returns (uint256)',
  'function ownerOf(uint256 accountId) view returns (address)',
  'function manager(uint256 accountId) view returns (address)',
  'function submitTransfer((uint256 fromAcc, uint256 toAcc, address asset, uint256 subId, int256 amount, bytes32 assetData) assetTransfer, bytes managerData) returns (uint256)',
  'event AccountCreated(address indexed owner, uint256 indexed accountId, address indexed manager)',
]);
const cashAbi = parseAbi([
  'function getCashToStableExchangeRate() view returns (uint256)',
  'function temporaryWithdrawFeeEnabled() view returns (bool)',
]);
const perpAbi = parseAbi([
  'function totalPosition(address manager) view returns (uint256)',
  'function totalPositionCap(address manager) view returns (uint256)',
]);

const accountCreated = parseAbiItem(
  'event AccountCreated(address indexed owner, uint256 indexed accountId, address indexed manager)',
);
const managerChanged = parseAbiItem(
  'event AccountManagerChanged(uint256 indexed accountId, address indexed oldManager, address indexed newManager)',
);

export type AuctionCall =
  | { functionName: 'startAuction'; args: readonly [bigint, bigint] }
  | { functionName: 'convertToInsolventAuction'; args: readonly [bigint] }
  | { functionName: 'terminateAuction'; args: readonly [bigint] }
  | { functionName: 'bid'; args: readonly [bigint, bigint, bigint, bigint, bigint] };

export function createKeeperChain(config: Config) {
  const transport = http(config.RPC_URL);
  const chain =
    config.CHAIN_ID === base.id
      ? base
      : defineChain({
          id: config.CHAIN_ID,
          name: `chain-${config.CHAIN_ID}`,
          nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
          rpcUrls: { default: { http: [config.RPC_URL] } },
        });
  const client = createPublicClient({ chain, transport });
  const keeper = privateKeyToAccount(config.KEEPER_KEY as Hex);
  const wallet = createWalletClient({ account: keeper, chain, transport });

  const accounts = new Set<bigint>();
  /** Accounts the keeper itself owns under the SRM: its funding account and every bid account. */
  const ownAccounts = new Set<bigint>([config.KEEPER_ACCOUNT]);
  // Bid accounts that were created but never bid from (funding or the bid itself failed): still
  // cash-only, so still valid bidders. Reused before creating another.
  const spareBidAccounts: bigint[] = [];
  let scannedTo = config.START_BLOCK - 1n;

  async function send(request: Parameters<typeof wallet.writeContract>[0]) {
    const hash = await wallet.writeContract(request);
    const receipt = await client.waitForTransactionReceipt({ hash, timeout: 60_000 });
    if (receipt.status !== 'success') {
      // TRACE BRANCH ONLY: say whether it ran out of gas, and whether it succeeds with unlimited gas.
      const tx = await client.getTransaction({ hash });
      const block = await client.getBlock({ blockNumber: receipt.blockNumber });
      const prev = await client.getBlock({ blockNumber: receipt.blockNumber - 1n });
      const replay = await client
        .call({ account: tx.from, to: tx.to!, data: tx.input, blockNumber: receipt.blockNumber - 1n })
        .then(() => 'succeeds with unlimited gas')
        .catch((error: Error) => `reverts: ${error.message.split('\n')[0]}`);
      const trace = await client
        .request({ method: 'debug_traceTransaction' as never, params: [hash, { disableStack: true, disableMemory: true, disableStorage: true }] as never })
        .then((t: any) => `trace failed=${t.failed} gas=${t.gas} last=${JSON.stringify((t.structLogs ?? []).slice(-2).map((l: any) => [l.op, l.gas, l.gasCost, l.error]))}`)
        .catch((error: Error) => `trace unavailable: ${error.message.split('\n')[0]}`);
      throw new Error(
        `transaction reverted on chain: ${hash} ${String(request.functionName)}: gasUsed ${receipt.gasUsed} of limit ${tx.gas} ` +
          `(block ts ${block.timestamp}, previous ${prev.timestamp}); replay at previous block ${replay}; ${trace}`,
      );
    }
    return receipt;
  }

  async function balance(accountId: bigint, asset: Address): Promise<bigint> {
    return client.readContract({
      address: config.SUB_ACCOUNTS,
      abi: subAccountsAbi,
      functionName: 'getBalance',
      args: [accountId, asset, 0n],
    });
  }

  async function optional<T>(read: () => Promise<T>): Promise<T | null> {
    try {
      return await read();
    } catch {
      return null;
    }
  }

  /** A fresh cash-only account under the SRM, owned by the keeper, to bid from. */
  async function createAccount(): Promise<bigint> {
    const created = await send({
      account: keeper,
      chain,
      address: config.SUB_ACCOUNTS,
      abi: subAccountsAbi,
      functionName: 'createAccount',
      args: [keeper.address, config.SRM],
    });
    const log = created.logs
      .map((entry) => {
        try {
          return decodeEventLog({ abi: subAccountsAbi, data: entry.data, topics: entry.topics });
        } catch {
          return null;
        }
      })
      .find((event) => event?.eventName === 'AccountCreated');
    if (!log || log.eventName !== 'AccountCreated') throw new Error('createAccount emitted no AccountCreated');
    ownAccounts.add(log.args.accountId);
    return log.args.accountId;
  }

  return {
    keeper,

    /**
     * Every account the perp SRM manages: created under it, or moved onto it, less any moved off.
     * Scans incrementally, so each poll reads only the blocks since the last one.
     */
    async discoverAccounts(): Promise<bigint[]> {
      const head = await client.getBlockNumber();
      while (scannedTo < head) {
        const from = scannedTo + 1n;
        const to = from + config.LOG_CHUNK_BLOCKS - 1n < head ? from + config.LOG_CHUNK_BLOCKS - 1n : head;
        const [created, movedIn, movedOut] = await Promise.all([
          client.getLogs({ address: config.SUB_ACCOUNTS, event: accountCreated, args: { manager: config.SRM }, fromBlock: from, toBlock: to }),
          client.getLogs({ address: config.SUB_ACCOUNTS, event: managerChanged, args: { newManager: config.SRM }, fromBlock: from, toBlock: to }),
          client.getLogs({ address: config.SUB_ACCOUNTS, event: managerChanged, args: { oldManager: config.SRM }, fromBlock: from, toBlock: to }),
        ]);
        for (const log of [...created, ...movedIn]) accounts.add(log.args.accountId!);
        for (const log of movedOut) accounts.delete(log.args.accountId!);
        for (const log of created) if (log.args.owner === keeper.address) ownAccounts.add(log.args.accountId!);
        scannedTo = to;
      }
      // The security module's account and the keeper's own are never the keeper's to liquidate; its
      // own are watched in readHealth instead.
      return [...accounts]
        .filter((id) => id !== config.SECURITY_MODULE_ACCOUNT && !ownAccounts.has(id))
        .sort((a, b) => (a < b ? -1 : 1));
    },

    /**
     * An account under the SRM, funded from the keeper's funding account, to bid from.
     * DutchAuction only accepts a bidder holding nothing but cash (DA_InvalidBidderPortfolio), so a
     * bid account is used for one landed bid: afterwards it holds the inherited position, and the
     * funding account stays cash-only and able to fund the next. A spare (never bid from) is reused
     * first, so failed attempts do not leave an account behind each time.
     */
    async createBidAccount(cash: bigint): Promise<bigint> {
      const spare = spareBidAccounts.pop();
      const accountId = spare ?? (await createAccount());
      try {
        await send({
          account: keeper,
          chain,
          address: config.SUB_ACCOUNTS,
          abi: subAccountsAbi,
          functionName: 'submitTransfer',
          args: [
            { fromAcc: config.KEEPER_ACCOUNT, toAcc: accountId, asset: config.CASH, subId: 0n, amount: cash, assetData: pad('0x', { size: 32 }) },
            '0x',
          ],
        });
      } catch (error) {
        spareBidAccounts.push(accountId);
        throw error;
      }
      return accountId;
    },

    /** Returns a bid account whose bid did not land: it holds only cash, so it can bid again. */
    releaseBidAccount(accountId: bigint): void {
      spareBidAccounts.push(accountId);
    },

    /**
     * The funding account must be the keeper's own and under this SRM. One opened through the app
     * or SubAccountCreator is held by Matching, not the keeper EOA, and every bid-account funding
     * transfer from it reverts (NotEnoughSubIdOrAssetAllowances). Checked each pass so /health, and
     * with it the enable and index-step gates, fail on it.
     */
    async assertFundingAccount(): Promise<void> {
      const [owner, manager] = await Promise.all([
        client.readContract({ address: config.SUB_ACCOUNTS, abi: subAccountsAbi, functionName: 'ownerOf', args: [config.KEEPER_ACCOUNT] }),
        client.readContract({ address: config.SUB_ACCOUNTS, abi: subAccountsAbi, functionName: 'manager', args: [config.KEEPER_ACCOUNT] }),
      ]);
      if (owner.toLowerCase() !== keeper.address.toLowerCase()) {
        throw new Error(`KEEPER_ACCOUNT #${config.KEEPER_ACCOUNT} is owned by ${owner}, not the keeper ${keeper.address}: it cannot fund bids`);
      }
      if (manager.toLowerCase() !== config.SRM.toLowerCase()) {
        throw new Error(`KEEPER_ACCOUNT #${config.KEEPER_ACCOUNT} is under ${manager}, not the perp SRM ${config.SRM}`);
      }
    },


    /** Everything decide() needs about one account. Throws if margin cannot be read (stale feeds). */
    async readAccount(accountId: bigint): Promise<AccountView> {
      const [mm, bm, mtm] = await client.readContract({
        address: config.AUCTION,
        abi: auctionAbi,
        functionName: 'getMarginAndMarkToMarket',
        args: [accountId, 0n],
      });
      const auction = await client.readContract({
        address: config.AUCTION,
        abi: auctionAbi,
        functionName: 'getAuction',
        args: [accountId],
      });
      const view: AccountView = {
        accountId,
        mm,
        bm,
        mtm,
        auction: { ongoing: auction.ongoing, insolvent: auction.insolvent, reservedCash: auction.reservedCash },
        canTerminate: false,
        bidPrice: null,
        maxProportion: null,
      };
      if (!auction.ongoing) return view;

      const [status, bidPrice, maxProportion] = await Promise.all([
        client.readContract({ address: config.AUCTION, abi: auctionAbi, functionName: 'getAuctionStatus', args: [accountId] }),
        optional(() => client.readContract({ address: config.AUCTION, abi: auctionAbi, functionName: 'getCurrentBidPrice', args: [accountId] })),
        auction.insolvent
          ? Promise.resolve(null)
          : optional(() => client.readContract({ address: config.AUCTION, abi: auctionAbi, functionName: 'getMaxProportion', args: [accountId, 0n] })),
      ]);
      return { ...view, canTerminate: status[0], bidPrice, maxProportion };
    },

    async keeperCash(): Promise<bigint> {
      return balance(config.KEEPER_ACCOUNT, config.CASH);
    },

    async readHealth(): Promise<StackHealth> {
      const own = [...ownAccounts];
      const [ownPerp, ownMargins] = await Promise.all([
        Promise.all(own.map((id) => balance(id, config.PERP))),
        Promise.all(
          own.map((id) =>
            optional(() =>
              client.readContract({ address: config.AUCTION, abi: auctionAbi, functionName: 'getMarginAndMarkToMarket', args: [id, 0n] }),
            ),
          ),
        ),
      ]);
      const keeperAccountsUnderMargin = own.filter((_, i) => {
        const margins = ownMargins[i];
        return margins !== null && margins !== undefined && margins[0] < 0n;
      });
      const [securityModuleCash, totalInsolventMM, cashExchangeRate, temporaryWithdrawFeeEnabled, keeperCash, keeperEthWei, totalPosition, totalPositionCap] =
        await Promise.all([
          balance(config.SECURITY_MODULE_ACCOUNT, config.CASH),
          client.readContract({ address: config.AUCTION, abi: auctionAbi, functionName: 'totalInsolventMM' }),
          client.readContract({ address: config.CASH, abi: cashAbi, functionName: 'getCashToStableExchangeRate' }),
          client.readContract({ address: config.CASH, abi: cashAbi, functionName: 'temporaryWithdrawFeeEnabled' }),
          balance(config.KEEPER_ACCOUNT, config.CASH),
          client.getBalance({ address: keeper.address }),
          client.readContract({ address: config.PERP, abi: perpAbi, functionName: 'totalPosition', args: [config.SRM] }),
          client.readContract({ address: config.PERP, abi: perpAbi, functionName: 'totalPositionCap', args: [config.SRM] }),
        ]);
      return {
        securityModuleCash,
        totalInsolventMM,
        cashExchangeRate,
        temporaryWithdrawFeeEnabled,
        keeperCash,
        keeperEthWei,
        keeperPerpPosition: ownPerp.reduce((sum, position) => sum + position, 0n),
        keeperAccountsUnderMargin,
        totalPosition,
        totalPositionCap,
      };
    },

    /**
     * Simulates the call against the current chain, then sends it unless dry-running. A call that
     * would revert is reported, never sent: the state it was decided on has already moved.
     */
    async execute(call: AuctionCall, dryRun: boolean): Promise<{ sent: Hex | null }> {
      const params = {
        account: keeper,
        address: config.AUCTION,
        abi: auctionAbi,
        ...(call as { functionName: 'bid'; args: readonly [bigint, bigint, bigint, bigint, bigint] }),
      };
      const { request } = await client.simulateContract(params);
      if (dryRun) return { sent: null };
      // Auction calls settle interest and funding first, which depend on the block's timestamp, so
      // gas estimated against one block can fall short in the next. A liquidation that runs out of
      // gas is the failure a keeper exists to prevent: send with headroom.
      const estimate = await client.estimateContractGas(params);
      const hash = await wallet.writeContract({ ...request, gas: (estimate * GAS_HEADROOM_PCT) / 100n });
      const receipt = await client.waitForTransactionReceipt({ hash, timeout: 60_000 });
      if (receipt.status !== 'success') throw new Error(`${call.functionName} reverted on chain: ${hash}`);
      return { sent: hash };
    },
  };
}

export type KeeperChain = ReturnType<typeof createKeeperChain>;
