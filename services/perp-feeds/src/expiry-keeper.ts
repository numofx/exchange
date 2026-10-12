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

export type SweepOutcome = { settled: number; failed: number };

/**
 * Takes a USDC/cNGN future through expiry, with nothing but permissionless calls:
 *
 *  0. After every mark the forward publisher lands, settles every holder's VM, payers first (sweep).
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
 *     can point the sweep at the wrong ledger or manager.
 *
 * Every step reads its state back from the chain first, so a restart picks up where it left off and
 * two keepers running at once only waste gas on calls the contract then refuses.
 */
export class ExpiryKeeper {
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

  /**
   * Realises every holder's VM after a mark, payers before receivers. MarginEngine settles lazily:
   * an account's VM moves only when something touches it, and a loser has no reason to. Without
   * this, a winner who settles to withdraw is paid from the pool's reserve, and that reserve stays
   * out until each loser happens to trade, be liquidated or be closed out at expiry. Payers first,
   * so each sweep pays winners from what losers just paid in: the reserve then only covers what
   * losers pay in USDC instead of cNGN, and winners who settle themselves between sweeps.
   */
  async sweep(): Promise<SweepOutcome> {
    const holders = await this.holders();
    const pending = await Promise.all(
      holders.map(async (h) => ({
        ...h,
        vm: await this.future<bigint>(pendingAbi, 'getPendingVM', [h.id, this.config.FUTURE_SUB_ID]),
      })),
    );
    const due = pending.filter((h) => h.vm !== 0n).sort((a, b) => (a.vm < b.vm ? -1 : a.vm > b.vm ? 1 : 0));
    let settled = 0;
    let failed = 0;
    for (const { id, manager, vm } of due) {
      try {
        const tx = await this.chain.write(manager, managerAbi, 'settleAccount', [id]);
        settled++;
        console.log(`[sweep] settled account ${id} (${vm < 0n ? 'paid' : 'received'} ${vm < 0n ? -vm : vm} cNGN wei) tx=${tx}`);
      } catch (error) {
        failed++;
        await this.alert(`settle-failed-${id}`, `settleAccount(${id}) failed: ${(error as Error).message.slice(0, 300)}`);
      }
    }
    return { settled, failed };
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

/** The contract's own completeness rule: sampled from the window's start to expiry, no gap over the limit. */
export function fixingComplete(fixing: Fixing, expiry: bigint): boolean {
  if (fixing.firstSampleTime === 0n) return false;
  const closingGap = expiry - fixing.lastSampleTime;
  const largest = closingGap > fixing.largestGap ? closingGap : fixing.largestGap;
  return largest <= fixing.maxSampleGap;
}
