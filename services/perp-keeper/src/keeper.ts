import type { Alerter } from './alert.js';
import type { AuctionCall, KeeperChain } from './chain.js';
import type { Config } from './config.js';
import { decide, type Action } from './decide.js';
import { assessHealth, fmt } from './health.js';

/**
 * One pass: find every account, read it, decide, act; then check the stack's health. An account
 * that cannot be read is an alert, not a skip — an unreadable margin is usually a stale feed, and a
 * stale feed means liquidations are frozen along with trading.
 */
export async function runOnce(config: Config, chain: KeeperChain, alert: Alerter): Promise<Action[]> {
  const rules = {
    minSolventDiscountBps: config.MIN_SOLVENT_DISCOUNT_BPS,
    minBidPercent: BigInt(Math.round(config.MIN_BID_PERCENT * 1e16)),
    maxBidUsd: config.MAX_BID_USD,
  };

  // Throws (a failed pass, so /health fails) when the funding account cannot fund a bid.
  await chain.assertFundingAccount();
  const accounts = await chain.discoverAccounts();
  const actions: Action[] = [];
  let keeperCash = await chain.keeperCash();

  for (const accountId of accounts) {
    let action: Action;
    try {
      action = decide(await chain.readAccount(accountId), keeperCash, rules);
    } catch (error) {
      await alert('margin-unreadable', `cannot read margin for account ${accountId} (stale feed?): ${(error as Error).message}`);
      continue;
    }
    actions.push(action);
    if (action.kind === 'none') {
      if (action.note) console.log(`[keeper] #${accountId}: ${action.note}`);
      continue;
    }

    let freshBidder: bigint | null = null;
    try {
      // A live bid goes from a fresh account funded for exactly this bid (plus 2% for the block it
      // lands in). A dry run simulates from the funding account, which is cash-only and so a valid
      // bidder, without creating anything.
      const bidder =
        action.kind === 'bid' && !config.DRY_RUN
          ? await chain.createBidAccount((action.bidderCash * 102n) / 100n + 1n)
          : config.KEEPER_ACCOUNT;
      if (action.kind === 'bid' && !config.DRY_RUN) freshBidder = bidder;
      const call = toCall(action, bidder);
      const { sent } = await chain.execute(call, config.DRY_RUN);
      console.log(`[keeper] #${accountId}: ${describe(action)} ${sent ? `tx=${sent}` : '(dry-run, simulated ok)'}`);
      await alert(`action-${action.kind}-${accountId}`, `${config.DRY_RUN ? 'DRY-RUN ' : ''}${describe(action)} on account ${accountId}`);
      // A bid spends keeper cash; re-read before sizing the next one against a balance it no longer has.
      if (action.kind === 'bid' && sent) keeperCash = await chain.keeperCash();
    } catch (error) {
      // Funded but not bid from: still cash-only, so the next bid can use it.
      if (freshBidder !== null) chain.releaseBidAccount(freshBidder);
      await alert(`action-failed-${accountId}`, `${describe(action)} on account ${accountId} failed: ${(error as Error).message}`);
    }
  }

  const health = await chain.readHealth();
  for (const problem of assessHealth(health, {
    minSecurityModuleCash: config.MIN_SECURITY_MODULE_USD,
    minKeeperCash: config.MIN_KEEPER_CASH_USD,
    minKeeperEthWei: config.MIN_KEEPER_ETH,
    capWarnBps: config.OI_CAP_WARN_BPS,
  })) {
    await alert(problem.key, problem.message);
  }

  return actions;
}

export function toCall(action: Exclude<Action, { kind: 'none' }>, bidderAccount: bigint): AuctionCall {
  switch (action.kind) {
    case 'start':
      return { functionName: 'startAuction', args: [action.accountId, 0n] };
    case 'convert':
      return { functionName: 'convertToInsolventAuction', args: [action.accountId] };
    case 'terminate':
      return { functionName: 'terminateAuction', args: [action.accountId] };
    case 'bid':
      return { functionName: 'bid', args: [action.accountId, bidderAccount, action.percent, action.priceLimit, 0n] };
  }
}

function describe(action: Exclude<Action, { kind: 'none' }>): string {
  if (action.kind === 'bid') {
    return `${action.insolvent ? 'insolvent ' : ''}bid ${fmt(action.percent * 100n)}% (limit ${fmt(action.priceLimit)})`;
  }
  return action.kind;
}
