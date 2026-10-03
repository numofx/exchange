import { timeWeightedAverage, withinWindow } from 'cngn-rate-picker';
/** A sample from one ticker read, or why it is not one. */
export function pegMid(ticker, maxSpreadBps) {
    const { buy, sell } = ticker;
    if (!Number.isFinite(buy) || !Number.isFinite(sell) || buy <= 0 || sell <= 0) {
        return { ok: false, reason: `peg book is not two-sided (buy ${buy}, sell ${sell})` };
    }
    if (buy > sell)
        return { ok: false, reason: `peg book is crossed (buy ${buy} > sell ${sell})` };
    const mid = (buy + sell) / 2;
    const spreadBps = ((sell - buy) / mid) * 10_000;
    if (spreadBps > maxSpreadBps) {
        return { ok: false, reason: `peg spread ${spreadBps.toFixed(1)}bps is over ${maxSpreadBps}bps` };
    }
    return { ok: true, mid };
}
/** The tripwire's reading from the samples in the window, as of `nowMs`. */
export function pegReading(samples, nowMs, rules) {
    const inWindow = withinWindow(samples, nowMs - rules.windowMs);
    if (inWindow.length === 0) {
        return { state: 'blind', reason: `no good peg sample in the last ${Math.round(rules.windowMs / 60_000)} minutes` };
    }
    const twap = timeWeightedAverage(inWindow, nowMs);
    if (twap === null || !Number.isFinite(twap) || twap <= 0)
        return { state: 'blind', reason: 'peg TWAP is not a positive number' };
    const deviationBps = Math.abs(twap - 1) * 10_000;
    return { state: 'watching', ngnPerCngn: twap, deviationBps, samples: inWindow.length, tripped: deviationBps > rules.guardBps };
}
/** Reads Quidax's `cngnngn` ticker. */
export async function fetchPegTicker(baseUrl, signal) {
    const response = await fetch(`${baseUrl}/markets/tickers/cngnngn`, { signal });
    if (!response.ok)
        throw new Error(`Quidax cngnngn ticker HTTP ${response.status}`);
    const body = (await response.json());
    const ticker = body.data?.cngnngn?.ticker;
    if (!ticker)
        throw new Error('Quidax cngnngn ticker missing');
    return { buy: Number(ticker.buy), sell: Number(ticker.sell) };
}
