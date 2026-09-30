import {
  BlockradarProvider,
  BybitP2PProvider,
  QuidaxProvider,
  TextileProvider,
  timeWeightedAverage,
  type RateProvider,
} from 'cngn-rate-picker';

import type { Config } from './config.js';
import type { PegReading } from './peg.js';

/**
 * The index's sources, each reporting cNGN per USD stablecoin -- the unit the perp prices -- and
 * whether it counts toward the minimum number of sources a sample needs.
 *
 * What each one measures (checked against the providers' code and the venues' APIs, 2026-09-30):
 *   quidax      `usdtcngn`: cNGN per USDT, direct. Very thin (median ~1.5 USDT a day), so it is in the
 *               median but counts only while its 24h volume is at least INDEX_QUIDAX_MIN_VOLUME_USD.
 *   blockradar  cNGN per USDT, direct (needs BLOCKRADAR_API_KEY). Counts.
 *   textile     `USDT_NGN`: FIAT NGN per USDT, converted to cNGN through the measured peg. Counts.
 *   bybit-p2p   USDT ads in FIAT NGN, converted the same way. Counts.
 *   hyperfx     `USDC-cNGN` on Base: solver quotes, not trades. Counts only when it passes its own
 *               rules (HyperfxSource); USDC stands in for USDT as it does across the index.
 * A fiat source with no peg available is absent, never converted at an assumed 1:1.
 */

export type SourceReading = {
  source: string;
  /** cNGN per 1 USD stablecoin. */
  cngnPerUsdt: number;
  counts: boolean;
  /** Why it does not count, or how it was derived. */
  note?: string;
};

export type ReadContext = { signal: AbortSignal; fetch: typeof fetch; peg: PegReading };

export type IndexSource = {
  name: string;
  /** Throws when the source has nothing usable to say; the sample goes on without it. */
  read(ctx: ReadContext): Promise<SourceReading>;
};

/** A provider that quotes cNGN directly. `counts` decides, per read, whether it counts. */
export function directCngn(
  provider: RateProvider,
  counts: (ctx: ReadContext) => Promise<{ counts: boolean; note?: string }> = async () => ({ counts: true }),
): IndexSource {
  return {
    name: provider.name,
    async read(ctx) {
      const quote = await provider.getPriceInNgn({ signal: ctx.signal, fetch: ctx.fetch });
      return { source: provider.name, cngnPerUsdt: quote.price, ...(await counts(ctx)) };
    },
  };
}

/** A provider that quotes FIAT NGN, converted to cNGN through the measured peg. */
export function fiatNgn(provider: RateProvider): IndexSource {
  return {
    name: provider.name,
    async read(ctx) {
      if (!ctx.peg.ok) throw new Error(`no cNGN conversion for a fiat NGN quote: ${ctx.peg.reason}`);
      const quote = await provider.getPriceInNgn({ signal: ctx.signal, fetch: ctx.fetch });
      // NGN per USDT / NGN per cNGN = cNGN per USDT.
      return {
        source: provider.name,
        cngnPerUsdt: quote.price / ctx.peg.ngnPerCngn,
        counts: true,
        note: `${quote.price} NGN/USDT at ${ctx.peg.ngnPerCngn.toFixed(6)} NGN/cNGN`,
      };
    },
  };
}

/** Counts Quidax usdtcngn only while its 24h volume (USDT, the market's base) reaches the floor. */
export function quidaxVolumeGate(baseUrl: string, market: string, minVolumeUsd: number) {
  return async (ctx: ReadContext): Promise<{ counts: boolean; note?: string }> => {
    const response = await ctx.fetch(`${baseUrl}/markets/tickers/${market}`, { signal: ctx.signal });
    const body = (await response.json()) as { data?: Record<string, { ticker?: { vol?: unknown } }> };
    const volume = Number(body.data?.[market]?.ticker?.vol ?? 0);
    return volume >= minVolumeUsd
      ? { counts: true }
      : { counts: false, note: `24h volume ${volume.toFixed(2)} USDT is under ${minVolumeUsd}: in the median, not counted` };
  };
}

// --- HyperFX ------------------------------------------------------------------------------------

export type HyperfxRules = {
  url: string;
  book: string;
  fillChain: string;
  /** Depth each side must hold, in USDC, for a snapshot or a live quote to count. */
  minSizeUsd: number;
  minSolvers: number;
  maxSpreadBps: number;
  windowMs: number;
  /** Fewest qualifying snapshots in the window. */
  minSnapshots: number;
  /** How far the live minSize mid may sit from the window TWAP, in bps. */
  maxLiveDeviationBps: number;
};

export type HyperfxSnapshot = {
  recordedAt: string;
  mid: string | null;
  spread: string | null;
  bidSolvers: number;
  askSolvers: number;
  bidDepthBase: string | null;
  askDepthBase: string | null;
};

export type HyperfxLive = { bid: { rate: string; solverCount: number } | null; ask: { rate: string; solverCount: number } | null };

const E18 = 1e18;

/** Whether one bookHistory snapshot may enter the TWAP, and why not. */
export function qualifySnapshot(snapshot: HyperfxSnapshot, rules: HyperfxRules): string | null {
  if (!snapshot.mid) return 'a side is empty';
  if (snapshot.bidSolvers < rules.minSolvers || snapshot.askSolvers < rules.minSolvers) {
    return `solvers bid ${snapshot.bidSolvers} / ask ${snapshot.askSolvers} (need ${rules.minSolvers} each)`;
  }
  const bidDepth = Number(snapshot.bidDepthBase ?? 0) / E18;
  const askDepth = Number(snapshot.askDepthBase ?? 0) / E18;
  if (bidDepth < rules.minSizeUsd || askDepth < rules.minSizeUsd) {
    return `depth bid $${bidDepth.toFixed(0)} / ask $${askDepth.toFixed(0)} (need $${rules.minSizeUsd} each)`;
  }
  const mid = Number(snapshot.mid) / E18;
  const spreadBps = (Number(snapshot.spread ?? 0) / E18 / mid) * 10_000;
  if (spreadBps > rules.maxSpreadBps) return `spread ${spreadBps.toFixed(1)}bps over ${rules.maxSpreadBps}bps`;
  return null;
}

/**
 * The HyperFX reading from a window of snapshots and a live check at minSize: a 15-minute TWAP of
 * the mid over snapshots that each had >= minSolvers per side, >= minSize depth per side and a
 * spread under the cap; then the live best rates at minSize must also have >= minSolvers per side,
 * a spread under the cap, and a mid within maxLiveDeviationBps of that TWAP. The TWAP, not the live
 * mid, is the reading.
 */
export function hyperfxReading(
  snapshots: HyperfxSnapshot[],
  live: HyperfxLive,
  nowMs: number,
  rules: HyperfxRules,
): { ok: true; cngnPerUsdc: number } | { ok: false; reason: string } {
  const qualifying = snapshots.filter((s) => qualifySnapshot(s, rules) === null);
  if (qualifying.length < rules.minSnapshots) {
    const last = snapshots.at(-1);
    const why = last ? qualifySnapshot(last, rules) ?? 'older snapshots failed' : 'no snapshots';
    return { ok: false, reason: `${qualifying.length} of ${rules.minSnapshots} qualifying snapshots in the window (latest: ${why})` };
  }
  const twap = timeWeightedAverage(
    qualifying.map((s) => ({ price: Number(s.mid) / E18, at: Date.parse(s.recordedAt) })),
    nowMs,
  );
  if (twap === null || !Number.isFinite(twap) || twap <= 0) return { ok: false, reason: 'snapshot TWAP is not a positive number' };

  if (!live.bid || !live.ask) return { ok: false, reason: `no live ${live.bid ? 'ask' : 'bid'} at minSize $${rules.minSizeUsd}` };
  if (live.bid.solverCount < rules.minSolvers || live.ask.solverCount < rules.minSolvers) {
    return { ok: false, reason: `live solvers at minSize: bid ${live.bid.solverCount} / ask ${live.ask.solverCount} (need ${rules.minSolvers} each)` };
  }
  const bid = Number(live.bid.rate) / E18;
  const ask = Number(live.ask.rate) / E18;
  const liveMid = (bid + ask) / 2;
  const liveSpreadBps = ((ask - bid) / liveMid) * 10_000;
  if (liveSpreadBps > rules.maxSpreadBps) return { ok: false, reason: `live spread ${liveSpreadBps.toFixed(1)}bps over ${rules.maxSpreadBps}bps` };
  const deviationBps = (Math.abs(liveMid - twap) / twap) * 10_000;
  if (deviationBps > rules.maxLiveDeviationBps) {
    return { ok: false, reason: `live mid ${liveMid.toFixed(2)} is ${deviationBps.toFixed(0)}bps from the window TWAP ${twap.toFixed(2)}` };
  }
  return { ok: true, cngnPerUsdc: twap };
}

async function graphql<T>(ctx: ReadContext, url: string, query: string): Promise<T> {
  const response = await ctx.fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ query }),
    signal: ctx.signal,
  });
  const body = (await response.json()) as { data?: T; errors?: { message: string }[] };
  if (body.errors?.length) throw new Error(`HyperFX: ${body.errors[0]!.message}`);
  if (!body.data) throw new Error(`HyperFX HTTP ${response.status} with no data`);
  return body.data;
}

export function hyperfxSource(rules: HyperfxRules, now: () => number = Date.now): IndexSource {
  return {
    name: 'hyperfx',
    async read(ctx) {
      const to = new Date(now());
      const from = new Date(now() - rules.windowMs);
      const minSizeUsdc = BigInt(Math.round(rules.minSizeUsd)) * 10n ** 18n;
      const data = await graphql<{
        bookHistory: { edges: { node: HyperfxSnapshot }[] };
        bid: { rate: string; solverCount: number } | null;
        ask: { rate: string; solverCount: number } | null;
      }>(
        ctx,
        rules.url,
        `{ bookHistory(book: "${rules.book}", fillChain: "${rules.fillChain}", from: "${from.toISOString()}", to: "${to.toISOString()}", first: 200) {
             edges { node { recordedAt mid spread bidSolvers askSolvers bidDepthBase askDepthBase } } }
           bid: bestRate(tokenIn: "USDC", tokenOut: "cNGN", minSize: "${minSizeUsdc}", fillChain: "${rules.fillChain}") { rate solverCount }
           ask: bestRate(tokenIn: "cNGN", tokenOut: "USDC", minSize: "${minSizeUsdc}", fillChain: "${rules.fillChain}") { rate solverCount } }`,
      );
      const reading = hyperfxReading(
        data.bookHistory.edges.map((edge) => edge.node),
        { bid: data.bid, ask: data.ask },
        now(),
        rules,
      );
      if (!reading.ok) throw new Error(reading.reason);
      return { source: 'hyperfx', cngnPerUsdt: reading.cngnPerUsdc, counts: true, note: 'USDC-cNGN solver quotes, 15m TWAP' };
    },
  };
}

// --- the configured set -------------------------------------------------------------------------

export function buildIndexSources(config: Config): IndexSource[] {
  const sources: IndexSource[] = [
    directCngn(new QuidaxProvider({ baseUrl: config.QUIDAX_API_URL }), quidaxVolumeGate(config.QUIDAX_API_URL, 'usdtcngn', config.INDEX_QUIDAX_MIN_VOLUME_USD)),
    fiatNgn(new TextileProvider()),
    fiatNgn(new BybitP2PProvider()),
  ];
  if (config.BLOCKRADAR_API_KEY) sources.push(directCngn(new BlockradarProvider({ apiKey: config.BLOCKRADAR_API_KEY })));
  if (config.HYPERFX_ENABLED) {
    sources.push(
      hyperfxSource({
        url: config.HYPERFX_URL,
        book: config.HYPERFX_BOOK,
        fillChain: config.HYPERFX_FILL_CHAIN,
        minSizeUsd: config.HYPERFX_MIN_SIZE_USD,
        minSolvers: config.HYPERFX_MIN_SOLVERS,
        maxSpreadBps: config.HYPERFX_MAX_SPREAD_BPS,
        windowMs: config.HYPERFX_TWAP_WINDOW_MS,
        minSnapshots: config.HYPERFX_MIN_SNAPSHOTS,
        maxLiveDeviationBps: config.HYPERFX_MAX_LIVE_DEVIATION_BPS,
      }),
    );
  }
  return sources;
}
