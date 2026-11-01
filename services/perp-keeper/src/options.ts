/**
 * Settling expired options (cNGN options on MarginEngine v2). Pure: chain.ts reads the holdings, this decides.
 *
 * Why the keeper does it: an option's vol cannot be published past its expiry (LyraVolFeed refuses data stamped after
 * it), so once the last surface ages out (30 minutes) an account still holding an expired option cannot be margined,
 * and so cannot trade, withdraw or be liquidated, until `settleOptions(option, account)` turns the option into cash at
 * the settlement price. That price is the dated future's own (FutureFixingSettlementFeed): fixed from the index at
 * expiry, or by the vault's bounded fallback after a day. settleOptions is permissionless and value-neutral, and the
 * engine does not guard it against an open auction: settling first is what makes such an account readable again.
 */

export type OptionHolding = {
  account: bigint;
  option: string;
  subId: bigint;
  balance: bigint;
  /** OptionAsset.calcSettlementValue's flag: the expiry is past and its settlement price is fixed. */
  priceSettled: boolean;
};

export type OptionSweepPlan = {
  /** (account, option) pairs to settleOptions: one call settles every settled series of that option in the account. */
  settle: { account: bigint; option: string }[];
  /** Expired holdings whose price is not fixed yet, with their expiry: the fixing or the fallback is late. */
  awaiting: { account: bigint; option: string; expiry: bigint }[];
};

const UINT32_MAX = 0xffff_ffffn;

/** OptionEncoding.fromSubId's expiry: the low 32 bits. */
export function optionExpiry(subId: bigint): bigint {
  return subId & UINT32_MAX;
}

export function planOptionSettlement(holdings: OptionHolding[], nowSec: bigint): OptionSweepPlan {
  const settle = new Map<string, { account: bigint; option: string }>();
  const awaiting: OptionSweepPlan['awaiting'] = [];
  for (const h of holdings) {
    if (h.balance === 0n) continue;
    const expiry = optionExpiry(h.subId);
    if (expiry > nowSec) continue;
    if (h.priceSettled) settle.set(`${h.account}:${h.option.toLowerCase()}`, { account: h.account, option: h.option });
    else awaiting.push({ account: h.account, option: h.option, expiry });
  }
  return { settle: [...settle.values()], awaiting };
}

/** Expired, unsettled holdings older than `warnSec` past their expiry: the alert's subject. */
export function lateAwaiting(plan: OptionSweepPlan, nowSec: bigint, warnSec: bigint): OptionSweepPlan['awaiting'] {
  return plan.awaiting.filter((a) => nowSec - a.expiry > warnSec);
}
