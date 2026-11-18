/**
 * The cNGN reference price for the OnchainBook maker's divergence guard: USD per cNGN, 18 dp.
 *
 * The engine has no cNGN price but the index (engine market 1's signed spot feed), so the book maker cannot compare
 * the index with an independent on-chain feed as it does for EURC. The owner chose cngn-rate-picker (2026-11-18) as
 * that second price for now.
 *
 * NOT fully independent of the index: perp-feeds builds the index from the same library's providers (Quidax usdtngn,
 * Textile and Bybit P2P, all USDT; index-sources.ts). This reads the USDC corridors instead (Textile USDC_NGN, Bybit
 * USDC P2P), which the index does not read: it catches a broken or stale index publisher and a USDT-only dislocation,
 * not a failure of Textile or Bybit as a whole.
 *
 * cNGN at redemption parity: 1 cNGN = 1 NGN, as the index assumes. USDC = 1 USD.
 */
import { BybitP2PProvider, ExchangeRatePicker, TextileProvider } from 'cngn-rate-picker';

export type Reading = {
  /** USD per cNGN, 18 dp, as a decimal string: what the book maker reads. */
  usd_per_base_e18: string;
  /** Unix seconds of the successful read. */
  observed_at: number;
  ngn_per_usdc: number;
  provider: string;
  sources: { provider: string; ngn_per_usdc: number }[];
};

/** A plausible NGN per USDC: outside this the reading is refused, not served (the index's own sanity range). */
export const NGN_PER_USDC_MIN = 500;
export const NGN_PER_USDC_MAX = 5000;

export type Quote = { rate: number; provider: string; sources?: { provider: string; price: number }[] };

export function reading(q: Quote, nowMs: number): Reading {
  if (!Number.isFinite(q.rate) || q.rate < NGN_PER_USDC_MIN || q.rate > NGN_PER_USDC_MAX) {
    throw new Error(`NGN per USDC ${q.rate} from ${q.provider} is outside ${NGN_PER_USDC_MIN}..${NGN_PER_USDC_MAX}`);
  }
  // 1e18 / rate: exact enough for a guard measured in tens of bps (a double carries ~15 significant digits).
  const e18 = BigInt(Math.round(1e18 / q.rate));
  return {
    usd_per_base_e18: e18.toString(),
    observed_at: Math.floor(nowMs / 1000),
    ngn_per_usdc: q.rate,
    provider: q.provider,
    sources: (q.sources ?? []).map((s) => ({ provider: s.provider, ngn_per_usdc: s.price })),
  };
}

export function usdcPicker(): { getStablecoinToNgn(): Promise<Quote> } {
  return new ExchangeRatePicker({
    asset: 'USDC',
    providers: [new TextileProvider({ asset: 'USDC' }), new BybitP2PProvider({ asset: 'USDC' })],
  }) as unknown as { getStablecoinToNgn(): Promise<Quote> };
}
