import { parseAbi } from 'viem';

import type { Alerter } from './alert.js';
import type { ContractChain } from './chain.js';
import type { ForwardConfig } from './forward-config.js';

/** FutureAsset v3 (contracts/risk-core/src/assets/FutureAsset.sol): its fixing, recovery windows included. */
export const fixingV3Abi = parseAbi([
  'struct Fixing { uint32 round; uint64 windowStart; uint64 windowEnd; uint64 maxSampleGap; uint64 firstSampleTime; uint64 lastSampleTime; uint64 largestGap; address feed; uint256 lastPrice; uint256 accumulator; }',
  'struct FixingParams { uint64 fixingWindow; uint64 maxSampleGap; uint64 recoveryDelay; }',
  'function fixings(uint256 subId) view returns (Fixing)',
  // The series' own fixing parameters, fixed when it was listed. The contract-wide fixingWindow() and friends are
  // only the defaults for series listed later: reading them would put the keeper on a window the series does not use.
  'function seriesFixing(uint256 subId) view returns (FixingParams)',
  'function recordFixingSample(uint96 subId)',
  'function fixSettlementFromIndex(uint96 subId)',
  'function openRecoveryWindow(uint96 subId)',
]);

export type FixingV3 = {
  round: number;
  windowStart: bigint;
  windowEnd: bigint;
  maxSampleGap: bigint;
  firstSampleTime: bigint;
  lastSampleTime: bigint;
  largestGap: bigint;
};

export type SeriesFixing = { fixingWindow: bigint; maxSampleGap: bigint; recoveryDelay: bigint };

export type FixingV3Outcome =
  | 'before-window'
  | 'sampled'
  | 'sample-not-due'
  | 'sample-failed'
  | 'fixed'
  | 'fix-failed'
  | 'recovery-opened'
  | 'recovery-failed';

/**
 * The window a sample at `head` would fall in: the stored one, or, before round 0's first sample opens it, the
 * original window ending at expiry (FutureAsset opens it lazily at expiry - fixingWindow).
 */
export function currentWindow(fixing: FixingV3, expiry: bigint, fixingWindow: bigint): { start: bigint; end: bigint } {
  if (fixing.windowEnd === 0n) return { start: expiry - fixingWindow, end: expiry };
  return { start: fixing.windowStart, end: fixing.windowEnd };
}

/** FutureAsset._fixingComplete, exactly: sampled from the window's start to its end with no gap over the limit. */
export function fixingV3Complete(fixing: FixingV3): boolean {
  if (fixing.windowEnd === 0n || fixing.firstSampleTime === 0n) return false;
  const closingGap = fixing.windowEnd - fixing.lastSampleTime;
  const largest = closingGap > fixing.largestGap ? closingGap : fixing.largestGap;
  return largest <= fixing.maxSampleGap;
}

/**
 * Takes a v3 series from its fixing window to settlement, with permissionless calls only
 * (docs/eurc-usdc-futures-spec.md, A8). There is no owner price to fall back on:
 *
 *  1. Inside the current window, records a sample every FIXING_SAMPLE_INTERVAL_MS. The reports it samples must be
 *     fresh: the streams poster runs first each tick.
 *  2. Once the window has ended: if complete, fixes the settlement price; if not, opens a recovery window (which
 *     starts recoveryDelay later and discards the broken window's samples) and alerts, then samples that window.
 *     Repeats until a window completes.
 *
 * Every decision reads the fixing back from the chain first, so a restart resumes and a second keeper only wastes gas.
 */
export class FixingKeeperV3 {
  constructor(
    private readonly config: ForwardConfig,
    private readonly chain: ContractChain,
    private readonly alert: Alerter,
  ) {}

  private read<T>(functionName: string, args: readonly unknown[] = []) {
    return this.chain.read<T>(this.config.FUTURE_ASSET, fixingV3Abi, functionName, args);
  }

  private series() {
    return this.read<SeriesFixing>('seriesFixing', [this.config.FUTURE_SUB_ID]);
  }

  private write(functionName: string) {
    return this.chain.write(this.config.FUTURE_ASSET, fixingV3Abi, functionName, [this.config.FUTURE_SUB_ID]);
  }

  /** Refuses a sample interval that could break a window on its own: at most half the series' gap limit. */
  async checkSampleInterval(): Promise<void> {
    const gap = (await this.series()).maxSampleGap;
    if (gap === 0n) throw new Error(`series ${this.config.FUTURE_SUB_ID} is not listed on ${this.config.FUTURE_ASSET}`);
    const interval = BigInt(Math.floor(this.config.FIXING_SAMPLE_INTERVAL_MS / 1000));
    if (interval * 2n > gap) {
      throw new Error(`FIXING_SAMPLE_INTERVAL_MS (${interval}s) must be at most half the contract's maxSampleGap (${gap}s)`);
    }
  }

  /** For an unsettled series; `expiry` from futureContracts. */
  async tick(head: bigint, expiry: bigint): Promise<FixingV3Outcome> {
    const subId = this.config.FUTURE_SUB_ID;
    const fixing = await this.read<FixingV3>('fixings', [subId]);
    const series = await this.series();
    const window = currentWindow(fixing, expiry, series.fixingWindow);

    if (head < window.start) return 'before-window';
    if (head <= window.end) return this.sample(head, fixing);

    if (fixingV3Complete(fixing)) {
      try {
        const tx = await this.write('fixSettlementFromIndex');
        console.log(`[fixing-v3] settled from round ${fixing.round} tx=${tx}`);
        return 'fixed';
      } catch (error) {
        await this.alert('fixing-failed', `fixSettlementFromIndex for ${subId} failed: ${(error as Error).message.slice(0, 300)}`);
        return 'fix-failed';
      }
    }
    try {
      const tx = await this.write('openRecoveryWindow');
      const delay = series.recoveryDelay;
      await this.alert(
        'fixing-recovery-opened',
        `${this.config.BASE_SYMBOL} future ${subId}: round ${fixing.round} did not complete (largest gap ${fixing.largestGap}s, ` +
          `limit ${fixing.maxSampleGap}s); recovery window opened, starting in ${delay}s. tx=${tx}`,
      );
      return 'recovery-opened';
    } catch (error) {
      await this.alert('fixing-recovery-failed', `openRecoveryWindow for ${subId} failed: ${(error as Error).message.slice(0, 300)}`);
      return 'recovery-failed';
    }
  }

  private async sample(head: bigint, fixing: FixingV3): Promise<FixingV3Outcome> {
    const interval = BigInt(Math.floor(this.config.FIXING_SAMPLE_INTERVAL_MS / 1000));
    // A window not yet sampled (or round 0 not yet opened) has lastSampleTime 0, so it is due at once: the first
    // sample's distance from the window's start counts as a gap.
    if (head < fixing.lastSampleTime + interval) return 'sample-not-due';
    try {
      const tx = await this.write('recordFixingSample');
      console.log(`[fixing-v3] round ${fixing.round} sample tx=${tx}`);
      return 'sampled';
    } catch (error) {
      // Most often a stale index (EurcIndexFeed reverts). One miss is inside the gap limit; the next tick retries.
      await this.alert('fixing-sample-failed', `fixing sample for ${this.config.FUTURE_SUB_ID} failed: ${(error as Error).message.slice(0, 300)}`);
      return 'sample-failed';
    }
  }
}
