import { timeWeightedAverage, withinWindow, type PricePoint } from 'cngn-rate-picker';

/**
 * The cNGN/NGN peg leg: how many NGN one cNGN is worth, measured on Quidax's `cngnngn` market, so
 * the fiat NGN sources can be converted to cNGN rather than assumed equal to it.
 *
 * Measured from the order book's mid, sampled every minute, not from trades: `cngnngn` traded in 27
 * of the 300 hours to 2026-09-30 (about $17 a day), so a trade-based TWAP would be stale nearly all
 * the time, while the book stays two-sided at ~0.9999/1.0001. The value used is a TWAP of those
 * sampled mids, never one spot read. When the market stops answering, the last good peg stands for
 * up to `maxAgeMs` (15 minutes); after that the peg is unavailable, the fiat sources drop out, and
 * the index halts unless enough direct cNGN sources remain.
 */

export type PegRules = {
  windowMs: number;
  /** How long the newest good sample may stand in for a peg feed that stopped answering. */
  maxAgeMs: number;
  /** Largest bid/ask spread on the peg market a sample may have, in bps of the mid. */
  maxSpreadBps: number;
  /** Distance from parity (1 NGN per cNGN) at which the peg guard trips, in bps. */
  guardBps: number;
};

export type PegReading =
  | { ok: true; ngnPerCngn: number; ageMs: number; samples: number; guardTripped: boolean; deviationBps: number }
  | { ok: false; reason: string };

/** Quidax's ticker for `cngnngn`: buy is the best bid, sell the best ask, both NGN per cNGN. */
export type PegTicker = { buy: number; sell: number };

/** A sample from one ticker read, or why it is not one. */
export function pegMid(ticker: PegTicker, maxSpreadBps: number): { ok: true; mid: number } | { ok: false; reason: string } {
  const { buy, sell } = ticker;
  if (!Number.isFinite(buy) || !Number.isFinite(sell) || buy <= 0 || sell <= 0) {
    return { ok: false, reason: `peg book is not two-sided (buy ${buy}, sell ${sell})` };
  }
  if (buy > sell) return { ok: false, reason: `peg book is crossed (buy ${buy} > sell ${sell})` };
  const mid = (buy + sell) / 2;
  const spreadBps = ((sell - buy) / mid) * 10_000;
  if (spreadBps > maxSpreadBps) {
    return { ok: false, reason: `peg spread ${spreadBps.toFixed(1)}bps is over ${maxSpreadBps}bps` };
  }
  return { ok: true, mid };
}

/** The peg from the samples held, as of `nowMs`. */
export function pegReading(samples: PricePoint[], nowMs: number, rules: PegRules): PegReading {
  if (samples.length === 0) return { ok: false, reason: 'no peg sample yet' };
  const newest = samples.reduce((latest, point) => Math.max(latest, point.at), Number.NEGATIVE_INFINITY);
  const ageMs = nowMs - newest;
  if (ageMs > rules.maxAgeMs) {
    return { ok: false, reason: `peg unavailable: newest good sample is ${Math.round(ageMs / 1000)}s old (limit ${Math.round(rules.maxAgeMs / 1000)}s)` };
  }
  const inWindow = withinWindow(samples, nowMs - rules.windowMs);
  const twap = timeWeightedAverage(inWindow.length > 0 ? inWindow : samples.filter((p) => p.at === newest), nowMs);
  if (twap === null || !Number.isFinite(twap) || twap <= 0) return { ok: false, reason: 'peg TWAP is not a positive number' };
  const deviationBps = Math.abs(twap - 1) * 10_000;
  return { ok: true, ngnPerCngn: twap, ageMs, samples: inWindow.length, guardTripped: deviationBps > rules.guardBps, deviationBps };
}

/** Reads Quidax's `cngnngn` ticker. */
export async function fetchPegTicker(baseUrl: string, signal: AbortSignal): Promise<PegTicker> {
  const response = await fetch(`${baseUrl}/markets/tickers/cngnngn`, { signal });
  if (!response.ok) throw new Error(`Quidax cngnngn ticker HTTP ${response.status}`);
  const body = (await response.json()) as { data?: { cngnngn?: { ticker?: { buy?: unknown; sell?: unknown } } } };
  const ticker = body.data?.cngnngn?.ticker;
  if (!ticker) throw new Error('Quidax cngnngn ticker missing');
  return { buy: Number(ticker.buy), sell: Number(ticker.sell) };
}
