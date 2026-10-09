/**
 * What a USDC -> cNGN rebalance would get, from the HyperFX orderbook.
 *
 * The indexer's price feed is gone: `phantomOrderPriceSnapshotV2s` was removed from
 * nexus.indexer.polytope.technology (checked 2026-10-09; the schema now offers only the V1
 * `phantomOrderPriceSnapshots`, still frozen at 1393.0 on 2026-08-08), and @hyperbridge/sdk
 * 2.8.24 no longer reads snapshots at all. It prices from this orderbook, a separate GraphQL
 * service, and so does this.
 *
 * `quotePessimistic` rather than `quote`: one price, from the first level deep enough to fill the
 * whole amount by itself. It is what the trade can be relied on to get, not the best case, which
 * is the right side to err on for both an inventory valuation and a rebalance decision.
 *
 * Amounts on the orderbook are 18dp regardless of the token; both tokens here are 6dp.
 */
import { STATE_MACHINE_ID, TOKEN_DECIMALS } from './venue.js';

const SCALE = 10n ** BigInt(18 - TOKEN_DECIMALS);

const QUERY = `query QuotePessimistic($route: RouteInput!, $amountIn: BigInt!) {
  quotePessimistic(route: $route, amountIn: $amountIn) {
    route side amountIn amountOut rate slippageBps fillable maxFillableIn
  }
}`;

export type OrderbookQuote = {
  /** USDC in, 6dp. */
  amountIn: bigint;
  /** cNGN out, 6dp. */
  amountOut: bigint;
  /** cNGN per USDC. */
  rate: number;
  slippageBps: number;
  /** The most USDC the route can take, 6dp. */
  maxFillableIn: bigint;
};

export type FetchQuote = (orderbookUrl: string, amountIn: bigint) => Promise<OrderbookQuote>;

type Raw = {
  route: string; side: string; amountIn: string; amountOut: string; rate: string | null;
  slippageBps: number; fillable: boolean; maxFillableIn: string;
};

export const orderbookQuote: FetchQuote = async (orderbookUrl, amountIn) => {
  if (amountIn <= 0n) throw new Error('quote amount must be positive');
  const res = await fetch(orderbookUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      query: QUERY,
      variables: {
        route: { tokenIn: 'USDC', tokenOut: 'cNGN', sourceChain: STATE_MACHINE_ID, destinationChain: STATE_MACHINE_ID },
        amountIn: (amountIn * SCALE).toString(),
      },
    }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!res.ok) throw new Error(`orderbook returned ${res.status}`);
  const body = (await res.json()) as { data?: { quotePessimistic: Raw | null }; errors?: unknown };
  const raw = body.data?.quotePessimistic;
  if (!raw) throw new Error(`no USDC -> cNGN quote from the orderbook: ${JSON.stringify(body.errors ?? {})}`);
  return parseQuote(raw);
};

/** Separate from the fetch so the refusals are testable without a network. */
export function parseQuote(raw: Raw): OrderbookQuote {
  const amountIn = BigInt(raw.amountIn) / SCALE;
  const maxFillableIn = BigInt(raw.maxFillableIn) / SCALE;
  if (!raw.fillable) {
    throw new Error(`the orderbook cannot fill ${amountIn} USDC units (max ${maxFillableIn}); refusing to price on it`);
  }
  const amountOut = BigInt(raw.amountOut) / SCALE;
  if (amountOut <= 0n) throw new Error('the orderbook quoted zero output');
  return { amountIn, amountOut, rate: Number(amountOut) / Number(amountIn), slippageBps: raw.slippageBps, maxFillableIn };
}
