/**
 * What the keeper does about one account, given what the chain says about it. Pure, so every branch
 * is testable without a chain; the loop in keeper.ts only reads state in and sends actions out.
 *
 * All amounts are 18dp cash (USD), signed as DutchAuction returns them.
 */

import type { CollateralAsset } from './collateral.js';

export type AuctionView = {
  ongoing: boolean;
  insolvent: boolean;
  /** Cash already paid into the account by earlier solvent bids. */
  reservedCash: bigint;
  /** Chain time the auction started, seconds; 0 when none is ongoing. */
  startTime: bigint;
};

/** One base collateral held as margin: the escrow balance and the price the keeper values it at. */
export type CollateralView = {
  asset: CollateralAsset;
  /** WrappedERC20Asset balance, 18dp of the asset. */
  amount: bigint;
  /**
   * USD per whole unit, 18dp: PerpAsset.getIndexPrice() for cNGN, the market's ISpotFeed.getSpot() for
   * EURC. Null when that read failed (a stale Chainlink feed reverts): the keeper cannot price the
   * haircut, and the engine cannot value the account either.
   */
  price: bigint | null;
};

/** What the keeper applies to one collateral asset it may be paid in. */
export type CollateralRules = {
  /** Haircut on it, bps of its price (CNGN_HAIRCUT_BPS, EURC_HAIRCUT_BPS). */
  haircutBps: bigint;
  /** How much of it the keeper's accounts hold now, 18dp. */
  inventory: bigint;
  /** Most of it the keeper will hold, 18dp; null for no limit. */
  maxInventory: bigint | null;
};

export type AccountView = {
  accountId: bigint;
  /** Maintenance margin: below zero means liquidatable. */
  mm: bigint;
  /** Buffer margin: the solvent auction's target. */
  bm: bigint;
  /** Mark to market: below zero means insolvent. */
  mtm: bigint;
  auction: AuctionView;
  /** getAuctionStatus's canTerminate: the account is back above water. */
  canTerminate: boolean;
  /** getCurrentBidPrice for 100% of the account; only meaningful while an auction is live. */
  bidPrice: bigint | null;
  /** getMaxProportion while solvent (18dp percent), null when it reverts. */
  maxProportion: bigint | null;
  /** Each configured collateral the account holds a positive balance of; empty for cash only. */
  collateral: CollateralView[];
};

export type KeeperRules = {
  /** Least discount to mark-to-market a solvent bid must offer before the keeper takes it, in bps. */
  minSolventDiscountBps: bigint;
  /** Smallest share of an account worth a bid, 18dp; below this the gas is not worth it. */
  minBidPercent: bigint;
  /**
   * Largest bid, in USD (18dp) of margin tied up: for a solvent bid the cash committed (price plus
   * buffer), for an insolvent one the maintenance margin of the share taken -- there the payout means
   * little cash moves, but the whole share's risk does. A bid over it is sized down, not skipped: a
   * later pass takes the next slice. Null for no cap.
   */
  maxBidUsd: bigint | null;
  /** Per configured collateral; an account holding one with no entry here is a wiring error. */
  collateral: Partial<Record<CollateralAsset, CollateralRules>>;
};

export type Action =
  | { kind: 'start'; accountId: bigint }
  | { kind: 'convert'; accountId: bigint }
  | { kind: 'terminate'; accountId: bigint }
  | {
      kind: 'bid';
      accountId: bigint;
      percent: bigint;
      priceLimit: bigint;
      insolvent: boolean;
      /** Cash DutchAuction requires in the bidding account for this bid (_ensureBidderCashBalance). */
      bidderCash: bigint;
      /** The bid that takes everything the auction has left and ends it. */
      finishing?: boolean;
    }
  | { kind: 'none'; accountId: bigint; note?: string };

const ONE = 10n ** 18n;

export function decide(account: AccountView, keeperCash: bigint, rules: KeeperRules): Action {
  const { accountId, auction } = account;

  // A held asset the keeper cannot price: the engine values the account with the same feed, so its
  // margin is unreadable too (or, if only the keeper's read failed, the haircut is). Nothing is done
  // to the account this pass -- no start, no bid -- and the next pass reads the feed again.
  const unpriced = account.collateral.filter((held) => held.price === null).map((held) => held.asset);
  if (unpriced.length > 0) {
    return { kind: 'none', accountId, note: `cannot price ${unpriced.join(', ')} (feed unreadable, stale?): no bid` };
  }

  if (!auction.ongoing) {
    return account.mm < 0n ? { kind: 'start', accountId } : { kind: 'none', accountId };
  }

  // Recovered (the owner topped up, or the price came back): free the account before anything else.
  if (account.canTerminate) return { kind: 'terminate', accountId };

  if (!auction.insolvent) {
    // The solvent phase has run out with the account still under water: hand it to the security module.
    if (account.bidPrice !== null && account.bidPrice <= 0n) {
      return account.mm < 0n ? { kind: 'convert', accountId } : { kind: 'none', accountId, note: 'awaiting terminate' };
    }
    return decideSolventBid(account, keeperCash, rules);
  }

  return decideInsolventBid(account, keeperCash, rules);
}

/**
 * Solvent: the keeper pays `bidPrice × percent` for `percent` of a portfolio worth `mtm × percent`.
 * It bids only at a real discount, and only what its cash can back, since DutchAuction also requires
 * the bidder to hold |bm − reserved| × percent on top of the price. cNGN in the portfolio counts at
 * the index here and at the inventory limit; see decideInsolventBid for the haircut.
 */
function decideSolventBid(account: AccountView, keeperCash: bigint, rules: KeeperRules): Action {
  const { accountId, bidPrice, mtm, maxProportion } = account;
  if (bidPrice === null || maxProportion === null || mtm <= 0n) {
    return { kind: 'none', accountId, note: 'no solvent price' };
  }

  // Judged at the index, cNGN included: the keeper carries the cNGN it is paid in as inventory,
  // like the position itself. Netting the haircut here instead would leave an account whose equity
  // is under the haircut unbiddable for the whole solvent phase (12 hours), position open. The
  // haircut is the insolvent rule's, where it sets what the security module pays.
  const perUnit = bidPrice + abs(account.bm - account.auction.reservedCash);
  const affordable = perUnit === 0n ? ONE : (keeperCash * ONE) / perUnit;
  const { room, bound } = collateralRoom(account, rules);
  const percent = min(maxProportion, affordable, capToMaxBid(perUnit, rules), room, ONE);
  // The finishing bid. What the auction will still sell is below the keeper's minimum (an earlier bid
  // took the rest) and the keeper can take all of it. DutchAuction caps any bid at that proportion
  // and terminates the auction when a bid reaches it, so this is the bid that frees the account:
  // while the auction is open the chain refuses every trade for the owner (BM_AccountUnderLiquidation),
  // and a solvent window runs 12h15m. The discount gate below is waived here -- the amount is a sliver
  // by construction, and a locked account costs its owner more than a few cents of premium.
  if (maxProportion > 0n && maxProportion < rules.minBidPercent && percent === maxProportion) {
    return {
      kind: 'bid',
      accountId,
      percent,
      priceLimit: (bidPrice * percent) / ONE + 1n,
      insolvent: false,
      bidderCash: (perUnit * percent) / ONE + 1n,
      finishing: true,
    };
  }

  const discountBps = ((mtm - bidPrice) * 10_000n) / mtm;
  if (discountBps < rules.minSolventDiscountBps) {
    return { kind: 'none', accountId, note: `discount ${discountBps}bps below ${rules.minSolventDiscountBps}bps` };
  }
  if (percent < rules.minBidPercent) {
    // Say which limit bound: an auction nearly sold out is routine, a keeper out of cash is an alarm.
    const note =
      bound !== null && room < maxProportion && room < affordable
        ? `keeper ${bound} inventory ${rules.collateral[bound]!.inventory} (18dp) leaves room for only ${room} (18dp) of the bid`
        : maxProportion <= affordable
          ? `auction has only ${maxProportion} (18dp) left to sell`
          : `keeper cash covers only ${affordable} (18dp) of the bid`;
    return { kind: 'none', accountId, note };
  }

  // The price limit is what the keeper agreed to at this discount; a later block that costs more reverts.
  return {
    kind: 'bid',
    accountId,
    percent,
    priceLimit: (bidPrice * percent) / ONE + 1n,
    insolvent: false,
    bidderCash: (perUnit * percent) / ONE,
  };
}

/**
 * Insolvent: the security module pays the keeper `−bidPrice × percent` to take `percent` of a
 * portfolio under water. The price starts at the account's mark-to-market (so the payout exactly
 * covers the deficit) and moves toward its maintenance margin over the auction. At the deficit the
 * keeper would carry the position with nothing for the risk, so it waits until the payout covers the
 * deficit plus the same margin it asks of solvent bids, then takes as much as its cash can back
 * (DutchAuction requires |mm| × percent − payout in the bidder's account).
 *
 * cNGN in the portfolio is paid for at the index in the mark-to-market but is worth less to the
 * keeper, which has to sell or hold it: it waits for the haircut on top. Not the SRM's 50% -- the
 * auction's end price is the maintenance-margin deficit, which on cNGN carries that haircut, so a
 * keeper that waited for it would cost the security module the most the auction can charge.
 */
function decideInsolventBid(account: AccountView, keeperCash: bigint, rules: KeeperRules): Action {
  const { accountId, bidPrice, mm, mtm } = account;
  if (bidPrice === null) return { kind: 'none', accountId, note: 'no insolvent price' };

  const paid = bidPrice < 0n ? -bidPrice : 0n;
  const deficit = mtm < 0n ? -mtm : 0n;
  const wanted = (deficit * (10_000n + rules.minSolventDiscountBps)) / 10_000n + collateralHaircut(account, rules);
  if (paid < wanted) {
    return { kind: 'none', accountId, note: `insolvent payout ${paid} below deficit + margin ${wanted}; waiting` };
  }

  const needPerUnit = abs(mm) > paid ? abs(mm) - paid : 0n;
  const affordable = needPerUnit === 0n ? ONE : (keeperCash * ONE) / needPerUnit;
  const { room, bound } = collateralRoom(account, rules);
  const percent = min(affordable, capToMaxBid(abs(mm), rules), room, ONE);
  if (percent < rules.minBidPercent) {
    const note =
      bound !== null && room < affordable
        ? `keeper ${bound} inventory ${rules.collateral[bound]!.inventory} (18dp) leaves room for only ${room} (18dp) of the insolvent bid`
        : `keeper cash covers only ${percent} of the insolvent bid`;
    return { kind: 'none', accountId, note };
  }
  // priceLimit is the most the keeper will PAY; here it is paid, so allow any payout down to zero.
  return { kind: 'bid', accountId, percent, priceLimit: 0n, insolvent: true, bidderCash: (needPerUnit * percent) / ONE };
}

function rulesFor(asset: CollateralAsset, rules: KeeperRules): CollateralRules {
  const found = rules.collateral[asset];
  if (found === undefined) throw new Error(`account holds ${asset} but the keeper has no rules for it`);
  return found;
}

/**
 * What the keeper discounts the account's collateral by, in USD 18dp: the sum over every asset it
 * holds of value × that asset's haircut. Each term rounds on its own, so a cNGN-only account is
 * discounted exactly as before EURC existed.
 */
function collateralHaircut(account: AccountView, rules: KeeperRules): bigint {
  let total = 0n;
  for (const held of account.collateral) {
    const value = (held.amount * held.price!) / ONE; // decide() returned before here on a null price
    total += (value * rulesFor(held.asset, rules).haircutBps) / 10_000n;
  }
  return total;
}

/**
 * The share of the account whose collateral still fits under every inventory limit: the least over
 * the assets it holds, and which asset set it (null when none binds, room is then 100%).
 */
function collateralRoom(account: AccountView, rules: KeeperRules): { room: bigint; bound: CollateralAsset | null } {
  let room = ONE;
  let bound: CollateralAsset | null = null;
  for (const held of account.collateral) {
    const { inventory, maxInventory } = rulesFor(held.asset, rules);
    if (held.amount === 0n || maxInventory === null) continue;
    const left = maxInventory - inventory;
    const share = left <= 0n ? 0n : min((left * ONE) / held.amount, ONE);
    if (share < room) {
      room = share;
      bound = held.asset;
    }
  }
  return { room, bound };
}

/** The share of an account whose `perUnit` (USD per 100% of it) fits inside the max bid. */
function capToMaxBid(perUnit: bigint, rules: KeeperRules): bigint {
  if (rules.maxBidUsd === null || perUnit === 0n) {
    return ONE;
  }
  return (rules.maxBidUsd * ONE) / perUnit;
}

function abs(value: bigint): bigint {
  return value < 0n ? -value : value;
}

function min(...values: bigint[]): bigint {
  return values.reduce((a, b) => (b < a ? b : a));
}
