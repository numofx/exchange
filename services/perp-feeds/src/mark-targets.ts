/**
 * Mark and impact prices from the venue's own perp book, relative to the index.
 *
 * Ported from contracts/risk-core/scripts/update_btc_squared_feeds.py (mark = book mid clamped to
 * the index ± a maximum basis), with two changes a thin venue book needs:
 *
 *  - Impact prices are the average fill for a fixed notional on each side of the book, not a fixed
 *    spread around the mark. PerpAsset funds on them, so they should say what a real order pays.
 *  - Any side without that depth reads as the index. A missing side is then no premium in either
 *    direction, rather than a funding rate conjured from one resting order.
 *
 * Every price is USD per NGN at 18dp, the perp's engine denomination.
 */

export type BookSide = 'buy' | 'sell';

/** One resting order, in engine terms: price in USD per NGN, amount in NGN. */
export type RestingOrder = {
  side: BookSide;
  price: bigint;
  remaining: bigint;
};

export type MarkRules = {
  /** Farthest the mark and impact prices may sit from the index, in bps. */
  maxBasisBps: bigint;
  /** Notional, in USD at 18dp, an impact price must be able to fill. */
  impactNotional: bigint;
};

export type MarkTargets = {
  mark: bigint;
  impactAsk: bigint;
  impactBid: bigint;
  /** Why each target is what it is, for the publisher's log line. */
  basis: { mark: 'book-mid' | 'index'; impactAsk: 'depth' | 'index'; impactBid: 'depth' | 'index' };
};

const ONE = 10n ** 18n;

export function computeMarkTargets(index: bigint, orders: RestingOrder[], rules: MarkRules): MarkTargets {
  if (index <= 0n) throw new Error('index must be positive');

  // Engine "buy" is a long NGN bid; "sell" is an ask. Best first on each side.
  const bids = orders.filter((o) => o.side === 'buy' && o.remaining > 0n).sort((a, b) => cmp(b.price, a.price));
  const asks = orders.filter((o) => o.side === 'sell' && o.remaining > 0n).sort((a, b) => cmp(a.price, b.price));

  const bestBid = bids[0]?.price ?? null;
  const bestAsk = asks[0]?.price ?? null;
  const crossed = bestBid !== null && bestAsk !== null && bestBid >= bestAsk;

  const mark =
    bestBid !== null && bestAsk !== null && !crossed ? clamp((bestBid + bestAsk) / 2n, index, rules.maxBasisBps) : index;

  const askFill = crossed ? null : averageFill(asks, rules.impactNotional);
  const bidFill = crossed ? null : averageFill(bids, rules.impactNotional);
  let impactAsk = askFill === null ? index : clamp(askFill, index, rules.maxBasisBps);
  let impactBid = bidFill === null ? index : clamp(bidFill, index, rules.maxBasisBps);

  // PerpAsset reverts funding when impact ask < impact bid. Clamping can produce that from a book
  // that was not crossed, so fold both to the mark rather than publish something the chain rejects.
  if (impactAsk < impactBid) {
    impactAsk = mark;
    impactBid = mark;
  }

  return {
    mark,
    impactAsk,
    impactBid,
    basis: {
      mark: mark === index && (bestBid === null || bestAsk === null || crossed) ? 'index' : 'book-mid',
      impactAsk: askFill === null ? 'index' : 'depth',
      impactBid: bidFill === null ? 'index' : 'depth',
    },
  };
}

/**
 * Volume-weighted price to fill `notional` USD walking one side of the book, or null when the side
 * cannot fill it. `notional` and prices are 18dp USD; amounts are 18dp NGN.
 */
export function averageFill(side: RestingOrder[], notional: bigint): bigint | null {
  if (notional <= 0n) throw new Error('impact notional must be positive');
  let usdLeft = notional;
  let ngnTaken = 0n;
  for (const order of side) {
    const orderUsd = (order.remaining * order.price) / ONE;
    if (orderUsd >= usdLeft) {
      ngnTaken += (usdLeft * ONE) / order.price;
      usdLeft = 0n;
      break;
    }
    ngnTaken += order.remaining;
    usdLeft -= orderUsd;
  }
  if (usdLeft > 0n || ngnTaken === 0n) return null;
  return (notional * ONE) / ngnTaken;
}

export function clamp(price: bigint, index: bigint, maxBasisBps: bigint): bigint {
  const cap = (index * maxBasisBps) / 10_000n;
  if (price > index + cap) return index + cap;
  if (price < index - cap) return index - cap;
  return price;
}

/** The signed diff a LyraSpotDiffFeed stores: target minus index, checked to fit int96. */
export function toSpotDiff(target: bigint, index: bigint): bigint {
  const diff = target - index;
  const limit = 2n ** 95n;
  if (diff < -limit || diff >= limit) throw new Error(`diff ${diff} does not fit int96`);
  return diff;
}

function cmp(a: bigint, b: bigint): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
