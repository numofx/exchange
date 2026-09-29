import { parseUnits, type Address } from 'viem';

import type { RestingOrder } from './mark-targets.js';

type PresentedOrder = {
  side: 'buy' | 'sell';
  limit_price: string;
  desired_amount: string;
  filled_amount: string;
  expiry?: number;
  status?: string;
};

type BookResponse = { bids?: PresentedOrder[]; asks?: PresentedOrder[] };

/**
 * The perp's resting orders from markets-service, in engine terms (USD per NGN, NGN amounts). The
 * book endpoint returns engine prices and amounts as decimals, the same shape spot's raw fields
 * have; the perp has no display inversion at this layer.
 */
export async function fetchPerpBook(
  marketsServiceUrl: string,
  perp: Address,
  nowSec: number,
  fetchImpl: typeof fetch = fetch,
): Promise<RestingOrder[]> {
  const url = `${marketsServiceUrl}/v1/book?asset_address=${perp}&sub_id=0`;
  const response = await fetchImpl(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(8_000) });
  if (!response.ok) throw new Error(`markets-service book returned ${response.status}`);
  return parseBook((await response.json()) as BookResponse, nowSec);
}

export function parseBook(body: BookResponse, nowSec: number): RestingOrder[] {
  const orders = [...(body.bids ?? []), ...(body.asks ?? [])];
  const resting: RestingOrder[] = [];
  for (const order of orders) {
    // An order past its expiry no longer matches; the book can list it until it is swept.
    if (order.expiry !== undefined && order.expiry <= nowSec) continue;
    if (order.status !== undefined && order.status !== 'active') continue;
    const remaining = parseUnits(order.desired_amount, 18) - parseUnits(order.filled_amount, 18);
    if (remaining <= 0n) continue;
    resting.push({ side: order.side, price: parseUnits(order.limit_price, 18), remaining });
  }
  return resting;
}
