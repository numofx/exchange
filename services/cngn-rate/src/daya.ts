/**
 * Daya Pro's public USD-NGN order book, inverted into cNGN terms: a two-sided quoting input, served on GET /daya.
 *
 * Kept apart from /usd-per-cngn on purpose. That reading (Textile and Bybit P2P USDC corridors) is the independent
 * check a quoter compares this book against; folding Daya into it would leave nothing to compare with.
 *
 * Daya's "USD" is one balance credited by both USDT and USDC deposits; there is no USDT-NGN or USDC-NGN symbol. The
 * owner accepts USDT = USDC = USD and NGN = cNGN (2026-11-21), so USD-NGN reads as USDC/cNGN.
 *
 * Sides swap under inversion: a cNGN bid (buying cNGN for USDC) is backed by Daya's NGN asks (selling USD for NGN),
 * so the best cNGN bid is 1 / best NGN ask, and the best cNGN ask is 1 / best NGN bid.
 *
 * Public endpoint, no key, 100 requests per minute per IP (docs.daya.co/pro/api-reference/get-orderbook). No sandbox
 * and no websocket, so this polls.
 */
import { NGN_PER_USDC_MAX, NGN_PER_USDC_MIN } from './rate.js';

export const DAYA_ORDERBOOK_URL = 'https://api.pro.daya.co/public/v1/orderbook/USD-NGN?depth=100';

/** A level in cNGN terms. */
export type Level = {
  /** USD per cNGN, 18 dp, as a decimal string. */
  usd_per_cngn_e18: string;
  /** The source level's NGN per USD, as Daya printed it. */
  ngn_per_usd: string;
  /** Size in USD, as Daya printed it. */
  usd: string;
};

export type DayaBook = {
  /** Daya's own timestamp for the book, Unix seconds. Staleness is measured from this, not from the fetch. */
  observed_at: number;
  /** When this service fetched it, Unix seconds. */
  fetched_at: number;
  best_bid_usd_per_cngn_e18: string;
  best_ask_usd_per_cngn_e18: string;
  mid_usd_per_cngn_e18: string;
  spread_bps: number;
  /** cNGN bids, best (highest) first: from Daya's NGN asks. */
  bids: Level[];
  /** cNGN asks, best (lowest) first: from Daya's NGN bids. */
  asks: Level[];
};

/** Daya's clock may run ahead of ours by this much before a book is refused as from the future. */
export const MAX_FUTURE_SECONDS = 5;

const e18 = (ngnPerUsd: number) => BigInt(Math.round(1e18 / ngnPerUsd)).toString();

type RawLevel = { price: string; quantity: string };

function levels(raw: unknown, side: string): { p: number; q: number; price: string; quantity: string }[] {
  if (!Array.isArray(raw) || raw.length === 0) throw new Error(`Daya ${side} side is empty`);
  return raw.map((l: RawLevel) => {
    const p = Number(l?.price);
    const q = Number(l?.quantity);
    if (!Number.isFinite(p) || p < NGN_PER_USDC_MIN || p > NGN_PER_USDC_MAX) {
      throw new Error(`Daya ${side} price ${l?.price} is outside ${NGN_PER_USDC_MIN}..${NGN_PER_USDC_MAX}`);
    }
    if (!Number.isFinite(q) || q <= 0) throw new Error(`Daya ${side} quantity ${l?.quantity} is not positive`);
    return { p, q, price: String(l.price), quantity: String(l.quantity) };
  });
}

/** Parses Daya's orderbook response into cNGN terms, or throws: a book it cannot vouch for is never served. */
export function parseDayaBook(body: unknown, nowMs: number): DayaBook {
  const b = body as { success?: boolean; data?: { symbol?: string; bids?: unknown; asks?: unknown; timestamp?: string } };
  if (b?.success !== true || !b.data) throw new Error('Daya orderbook response is not a success');
  if (b.data.symbol !== 'USD-NGN') throw new Error(`Daya orderbook symbol is ${b.data.symbol}, not USD-NGN`);

  const tsMs = Date.parse(b.data.timestamp ?? '');
  if (!Number.isFinite(tsMs)) throw new Error(`Daya orderbook timestamp ${b.data.timestamp} does not parse`);
  if (tsMs / 1000 > nowMs / 1000 + MAX_FUTURE_SECONDS) throw new Error(`Daya orderbook timestamp ${b.data.timestamp} is in the future`);

  // Sorted here rather than trusted: best NGN bid is the highest, best NGN ask the lowest.
  const ngnBids = levels(b.data.bids, 'bid').sort((x, y) => y.p - x.p);
  const ngnAsks = levels(b.data.asks, 'ask').sort((x, y) => x.p - y.p);
  const bestNgnBid = ngnBids[0].p;
  const bestNgnAsk = ngnAsks[0].p;
  if (bestNgnBid >= bestNgnAsk) throw new Error(`Daya book is crossed or locked: bid ${bestNgnBid} >= ask ${bestNgnAsk}`);

  const toLevel = (l: { p: number; price: string; quantity: string }): Level => ({
    usd_per_cngn_e18: e18(l.p),
    ngn_per_usd: l.price,
    usd: l.quantity,
  });
  const midNgn = (bestNgnBid + bestNgnAsk) / 2;
  return {
    observed_at: Math.floor(tsMs / 1000),
    fetched_at: Math.floor(nowMs / 1000),
    best_bid_usd_per_cngn_e18: e18(bestNgnAsk),
    best_ask_usd_per_cngn_e18: e18(bestNgnBid),
    // The mid of the inverted quotes, not 1 / the NGN mid: the two differ by ~spread^2, which is noise at Daya's size.
    mid_usd_per_cngn_e18: BigInt(Math.round((1e18 / bestNgnAsk + 1e18 / bestNgnBid) / 2)).toString(),
    spread_bps: Math.round(((bestNgnAsk - bestNgnBid) / midNgn) * 1e4 * 100) / 100,
    bids: ngnAsks.map(toLevel),
    asks: ngnBids.map(toLevel),
  };
}

export async function fetchDayaBook(nowMs: () => number, fetchFn: typeof fetch = fetch): Promise<DayaBook> {
  const res = await fetchFn(DAYA_ORDERBOOK_URL, { signal: AbortSignal.timeout(5000) });
  if (!res.ok) throw new Error(`Daya orderbook HTTP ${res.status}`);
  return parseDayaBook(await res.json(), nowMs());
}
