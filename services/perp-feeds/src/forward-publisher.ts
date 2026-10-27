import { parseAbi, parseUnits, type Address } from 'viem';

import type { Alerter } from './alert.js';
import { fetchBook } from './book.js';
import type { ContractChain } from './chain.js';
import type { ForwardConfig } from './forward-config.js';
import { computeForwardTarget, invert } from './forward-targets.js';
import { encodeForwardData, encodeManagerData, signFeedUpdate } from './feed-data.js';
import type { RestingOrder } from './mark-targets.js';

export const futureAbi = parseAbi([
  'struct FutureContract { bool listed; bool settled; uint64 expiry; uint64 lastTradeTime; uint64 lastMarkTime; uint256 markPrice; int256 cumulativeVMPerContract; }',
  'function futureContracts(uint256 subId) view returns (FutureContract)',
  'function minMarkInterval() view returns (uint256)',
  'function contractSize() view returns (uint256)',
  'function maxMarkDeviation() view returns (uint256)',
  'function markIndexBand(uint64 expiry) view returns (uint256)',
  'function forwardFeed() view returns (address)',
  'function pullMark(uint96 subId)',
]);

type FutureContract = {
  listed: boolean;
  settled: boolean;
  expiry: bigint;
  lastTradeTime: bigint;
  lastMarkTime: bigint;
  markPrice: bigint;
  cumulativeVMPerContract: bigint;
};

export type ForwardOutcome =
  | 'published'
  | 'dry-run'
  | 'waiting'
  | 'closed'
  | 'settled'
  | 'no-index'
  | 'unreachable'
  | 'sign-failed'
  | 'pull-failed'
  | 'misconfigured';

/**
 * Marks a dated future from its forward (v1 USDC-cNGN, or a v2 series on any base, FUTURE_VERSION): each tick, once the contract's minMarkInterval has
 * passed, it works out the forward (forward-targets.ts), signs it into the future's LyraForwardFeed
 * and calls FutureAsset.pullMark, which reads it back, checks it against the index band and move
 * limit, and accrues VM. Stops at last trade.
 *
 * Every refusal alerts. A mark that has not landed for FORWARD_MARK_LATE_MS while trading is open
 * alerts on its own: the contract's VM is only as fresh as its last mark.
 */
export class ForwardPublisher {
  constructor(
    private readonly config: ForwardConfig,
    private readonly chain: ContractChain,
    private readonly alert: Alerter,
    private readonly readBook: (nowSec: number) => Promise<RestingOrder[]> = (nowSec) =>
      fetchBook(config.MARKETS_SERVICE_URL, config.FUTURE_ASSET, config.FUTURE_SUB_ID, nowSec),
  ) {}

  private read<T>(functionName: string, args: readonly unknown[] = []): Promise<T> {
    return this.chain.read<T>(this.config.FUTURE_ASSET, futureAbi, functionName, args);
  }

  /**
   * Refuses a late-mark threshold that an on-time mark would trip. A mark is due every minMarkInterval
   * and the publisher only looks every FORWARD_TICK_MS, so an on-time mark can be that much older.
   * Run once at startup.
   */
  async checkLateThreshold(): Promise<void> {
    const interval = await this.read<bigint>('minMarkInterval');
    const earliestLateMs = Number(interval) * 1000 + this.config.FORWARD_TICK_MS;
    if (this.config.FORWARD_MARK_LATE_MS <= earliestLateMs) {
      throw new Error(
        `FORWARD_MARK_LATE_MS (${this.config.FORWARD_MARK_LATE_MS}) must exceed minMarkInterval + FORWARD_TICK_MS (${earliestLateMs}ms)`,
      );
    }
  }

  /**
   * Refuses a FUTURE_VERSION that does not match the contract, by where its mark sits against the
   * index: a v1 mark is cNGN per USDC (about 1 / index), a v2 mark USDC per unit of the base (about the
   * index). It refuses when the mark sits nearer the index read the other version's way: for cNGN the
   * two are millions apart, for a base near a dollar (EURC) a third or so, and a stale mark is never
   * that far off. The wrong version would only compute marks the contract refuses; this says why at
   * startup. Skipped, with a warning, while the index cannot be read.
   */
  async checkUnits(): Promise<void> {
    const contract = await this.read<FutureContract>('futureContracts', [this.config.FUTURE_SUB_ID]);
    const indexUsdc = await this.chain.readIndex(this.config.INDEX_FEED);
    if (!contract.listed || contract.markPrice === 0n || indexUsdc === null || indexUsdc === 0n) {
      console.warn('[forward] units not checked: the contract is unlisted or the index is unreadable');
      return;
    }
    const v2 = this.config.FUTURE_VERSION === 'v2';
    const index = v2 ? indexUsdc : invert(indexUsdc);
    const other = v2 ? invert(indexUsdc) : indexUsdc;
    if (ratio(contract.markPrice, other) < ratio(contract.markPrice, index)) {
      throw new Error(
        `FUTURE_VERSION=${this.config.FUTURE_VERSION} does not match future ${this.config.FUTURE_ASSET}: its mark ${contract.markPrice} is nearer ${other} than the index in those units, ${index}`,
      );
    }
  }

  async tick(): Promise<ForwardOutcome> {
    const contract = await this.read<FutureContract>('futureContracts', [this.config.FUTURE_SUB_ID]);
    if (!contract.listed) {
      await this.alert('forward-unlisted', `future ${this.config.FUTURE_ASSET} has no contract ${this.config.FUTURE_SUB_ID}`);
      return 'misconfigured';
    }
    if (contract.settled) return 'settled';

    const head = await this.chain.headTimestamp();
    if (head >= contract.lastTradeTime) return 'closed';

    const lateSec = BigInt(Math.floor(this.config.FORWARD_MARK_LATE_MS / 1000));
    if (head - contract.lastMarkTime > lateSec) {
      await this.alert(
        'forward-mark-late',
        `future ${this.config.FUTURE_SUB_ID}: last mark ${head - contract.lastMarkTime}s ago, past ${lateSec}s; VM is stale`,
      );
    }

    const minInterval = await this.read<bigint>('minMarkInterval');
    if (head < contract.lastMarkTime + minInterval) return 'waiting';

    const feed = await this.read<Address>('forwardFeed');
    if (feed.toLowerCase() !== this.config.FORWARD_FEED.toLowerCase()) {
      await this.alert('forward-feed-mismatch', `future reads forward feed ${feed}, configured ${this.config.FORWARD_FEED}`);
      return 'misconfigured';
    }

    const indexUsdc = await this.chain.readIndex(this.config.INDEX_FEED);
    if (indexUsdc === null) {
      await this.alert('forward-no-index', 'forward not published: index feed is unset or stale');
      return 'no-index';
    }

    let orders: RestingOrder[] = [];
    try {
      orders = await this.readBook(Number(head));
    } catch (error) {
      // No book is the normal state before the market is listed: mark to carry, and say so in the log.
      console.warn(`[forward] book unavailable, marking to carry: ${(error as Error).message}`);
    }

    const [band, maxMove, contractSize] = await Promise.all([
      this.read<bigint>('markIndexBand', [contract.expiry]),
      this.read<bigint>('maxMarkDeviation'),
      this.read<bigint>('contractSize'),
    ]);
    const target = computeForwardTarget({
      version: this.config.FUTURE_VERSION,
      indexUsdc,
      carry: this.config.CARRY,
      secondsToExpiry: contract.expiry - head,
      orders,
      contractSize,
      minDepthUsdc: parseUnits(String(this.config.FORWARD_MIN_BOOK_DEPTH_USDC), 18),
      lastMark: contract.markPrice,
      band,
      maxMove,
      maxBasisBps: BigInt(this.config.FORWARD_MAX_BASIS_BPS),
      safetyBps: BigInt(this.config.FORWARD_SAFETY_BPS),
    });
    if (!target.ok) {
      await this.alert('forward-unreachable', `future ${this.config.FUTURE_SUB_ID}: ${target.reason}`);
      return 'unreachable';
    }

    let update;
    try {
      update = await signFeedUpdate({
        signer: this.chain.signer,
        kind: 'LyraForwardFeed',
        feed: this.config.FORWARD_FEED,
        chainId: this.chain.chainId,
        data: encodeForwardData(contract.expiry, target.diffUsdc),
        timestamp: head - BigInt(this.config.TIMESTAMP_SAFETY_SEC),
        deadline: head + BigInt(this.config.DEADLINE_SEC),
      });
    } catch (error) {
      // With a KMS signer this is KMS refusing or failing: a lost grant, a disabled key, throttling.
      await this.alert('forward-sign-failed', `forward not signed: ${(error as Error).message.slice(0, 300)}`);
      return 'sign-failed';
    }
    const clamps = target.clampedBy.length ? ` clamped by ${target.clampedBy.join(',')}` : '';
    console.log(`[forward] mark ${target.mark} (${target.basis}${clamps}) diff ${target.diffUsdc} on index ${indexUsdc}`);

    if (this.config.DRY_RUN) return 'dry-run';

    try {
      await this.chain.submit(encodeManagerData([update]));
      const tx = await this.chain.write(this.config.FUTURE_ASSET, futureAbi, 'pullMark', [this.config.FUTURE_SUB_ID]);
      console.log(`[forward] marked tx=${tx}`);
      return 'published';
    } catch (error) {
      await this.alert('forward-pull-failed', `future ${this.config.FUTURE_SUB_ID}: ${(error as Error).message.slice(0, 300)}`);
      return 'pull-failed';
    }
  }
}

/** max / min of two positive prices, 18dp: how far apart they are, whichever is larger. */
function ratio(a: bigint, b: bigint): bigint {
  return a > b ? (a * 10n ** 18n) / b : (b * 10n ** 18n) / a;
}
