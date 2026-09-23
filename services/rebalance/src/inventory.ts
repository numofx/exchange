/**
 * Decides when the market maker needs a rebalance.
 *
 * The failure this watches for is the bid side going dark. The market maker's flow is
 * one-directional -- it sells cNGN for USDC -- so cNGN drains while USDC piles up, and the first
 * visible symptom is an order book with no bids. By then the venue has already stopped quoting one
 * side, which is what this exists to get ahead of.
 *
 * Kept pure and separate from the reads so the thresholds are testable without a chain: the point
 * of an alert is that it fires, and an alert nobody has watched fire is the kind this repo has
 * repeatedly found not to work.
 */
import { formatUnits } from 'viem';
import { LEDGER_DECIMALS } from './venue.js';

export type InventoryReading = {
  /** Subaccount holdings, 18dp as SubAccounts reports them. */
  usdc: bigint;
  cngn: bigint;
  /** cNGN per USDC, from the live HyperFX feed — what a rebalance would actually convert at. */
  rate: number;
};

export type InventoryThresholds = {
  /**
   * Rebalance when cNGN's share of total inventory value falls below this fraction.
   *
   * A share rather than an absolute USDC figure, because absolute USDC is not the condition. The
   * first version of this alerted on "idle USDC over $200" and fired on a subaccount holding $310
   * USDC against $348 of cNGN -- a balanced, well-funded book where converting more USDC would
   * have made the imbalance worse. A threshold that is wrong the first time it runs is one an
   * operator learns to ignore.
   */
  cngnMinShare: number;
  /** Below this much cNGN (valued in USD), the bid side is nearly dark whatever the share says. */
  cngnFloorUsd: number;
  /** The market maker's own halt, for context in the message. Purely informational. */
  haltNetInventoryUsd?: number;
};

export type Verdict = {
  action: 'none' | 'rebalance' | 'urgent';
  usdcUsd: number;
  cngnUsd: number;
  /** cNGN's share of total inventory value, 0..1. */
  cngnShare: number;
  reasons: string[];
  message: string;
};

export function assessInventory(reading: InventoryReading, thresholds: InventoryThresholds, subaccount: bigint): Verdict {
  if (!(reading.rate > 0)) throw new Error('rate must be positive to value the cNGN side');
  const usdcUsd = Number(formatUnits(reading.usdc, LEDGER_DECIMALS));
  const cngnUsd = Number(formatUnits(reading.cngn, LEDGER_DECIMALS)) / reading.rate;

  const total = usdcUsd + cngnUsd;
  // An empty subaccount is not lopsided; it is empty, and nothing here can fix that.
  const cngnShare = total > 0 ? cngnUsd / total : 1;

  const reasons: string[] = [];
  // Urgent and routine are separate conditions, not a severity ladder on one number: a nearly dark
  // bid side is a live problem, a drifting ratio is only a pending one. Both can be true at once.
  const urgent = cngnUsd < thresholds.cngnFloorUsd && total > 0;
  if (urgent) reasons.push(`cNGN side is $${cngnUsd.toFixed(0)}, under the $${thresholds.cngnFloorUsd} floor — bids will go dark`);
  const routine = cngnShare < thresholds.cngnMinShare;
  if (routine) {
    reasons.push(`cNGN is ${(cngnShare * 100).toFixed(0)}% of inventory, under the ${(thresholds.cngnMinShare * 100).toFixed(0)}% floor`);
  }
  if (thresholds.haltNetInventoryUsd !== undefined && usdcUsd >= thresholds.haltNetInventoryUsd * 0.8) {
    reasons.push(`within 20% of the market maker's $${thresholds.haltNetInventoryUsd} inventory halt`);
  }

  const action: Verdict['action'] = urgent ? 'urgent' : routine ? 'rebalance' : 'none';
  const head = action === 'urgent'
    ? `cNGN rebalance URGENT (sub ${subaccount})`
    : action === 'rebalance'
      ? `cNGN rebalance due (sub ${subaccount})`
      : `cNGN inventory healthy (sub ${subaccount})`;
  const balances = `USDC $${usdcUsd.toFixed(0)} / cNGN $${cngnUsd.toFixed(0)} (cNGN ${(cngnShare * 100).toFixed(0)}%) at ${reading.rate.toFixed(2)}`;
  const body = reasons.length ? `${balances}. ${reasons.join('; ')}.` : `${balances}.`;
  // The next step is a human one -- a withdrawal pays out only to the subaccount owner and cannot
  // be delegated -- so the message says what to do rather than just what is true.
  //
  // It is TWO moves, not one. An earlier version read "withdraw to the rebalance signer", which the
  // chain cannot do: the action data is (asset, amount) with no recipient, so a withdrawal always
  // pays the owner. An operator following that literally goes looking for an argument that does not
  // exist. Full procedure in services/rebalance/RUNBOOK.md.
  const next = action === 'none'
    ? ''
    : ' Withdraw USDC from the subaccount (pays the owner), forward it to the rebalance signer, then `pnpm rebalance swap <amount> --execute` and `pnpm rebalance deposit --execute`. Runbook: services/rebalance/RUNBOOK.md.';
  return { action, usdcUsd, cngnUsd, cngnShare, reasons, message: `${head}: ${body}${next}` };
}
