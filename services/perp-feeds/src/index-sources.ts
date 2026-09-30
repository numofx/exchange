import { BybitP2PProvider, QuidaxProvider, TextileProvider, type RateProvider } from 'cngn-rate-picker';

import type { Config } from './config.js';

/**
 * The index's sources: FIAT NGN per USDT from three independent venues, taken as cNGN per USDT at
 * redemption parity. cNGN's price is held by redemption (1 cNGN redeems for 1 NGN), not by trading,
 * so the deep fiat NGN/USDT markets are the right basis and the thin cNGN trading markets are not.
 * Whether cNGN still sits at that parity is watched separately by the peg tripwire (peg.ts), which
 * halts the index and pages when it breaks; the tripwire is not a source and does not convert.
 *
 *   quidax     `usdtngn`, NGN per USDT (~1.3M USDT a day)
 *   textile    `USDT_NGN`, NGN per USDT (Textile Credit FX feed)
 *   bybit-p2p  USDT ads in NGN (P2P, fraud-filtered)
 *
 * USDT stands in for USDC, which the perp settles in.
 */

export type SourceReading = {
  source: string;
  /** cNGN per 1 USD stablecoin: the venue's NGN per USDT at redemption parity. */
  cngnPerUsdt: number;
};

export type ReadContext = { signal: AbortSignal; fetch: typeof fetch };

export type IndexSource = {
  name: string;
  /** Throws when the source has nothing usable to say; the sample goes on without it. */
  read(ctx: ReadContext): Promise<SourceReading>;
};

/** A fiat NGN per USDT quote, as cNGN per USDT at redemption parity. */
export function fiatNgnAtParity(provider: RateProvider): IndexSource {
  return {
    name: provider.name,
    async read(ctx) {
      const quote = await provider.getPriceInNgn({ signal: ctx.signal, fetch: ctx.fetch });
      return { source: provider.name, cngnPerUsdt: quote.price };
    },
  };
}

export function buildIndexSources(config: Config): IndexSource[] {
  return [
    fiatNgnAtParity(new QuidaxProvider({ baseUrl: config.QUIDAX_API_URL, market: 'usdtngn' })),
    fiatNgnAtParity(new TextileProvider()),
    fiatNgnAtParity(new BybitP2PProvider()),
  ];
}
