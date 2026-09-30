/**
 * The index: what one USD of stablecoin is worth in NGN, turned into the perp's USDC-per-cNGN price.
 *
 * Everything here is pure, so every refusal can be tested without a network. The publisher's job
 * is to fail closed: an index it is not sure of is worse than no index, because a stale feed halts
 * the market (trading and liquidation alike) while a wrong one liquidates solvent traders.
 *
 * Why this does not use ExchangeRatePicker's own multi-source mode: with `threshold > 1` the picker
 * averages the FIRST `threshold` successes, weighted by the gaps between their fetch times, and never
 * compares them. That is neither a median nor a disagreement check. The picker's providers are used
 * individually instead, and the aggregation below is ours.
 */
import { timeWeightedAverage, withinWindow, type PricePoint } from 'cngn-rate-picker';

export type SourceQuote = {
  /** Provider name, e.g. "quidax". */
  source: string;
  /** NGN per 1 USDT, as the provider reported it. */
  ngnPerUsdt: number;
};

export type SampleRules = {
  /** Fewest sources a sample may be built from. */
  minSources: number;
  /** Largest distance any source may sit from the median, in bps of the median. */
  maxSourceDeviationBps: number;
};

export type SampleResult =
  | { ok: true; median: number; sources: string[] }
  | { ok: false; reason: string };

/** Median of the sources' NGN-per-USDT, refused when too few answered or any one disagrees. */
export function aggregateSample(quotes: SourceQuote[], rules: SampleRules): SampleResult {
  const valid = quotes.filter((quote) => Number.isFinite(quote.ngnPerUsdt) && quote.ngnPerUsdt > 0);
  if (valid.length < rules.minSources) {
    return { ok: false, reason: `only ${valid.length} of ${rules.minSources} required sources answered` };
  }

  const median = medianOf(valid.map((quote) => quote.ngnPerUsdt));
  const outliers = valid.filter((quote) => deviationBps(quote.ngnPerUsdt, median) > rules.maxSourceDeviationBps);
  if (outliers.length > 0) {
    const detail = outliers
      .map((quote) => `${quote.source}=${quote.ngnPerUsdt} (${deviationBps(quote.ngnPerUsdt, median).toFixed(0)}bps)`)
      .join(', ');
    return { ok: false, reason: `sources disagree with median ${median}: ${detail}` };
  }

  return { ok: true, median, sources: valid.map((quote) => quote.source) };
}

export type WindowRules = {
  windowMs: number;
  /** Fewest accepted samples the window must hold before a TWAP means anything. */
  minSamples: number;
  /**
   * Oldest the NEWEST accepted sample may be. Without it, a run of refused samples (sources that
   * disagree, or stopped answering) still leaves older accepted ones in the window, and every
   * publish would re-sign a TWAP of the past -- the market running on a price nobody is confirming.
   */
  maxNewestAgeMs: number;
};

export type TwapResult = { ok: true; ngnPerUsdt: number; samples: number } | { ok: false; reason: string };

/**
 * Time-weighted average of the accepted samples in the trailing window. A window with too few
 * samples is refused rather than averaged: after a restart, or through a stretch of refused
 * samples, the "TWAP" would otherwise be one or two prints wearing a 15-minute label.
 */
export function windowTwap(samples: PricePoint[], nowMs: number, rules: WindowRules): TwapResult {
  const inWindow = withinWindow(samples, nowMs - rules.windowMs);
  const newest = inWindow.reduce((latest, point) => Math.max(latest, point.at), Number.NEGATIVE_INFINITY);
  if (inWindow.length > 0 && nowMs - newest > rules.maxNewestAgeMs) {
    return {
      ok: false,
      reason: `newest accepted sample is ${Math.round((nowMs - newest) / 1000)}s old (limit ${Math.round(rules.maxNewestAgeMs / 1000)}s): sources have not confirmed the price since`,
    };
  }
  if (inWindow.length < rules.minSamples) {
    return { ok: false, reason: `window holds ${inWindow.length} of ${rules.minSamples} required samples` };
  }
  const twap = timeWeightedAverage(inWindow, nowMs);
  if (twap === null || !Number.isFinite(twap) || twap <= 0) {
    return { ok: false, reason: 'window TWAP is not a positive number' };
  }
  return { ok: true, ngnPerUsdt: twap, samples: inWindow.length };
}

export type JumpRules = {
  /** Largest move from the last published index a new one may make, in bps. */
  maxJumpBps: number;
};

/**
 * Refuses an index that has moved too far from the last one published. A genuine devaluation will
 * trip this too; that is deliberate. The market halts and an operator decides, rather than a
 * publisher liquidating half the book on one bad print. That decision is `--accept-index-step`
 * (index-step.ts): one publish, approved by name, with the keeper confirmed live first.
 */
export function checkJump(
  nextUsdPerNgn: bigint,
  lastUsdPerNgn: bigint | null,
  rules: JumpRules,
): { ok: true } | { ok: false; reason: string } {
  if (lastUsdPerNgn === null || lastUsdPerNgn === 0n) {
    return { ok: true };
  }
  const moveBps = stepBps(nextUsdPerNgn, lastUsdPerNgn);
  if (Math.abs(moveBps) > rules.maxJumpBps) {
    return { ok: false, reason: `index would move ${moveBps}bps from ${lastUsdPerNgn}, over ${rules.maxJumpBps}bps` };
  }
  return { ok: true };
}

/** Signed move from `from` to `to`, in bps of `from`. */
export function stepBps(to: bigint, from: bigint): number {
  return Number(((to - from) * 10_000n) / from);
}

/**
 * NGN per USDT to the perp's denomination: USDC per cNGN, 18dp. Quidax and Blockradar quote cNGN
 * per USDT; Textile and Bybit P2P quote fiat NGN per USDT. So this assumes cNGN ~ NGN and
 * USDT ~ USDC: a cNGN depeg or a USDT/USDC spread moves the market away from the index without
 * moving the index.
 */
export function toUsdPerNgn(ngnPerUsdt: number): bigint {
  if (!Number.isFinite(ngnPerUsdt) || ngnPerUsdt <= 0) {
    throw new Error(`cannot invert ${ngnPerUsdt}`);
  }
  // 1e36 / (ngnPerUsdt * 1e18), computed at 1e18 precision on the rate so no float reaches 1e18 scale.
  const rate18 = BigInt(Math.round(ngnPerUsdt * 1e9)) * 1_000_000_000n;
  return 10n ** 36n / rate18;
}

function medianOf(values: number[]): number {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 1 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

function deviationBps(value: number, reference: number): number {
  return (Math.abs(value - reference) / reference) * 10_000;
}
