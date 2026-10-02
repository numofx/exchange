/**
 * What the keeper does about one account, given what the chain says about it. Pure, so every branch
 * is testable without a chain; the loop in keeper.ts only reads state in and sends actions out.
 *
 * All amounts are 18dp cash (USD), signed as DutchAuction returns them.
 */

export type AuctionView = {
  ongoing: boolean;
  insolvent: boolean;
  /** Cash already paid into the account by earlier solvent bids. */
  reservedCash: bigint;
};

/** cNGN held as margin, as the SRM sees it: the escrow balance and the index it is valued at. */
export type CollateralView = {
  /** WrappedERC20Asset balance, 18dp cNGN. */
  cngn: bigint;
  /** PerpAsset.getIndexPrice(): USDC per cNGN, 18dp. */
  indexPrice: bigint;
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
  /** cNGN in the account, or null when it holds none (or no escrow is configured). */
  collateral: CollateralView | null;
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
  /** Haircut on cNGN the keeper is paid in, bps of index value (CNGN_HAIRCUT_BPS). */
  cngnHaircutBps: bigint;
  /** cNGN the keeper's accounts hold now, 18dp. */
  cngnInventory: bigint;
  /** Most cNGN the keeper will hold, 18dp; null for no limit. */
  maxCngnInventory: bigint | null;
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
    }
  | { kind: 'none'; accountId: bigint; note?: string };

const ONE = 10n ** 18n;

export function decide(account: AccountView, keeperCash: bigint, rules: KeeperRules): Action {
  const { accountId, auction } = account;

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
  const discountBps = ((mtm - bidPrice) * 10_000n) / mtm;
  if (discountBps < rules.minSolventDiscountBps) {
    return { kind: 'none', accountId, note: `discount ${discountBps}bps below ${rules.minSolventDiscountBps}bps` };
  }

  const perUnit = bidPrice + abs(account.bm - account.auction.reservedCash);
  const affordable = perUnit === 0n ? ONE : (keeperCash * ONE) / perUnit;
  const room = cngnRoom(account, rules);
  const percent = min(maxProportion, affordable, capToMaxBid(perUnit, rules), room, ONE);
  // The finishing bid: an earlier bid restored maintenance margin and the auction has only a rounding
  // sliver left to sell (it ends at BUFFER margin). Below the keeper's minimum, but a live auction
  // freezes the account for its owner, so the keeper takes the sliver when the cash it pays in is
  // what restores buffer margin and ends the auction. When the price has decayed too far for that,
  // the sliver waits: the solvent window ends at maintenance margin, and terminate runs then.
  const paysIn = (bidPrice * maxProportion) / ONE;
  if (percent < rules.minBidPercent && percent === maxProportion && maxProportion > 0n && account.mm >= 0n && paysIn >= abs(account.bm)) {
    return {
      kind: 'bid',
      accountId,
      percent,
      priceLimit: (bidPrice * percent) / ONE + 1n,
      insolvent: false,
      bidderCash: (perUnit * percent) / ONE + 1n,
    };
  }
  if (percent < rules.minBidPercent) {
    // Say which limit bound: an auction nearly sold out is routine, a keeper out of cash is an alarm.
    const note =
      room < maxProportion && room < affordable
        ? `keeper cNGN inventory ${rules.cngnInventory} (18dp) leaves room for only ${room} (18dp) of the bid`
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
  const wanted = (deficit * (10_000n + rules.minSolventDiscountBps)) / 10_000n + cngnHaircut(account, rules);
  if (paid < wanted) {
    return { kind: 'none', accountId, note: `insolvent payout ${paid} below deficit + margin ${wanted}; waiting` };
  }

  const needPerUnit = abs(mm) > paid ? abs(mm) - paid : 0n;
  const affordable = needPerUnit === 0n ? ONE : (keeperCash * ONE) / needPerUnit;
  const room = cngnRoom(account, rules);
  const percent = min(affordable, capToMaxBid(abs(mm), rules), room, ONE);
  if (percent < rules.minBidPercent) {
    const note =
      room < affordable
        ? `keeper cNGN inventory ${rules.cngnInventory} (18dp) leaves room for only ${room} (18dp) of the insolvent bid`
        : `keeper cash covers only ${percent} of the insolvent bid`;
    return { kind: 'none', accountId, note };
  }
  // priceLimit is the most the keeper will PAY; here it is paid, so allow any payout down to zero.
  return { kind: 'bid', accountId, percent, priceLimit: 0n, insolvent: true, bidderCash: (needPerUnit * percent) / ONE };
}

/** What the keeper discounts the account's cNGN by, in USD 18dp: index value × haircut. */
function cngnHaircut(account: AccountView, rules: KeeperRules): bigint {
  if (account.collateral === null) return 0n;
  const value = (account.collateral.cngn * account.collateral.indexPrice) / ONE;
  return (value * rules.cngnHaircutBps) / 10_000n;
}

/** The share of the account whose cNGN still fits under the keeper's inventory limit. */
function cngnRoom(account: AccountView, rules: KeeperRules): bigint {
  if (account.collateral === null || account.collateral.cngn === 0n || rules.maxCngnInventory === null) return ONE;
  const room = rules.maxCngnInventory - rules.cngnInventory;
  if (room <= 0n) return 0n;
  return min((room * ONE) / account.collateral.cngn, ONE);
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
