import { parseAbi, type Address } from 'viem';

import type { Alerter } from './alert.js';
import type { ContractChain } from './chain.js';
import type { ForwardConfig } from './forward-config.js';
import { futureAbi } from './forward-publisher.js';

export const fixingAbi = parseAbi([
  'struct Fixing { uint64 windowStart; uint64 maxSampleGap; uint64 firstSampleTime; uint64 lastSampleTime; uint64 largestGap; uint256 lastPrice; uint256 accumulator; }',
  'function fixings(uint256 subId) view returns (Fixing)',
  'function fixingWindow() view returns (uint256)',
  'function maxSampleGap() view returns (uint256)',
  'function fallbackDelay() view returns (uint256)',
  'function recordFixingSample(uint96 subId)',
  'function fixSettlementFromIndex(uint96 subId)',
]);
const managerAbi = parseAbi([
  'function closeOutExpired(uint256 accountId, uint96 subId)',
  'function settleAccount(uint256 accountId)',
]);
const pendingAbi = parseAbi(['function getPendingVM(uint256 accountId, uint256 subId) view returns (int256)']);
const engineAbi = parseAbi([
  'struct AssetDetail { bool isWhitelisted; uint8 assetType; uint256 marketId; }',
  'function accId() view returns (uint256)',
  'function cashAsset() view returns (address)',
  'function assetDetails(address asset) view returns (AssetDetail)',
  'function assetMap(uint256 marketId, uint8 assetType) view returns (address)',
  'function getMarketFeeds(uint256 marketId) view returns (address, address, address)',
]);
const spotFeedAbi = parseAbi(['function getSpot() view returns (uint256, uint256)']);
/** IMarginEngine.AssetType.Base: the market's cNGN escrow. */
const BASE_ASSET_TYPE = 3; // v1 only: v2's pool holds no base
const ONE = 10n ** 18n;
/**
 * A net within $1 of zero is covered. Settlement converts cNGN at the spot feed and rounds, and a pool holding
 * cNGN against a USDC debt accrues the cash rate on it: neither is worth a settlement or a page. Past $1 it is:
 * the interest on a $5,000 debt at 10% crosses it within a day, about when a top-up is worth doing. The pager
 * uses the same tolerance (check_perp_pager.FUTURE_POOL_DUST_USD).
 */
export const POOL_NET_TOLERANCE = 10n ** 18n;
const subAccountsAbi = parseAbi([
  'function lastAccountId() view returns (uint256)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function manager(uint256 accountId) view returns (address)',
]);
const assetAbi = parseAbi(['function subAccounts() view returns (address)']);

type FutureContract = { listed: boolean; settled: boolean; expiry: bigint; lastTradeTime: bigint };
type Fixing = { firstSampleTime: bigint; lastSampleTime: bigint; largestGap: bigint; maxSampleGap: bigint };

export type ExpiryOutcome =
  | 'before-window'
  | 'sampled'
  | 'sample-not-due'
  | 'sample-failed'
  | 'fixed'
  | 'fixing-incomplete'
  | 'fix-failed'
  | 'closing-out'
  | 'closed-out'
  | 'done';

/** What one coverPoolDeficit call did. `netUsd` is the pool's net after it, 18dp; null when not read. */
export type DeficitOutcome = { netUsd: bigint | null; settled: number; failed: number; stranded: boolean };

/** Where the VM pool lives and how its cNGN is valued: all read from the engine. */
type Pool = { id: bigint; cash: Address; escrow: Address; spotFeed: Address };

/** A loser the pool could be paid back by, and the USDC its settlement would bring in (18dp). */
type Loser = { id: bigint; manager: Address; owedCngn: bigint; usdc: bigint };

/**
 * Takes a dated future through expiry, with nothing but permissionless calls. v1 (USDC-cNGN, VM in
 * cNGN) and v2 (any base, VM in USDC cash) differ only in the VM pool (0); the fixing and close-out
 * calls are the same on both:
 *
 *  0. Every tick, keeps the VM pool's net at or above zero (coverPoolDeficit): while it is below,
 *     settles losers, those paying the most USDC first, up to SETTLE_PER_TICK a tick. Nothing else
 *     is settled on a schedule: every trade, transfer, withdrawal and liquidation settles its account
 *     first, close-out settles at expiry, and margin counts pending VM in the meantime.
 *  1. In the fixingWindow before expiry, records an index sample every FIXING_SAMPLE_INTERVAL_MS
 *     (well inside the contract's maxSampleGap, so one failed sample does not break the fixing).
 *  2. After expiry, fixes the settlement price from the samples. If the fixing is incomplete, it
 *     alerts: the vault's bounded fallback (setSettlementPrice, within 2% of the samples' TWAP) is
 *     the only way out, no sooner than fallbackDelay after expiry, and it alerts again once that
 *     delay has passed with the contract still unsettled.
 *  3. Once settled, calls closeOutExpired on every account still holding the series, up to
 *     CLOSE_OUT_BATCH per tick. Close-out converts any shortfall at the settlement price and reads no
 *     feed, so this works with the index down. The list comes from the chain and nothing else: the
 *     SubAccounts ledger is the one the future itself records (FutureAsset.subAccounts), and each
 *     account's close-out goes to its own manager (SubAccounts.manager), so no configured address
 *     can point a settlement or close-out at the wrong ledger or manager.
 *
 * Every step reads its state back from the chain first, so a restart picks up where it left off and
 * two keepers running at once only waste gas on calls the contract then refuses.
 */
export class ExpiryKeeper {
  /** Set once a deficit is left with no loser to settle, so it alerts once per episode; cleared at net >= 0. */
  private stranded = false;

  constructor(
    private readonly config: ForwardConfig,
    private readonly chain: ContractChain,
    private readonly alert: Alerter,
  ) {}

  private future<T>(abi: typeof futureAbi | typeof fixingAbi | typeof pendingAbi, functionName: string, args: readonly unknown[] = []) {
    return this.chain.read<T>(this.config.FUTURE_ASSET, abi, functionName, args);
  }

  async tick(): Promise<ExpiryOutcome> {
    const subId = this.config.FUTURE_SUB_ID;
    const contract = await this.future<FutureContract>(futureAbi, 'futureContracts', [subId]);
    if (!contract.listed) return 'done';
    const head = await this.chain.headTimestamp();

    if (contract.settled) return this.closeOut();

    if (head < contract.expiry) {
      const window = await this.future<bigint>(fixingAbi, 'fixingWindow');
      if (head < contract.expiry - window) return 'before-window';
      return this.sample(head);
    }
    return this.fix(head, contract.expiry);
  }

  /** Refuses a sample interval that could break the fixing on its own. Run once at startup. */
  async checkSampleInterval(): Promise<void> {
    const gap = await this.future<bigint>(fixingAbi, 'maxSampleGap');
    const interval = BigInt(Math.floor(this.config.FIXING_SAMPLE_INTERVAL_MS / 1000));
    // at most half the gap: one failed sample must still leave the next one inside it
    if (interval * 2n > gap) {
      throw new Error(`FIXING_SAMPLE_INTERVAL_MS (${interval}s) must be at most half the contract's maxSampleGap (${gap}s)`);
    }
  }

  private async sample(head: bigint): Promise<ExpiryOutcome> {
    const fixing = await this.future<Fixing>(fixingAbi, 'fixings', [this.config.FUTURE_SUB_ID]);
    const interval = BigInt(Math.floor(this.config.FIXING_SAMPLE_INTERVAL_MS / 1000));
    if (fixing.firstSampleTime !== 0n && head < fixing.lastSampleTime + interval) return 'sample-not-due';
    try {
      const tx = await this.chain.write(this.config.FUTURE_ASSET, fixingAbi, 'recordFixingSample', [this.config.FUTURE_SUB_ID]);
      console.log(`[expiry] fixing sample tx=${tx}`);
      return 'sampled';
    } catch (error) {
      // Most often a stale index (getSpot reverts). One miss is inside the gap limit; the next tick retries.
      await this.alert('fixing-sample-failed', `fixing sample for ${this.config.FUTURE_SUB_ID} failed: ${(error as Error).message.slice(0, 300)}`);
      return 'sample-failed';
    }
  }

  private async fix(head: bigint, expiry: bigint): Promise<ExpiryOutcome> {
    const fixing = await this.future<Fixing>(fixingAbi, 'fixings', [this.config.FUTURE_SUB_ID]);
    if (!fixingComplete(fixing, expiry)) {
      const fallbackDelay = await this.future<bigint>(fixingAbi, 'fallbackDelay');
      const due = head >= expiry + fallbackDelay;
      await this.alert(
        due ? 'fixing-fallback-due' : 'fixing-incomplete',
        due
          ? `future ${this.config.FUTURE_SUB_ID} is still unsettled ${head - expiry}s after expiry: the vault's fallback (setSettlementPrice, within 2% of fallbackReference) is now open`
          : `future ${this.config.FUTURE_SUB_ID}: the index fixing is incomplete; the vault may settle by hand from ${expiry + fallbackDelay}`,
      );
      return 'fixing-incomplete';
    }
    try {
      const tx = await this.chain.write(this.config.FUTURE_ASSET, fixingAbi, 'fixSettlementFromIndex', [this.config.FUTURE_SUB_ID]);
      console.log(`[expiry] settlement fixed tx=${tx}`);
      return 'fixed';
    } catch (error) {
      await this.alert('fixing-failed', `fixSettlementFromIndex for ${this.config.FUTURE_SUB_ID} failed: ${(error as Error).message.slice(0, 300)}`);
      return 'fix-failed';
    }
  }

  /**
   * Accounts still holding the series, each with the manager it sits under, all read from the chain:
   * the future's own SubAccounts ledger, walked to its lastAccountId (Base has a few dozen accounts).
   */
  async holders(): Promise<{ id: bigint; manager: Address }[]> {
    const ledger = await this.chain.read<Address>(this.config.FUTURE_ASSET, assetAbi, 'subAccounts');
    const last = await this.chain.read<bigint>(ledger, subAccountsAbi, 'lastAccountId');
    const holders: { id: bigint; manager: Address }[] = [];
    // TODO: one read per account, plus one per holder, sequentially, on every deficit and at close-out:
    // fine at a few dozen accounts, not at thousands. Then find holders from an index (the asset's
    // balance-change events) or a holder set kept on-chain, and keep this scan as the reconciliation.
    for (let id = 1n; id <= last; id++) {
      const balance = await this.chain.read<bigint>(ledger, subAccountsAbi, 'getBalance', [
        id,
        this.config.FUTURE_ASSET,
        this.config.FUTURE_SUB_ID,
      ]);
      if (balance === 0n) continue;
      holders.push({ id, manager: await this.chain.read<Address>(ledger, subAccountsAbi, 'manager', [id]) });
    }
    return holders;
  }

  /** The VM pool and how its cNGN is valued, from the engine: its pool account, cash, the market's escrow and spot feed. */
  private async pool(): Promise<Pool> {
    const engine = this.config.FUTURE_MANAGER;
    const [id, cash, detail] = await Promise.all([
      this.chain.read<bigint>(engine, engineAbi, 'accId'),
      this.chain.read<Address>(engine, engineAbi, 'cashAsset'),
      this.chain.read<{ marketId: bigint }>(engine, engineAbi, 'assetDetails', [this.config.FUTURE_ASSET]),
    ]);
    const [escrow, feeds] = await Promise.all([
      this.chain.read<Address>(engine, engineAbi, 'assetMap', [detail.marketId, BASE_ASSET_TYPE]),
      this.chain.read<readonly [Address, Address, Address]>(engine, engineAbi, 'getMarketFeeds', [detail.marketId]),
    ]);
    return { id, cash, escrow, spotFeed: feeds[0] };
  }

  /** USDC per cNGN, 18dp: the engine's own spot feed, the one settlement converts a cash remainder at. */
  private async spot(pool: Pool): Promise<bigint> {
    const [spot] = await this.chain.read<readonly [bigint, bigint]>(pool.spotFeed, spotFeedAbi, 'getSpot');
    return spot;
  }

  private async balance(account: bigint, asset: Address): Promise<bigint> {
    const ledger = await this.chain.read<Address>(this.config.FUTURE_ASSET, assetAbi, 'subAccounts');
    return this.chain.read<bigint>(ledger, subAccountsAbi, 'getBalance', [account, asset, 0n]);
  }

  /** The pool's net in USD, 18dp: its USDC cash plus its cNGN at the spot feed. The pager judges the same. */
  private async net(pool: Pool, spot: bigint): Promise<bigint> {
    const [cash, cngn] = await Promise.all([this.balance(pool.id, pool.cash), this.balance(pool.id, pool.escrow)]);
    return cash + (cngn * spot) / ONE;
  }

  /**
   * Losers, the most USDC their settlement would pay the pool first. Settlement takes a loser's cNGN
   * first and the rest in USDC (FutureVMLib._pay), so that is max(0, owed - cNGN held); USDC clears
   * the pool's actual cash debt and stops its interest. Ties, including losers who would pay only
   * cNGN, go by the size of what they owe.
   */
  private async losers(pool: Pool, spot: bigint): Promise<Loser[]> {
    const losers: Loser[] = [];
    for (const holder of await this.holders()) {
      const vm = await this.future<bigint>(pendingAbi, 'getPendingVM', [holder.id, this.config.FUTURE_SUB_ID]);
      if (vm >= 0n) continue;
      const held = await this.balance(holder.id, pool.escrow);
      const owedCngn = -vm;
      const inCash = owedCngn > held ? owedCngn - (held > 0n ? held : 0n) : 0n;
      losers.push({ ...holder, owedCngn, usdc: (inCash * spot) / ONE });
    }
    return losers.sort((a, b) => {
      if (a.usdc !== b.usdc) return a.usdc > b.usdc ? -1 : 1;
      if (a.owedCngn !== b.owedCngn) return a.owedCngn > b.owedCngn ? -1 : 1;
      return 0;
    });
  }

  /**
   * Keeps the VM pool's net at or above zero, to within POOL_NET_TOLERANCE. MarginEngine settles lazily: a winner who trades or
   * withdraws is paid from the pool at once, in cNGN while it has some and in borrowed USDC after,
   * while the losers who owe it settle only when something touches them. When the pool's net (USDC
   * plus cNGN at the spot feed) is below zero, this settles losers, the most USDC first, until it is
   * back, at most SETTLE_PER_TICK a tick; the next tick carries on. Winners are left alone: they
   * settle when they next trade or withdraw, or call settleAccount themselves.
   *
   * A deficit no loser can cover (the naira fell after everyone paid) alerts once per episode: only a
   * top-up of the pool account fixes it, and the pager pages if it lasts.
   */
  async coverPoolDeficit(): Promise<DeficitOutcome> {
    const contract = await this.future<FutureContract>(futureAbi, 'futureContracts', [this.config.FUTURE_SUB_ID]);
    // after settlement, close-out realises every account's VM at the settlement price
    if (!contract.listed || contract.settled) return { netUsd: null, settled: 0, failed: 0, stranded: false };
    if (this.config.FUTURE_VERSION === 'v2') return this.coverCashPool();
    const pool = await this.pool();
    const spot = await this.spot(pool);
    let net = await this.net(pool, spot);
    if (net >= -POOL_NET_TOLERANCE) {
      if (this.stranded) console.log(`[pool] net back to ${usd(net)}`);
      this.stranded = false;
      return { netUsd: net, settled: 0, failed: 0, stranded: false };
    }
    const losers = await this.losers(pool, spot);
    if (losers.length === 0) {
      if (!this.stranded) {
        this.stranded = true;
        await this.alert(
          'future-pool-deficit-stranded',
          `cNGN future VM pool #${pool.id} is ${usd(-net)} below zero (USDC plus cNGN at the spot feed) with no loser left to settle: top up the pool account`,
        );
      }
      return { netUsd: net, settled: 0, failed: 0, stranded: true };
    }
    let settled = 0;
    let failed = 0;
    for (const loser of losers.slice(0, this.config.SETTLE_PER_TICK)) {
      try {
        const tx = await this.chain.write(loser.manager, managerAbi, 'settleAccount', [loser.id]);
        settled++;
        console.log(`[pool] settled loser ${loser.id} (owed ${loser.owedCngn} cNGN wei, ~${usd(loser.usdc)} of it in USDC) tx=${tx}`);
      } catch (error) {
        failed++;
        await this.alert(`settle-failed-${loser.id}`, `settleAccount(${loser.id}) failed: ${(error as Error).message.slice(0, 300)}`);
      }
      net = await this.net(pool, spot);
      if (net >= -POOL_NET_TOLERANCE) break;
    }
    console.log(`[pool] ${settled} settled, ${failed} failed, net ${net < 0n ? '-' : ''}${usd(net < 0n ? -net : net)}`);
    return { netUsd: net, settled, failed, stranded: false };
  }

  /**
   * coverPoolDeficit on v2 (MarginEngine v2, FutureVMLib): VM is USDC and moves as cash through the pool,
   * nothing converted, so the pool's net is its cash and a loser's settlement pays the pool exactly what it
   * owes. No escrow leg, no spot feed, no market lookup: the pool is the engine's accId, the cash its
   * cashAsset, whatever the base. Losers go largest first, up to SETTLE_PER_TICK a tick.
   *
   * Every v2 series on an engine shares its pool, so each series' keeper sees the same net; each settles
   * only its own series' losers (settleAccount realises every future the account holds).
   */
  private async coverCashPool(): Promise<DeficitOutcome> {
    const engine = this.config.FUTURE_MANAGER;
    const [poolId, cash] = await Promise.all([
      this.chain.read<bigint>(engine, engineAbi, 'accId'),
      this.chain.read<Address>(engine, engineAbi, 'cashAsset'),
    ]);
    let net = await this.balance(poolId, cash);
    if (net >= -POOL_NET_TOLERANCE) {
      if (this.stranded) console.log(`[pool] net back to ${usd(net)}`);
      this.stranded = false;
      return { netUsd: net, settled: 0, failed: 0, stranded: false };
    }
    const losers: { id: bigint; manager: Address; owed: bigint }[] = [];
    for (const holder of await this.holders()) {
      const vm = await this.future<bigint>(pendingAbi, 'getPendingVM', [holder.id, this.config.FUTURE_SUB_ID]);
      if (vm < 0n) losers.push({ ...holder, owed: -vm });
    }
    losers.sort((a, b) => (a.owed > b.owed ? -1 : a.owed < b.owed ? 1 : 0));
    if (losers.length === 0) {
      if (!this.stranded) {
        this.stranded = true;
        await this.alert(
          'future-pool-deficit-stranded',
          `${this.config.BASE_SYMBOL} future VM pool #${poolId} is ${usd(-net)} below zero (cash) with no loser of ${this.config.FUTURE_SUB_ID} left to settle: top up the pool account`,
        );
      }
      return { netUsd: net, settled: 0, failed: 0, stranded: true };
    }
    let settled = 0;
    let failed = 0;
    for (const loser of losers.slice(0, this.config.SETTLE_PER_TICK)) {
      try {
        const tx = await this.chain.write(loser.manager, managerAbi, 'settleAccount', [loser.id]);
        settled++;
        console.log(`[pool] settled loser ${loser.id} (owed ${usd(loser.owed)}) tx=${tx}`);
      } catch (error) {
        failed++;
        await this.alert(`settle-failed-${loser.id}`, `settleAccount(${loser.id}) failed: ${(error as Error).message.slice(0, 300)}`);
      }
      net = await this.balance(poolId, cash);
      if (net >= -POOL_NET_TOLERANCE) break;
    }
    console.log(`[pool] ${settled} settled, ${failed} failed, net ${net < 0n ? '-' : ''}${usd(net < 0n ? -net : net)}`);
    return { netUsd: net, settled, failed, stranded: false };
  }

  private async closeOut(): Promise<ExpiryOutcome> {
    const holders = await this.holders();
    if (holders.length === 0) return 'done';
    let failed = 0;
    for (const { id, manager } of holders.slice(0, this.config.CLOSE_OUT_BATCH)) {
      try {
        const tx = await this.chain.write(manager, managerAbi, 'closeOutExpired', [id, this.config.FUTURE_SUB_ID]);
        console.log(`[expiry] closed out account ${id} tx=${tx}`);
      } catch (error) {
        failed++;
        await this.alert(`close-out-failed-${id}`, `closeOutExpired(${id}) failed: ${(error as Error).message.slice(0, 300)}`);
      }
    }
    return holders.length > this.config.CLOSE_OUT_BATCH || failed > 0 ? 'closing-out' : 'closed-out';
  }
}

/** An 18dp USD amount for a log line: "$12.34". */
function usd(amount: bigint): string {
  const cents = amount / 10n ** 16n;
  return `$${cents / 100n}.${(cents % 100n).toString().padStart(2, '0')}`;
}

/** The contract's own completeness rule: sampled from the window's start to expiry, no gap over the limit. */
export function fixingComplete(fixing: Fixing, expiry: bigint): boolean {
  if (fixing.firstSampleTime === 0n) return false;
  const closingGap = expiry - fixing.lastSampleTime;
  const largest = closingGap > fixing.largestGap ? closingGap : fixing.largestGap;
  return largest <= fixing.maxSampleGap;
}
