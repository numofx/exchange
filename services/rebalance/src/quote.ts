/**
 * Prices USDC -> cNGN off HyperFX's live phantom-order snapshot.
 *
 * Deliberately not `IntentGateway.quote()`. @hyperbridge/sdk 2.8.13 prices this pair from the V1
 * `phantomOrderPriceSnapshots` table, which froze on 2026-08-08 at 1393.0 — 1,617 identical rows —
 * and its only validation is that the timestamp parses. The live feed is
 * `phantomOrderPriceSnapshotV2s`, which the SDK never references. Quoting off V1 today asks about
 * 1.8% above market, which no solver bids on, so the order simply expires.
 *
 * The SDK also deducts the 5bps protocol fee before applying the price. Real fills do not: an
 * on-chain 300 USDC order paid out 300 * medianPrice, not 299.85 *. So this prices on gross.
 *
 * `low == median == high` on every snapshot and `bidCount` is 2 — it is an RFQ, not a book, so
 * there is no depth curve to walk. What the auction adds is competition: solvers may bid ABOVE
 * the required output, and the surplus is split 40% to the order owner, 60% to the gateway. The
 * fill is therefore usually a little better than this quote, never worse.
 */
import { STATE_MACHINE_ID } from './venue.js';

export type Snapshot = {
  commitment: string;
  standardAmount: bigint;
  medianPrice: bigint;
  lowestPrice: bigint | null;
  highestPrice: bigint | null;
  bidCount: number;
  snapshotTime: Date;
};

export type Quote = { amountIn: bigint; amountOut: bigint; rate: number; ageSeconds: number; snapshot: Snapshot };

const QUERY = `query LatestV2($tokenA: String!, $tokenB: String!, $chain: String!) {
  phantomOrderPriceSnapshotV2s(
    filter: { and: [
      { tokenA: { equalTo: $tokenA } },
      { tokenB: { equalTo: $tokenB } },
      { chain: { equalTo: $chain } },
      { medianPrice: { isNull: false } }
    ] }
    orderBy: BLOCK_NUMBER_DESC
    first: 1
  ) { nodes { commitment standardAmount medianPrice lowestPrice highestPrice bidCount snapshotTime } } }`;

type Row = {
  commitment: string; standardAmount: string; medianPrice: string;
  lowestPrice: string | null; highestPrice: string | null; bidCount: number; snapshotTime: string;
};

export async function latestSnapshot(indexerUrl: string, tokenIn: string, tokenOut: string): Promise<Snapshot> {
  const res = await fetch(indexerUrl, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      query: QUERY,
      variables: { tokenA: tokenIn.toLowerCase(), tokenB: tokenOut.toLowerCase(), chain: STATE_MACHINE_ID },
    }),
  });
  if (!res.ok) throw new Error(`indexer returned ${res.status}`);
  const body = (await res.json()) as { data?: { phantomOrderPriceSnapshotV2s: { nodes: Row[] } }; errors?: unknown };
  const row = body.data?.phantomOrderPriceSnapshotV2s?.nodes?.[0];
  if (!row) throw new Error(`no live ${tokenIn} -> ${tokenOut} snapshot: ${JSON.stringify(body.errors ?? {})}`);
  return {
    commitment: row.commitment,
    standardAmount: BigInt(row.standardAmount),
    medianPrice: BigInt(row.medianPrice),
    lowestPrice: row.lowestPrice === null ? null : BigInt(row.lowestPrice),
    highestPrice: row.highestPrice === null ? null : BigInt(row.highestPrice),
    bidCount: row.bidCount,
    // The indexer serves naive UTC timestamps.
    snapshotTime: new Date(`${row.snapshotTime}Z`),
  };
}

/** Throws rather than return a price it does not trust: a bad quote here escrows real money. */
export function priceFromSnapshot(snapshot: Snapshot, amountIn: bigint, maxAgeSeconds: number, now = new Date()): Quote {
  if (snapshot.standardAmount <= 0n) throw new Error('snapshot standardAmount is not positive');
  if (snapshot.medianPrice <= 0n) throw new Error('snapshot medianPrice is not positive');
  if (snapshot.bidCount <= 0) throw new Error('snapshot has no bids behind it');
  if (Number.isNaN(snapshot.snapshotTime.getTime())) throw new Error('snapshot time is unparseable');

  const ageSeconds = (now.getTime() - snapshot.snapshotTime.getTime()) / 1000;
  if (ageSeconds > maxAgeSeconds) {
    throw new Error(`snapshot is ${Math.round(ageSeconds)}s old (limit ${maxAgeSeconds}s); refusing to trade on it`);
  }
  const amountOut = (amountIn * snapshot.medianPrice) / snapshot.standardAmount;
  if (amountOut <= 0n) throw new Error('quote rounds down to zero output');
  return { amountIn, amountOut, rate: Number(amountOut) / Number(amountIn), ageSeconds, snapshot };
}
