import { timeWeightedAverage, withinWindow, type PricePoint } from 'cngn-rate-picker';

/**
 * The peg tripwire: whether cNGN still trades at its NGN redemption parity, measured on Quidax's
 * `cngnngn` market. It is NOT a source and it does NOT convert anything -- the index is fiat
 * NGN/USDT taken at parity (index-sources.ts). It only stops the index: when the measured peg sits
 * more than PEG_GUARD_BPS from 1, every sample is refused (the market halts once the index goes
 * stale) and the pager pages "peg guard".
 *
 * Measured from the order book's mid, sampled every minute, as a TWAP over PEG_TWAP_WINDOW_MS:
 * `cngnngn` traded in 27 of the 300 hours to 2026-09-30, so a trade-based measure would be stale
 * nearly all the time, while the book stays two-sided at ~0.9999/1.0001. When the market stops
 * answering the tripwire is blind: the index carries on at parity (redemption does not depend on
 * Quidax) and the status file says so.
 */

export type PegRules = {
  windowMs: number;
  /** Largest bid/ask spread on the peg market a sample may have, in bps of the mid. */
  maxSpreadBps: number;
  /** Distance from parity (1 NGN per cNGN) at which the tripwire trips, in bps. */
  guardBps: number;
};

export type PegReading =
  | { state: 'watching'; ngnPerCngn: number; deviationBps: number; samples: number; tripped: boolean }
  | { state: 'blind'; reason: string };

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

/** The tripwire's reading from the samples in the window, as of `nowMs`. */
export function pegReading(samples: PricePoint[], nowMs: number, rules: PegRules): PegReading {
  const inWindow = withinWindow(samples, nowMs - rules.windowMs);
  if (inWindow.length === 0) {
    return { state: 'blind', reason: `no good peg sample in the last ${Math.round(rules.windowMs / 60_000)} minutes` };
  }
  const twap = timeWeightedAverage(inWindow, nowMs);
  if (twap === null || !Number.isFinite(twap) || twap <= 0) return { state: 'blind', reason: 'peg TWAP is not a positive number' };
  const deviationBps = Math.abs(twap - 1) * 10_000;
  return { state: 'watching', ngnPerCngn: twap, deviationBps, samples: inWindow.length, tripped: deviationBps > rules.guardBps };
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
