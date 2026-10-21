import type { Alerter } from './alert.js';
import type { AuctionCall, KeeperChain } from './chain.js';
import type { Config } from './config.js';
import type { CollateralAsset } from './collateral.js';
import { decide, type Action, type KeeperRules } from './decide.js';
import { assessHealth, fmt } from './health.js';

/**
 * One pass: find every account, read it, decide, act; then check the stack's health. An account
 * that cannot be read is an alert, not a skip — an unreadable margin is usually a stale feed, and a
 * stale feed means liquidations are frozen along with trading.
 */
/** What one pass saw, for /health and the pager: accounts under maintenance margin, and under water. */
export type PassSummary = { liquidatable: bigint[]; insolvent: bigint[]; openAuctions: bigint[] };

export async function runOnce(
  config: Config,
  chain: KeeperChain,
  alert: Alerter,
  summary: PassSummary = { liquidatable: [], insolvent: [], openAuctions: [] },
  now: () => number = Date.now,
): Promise<Action[]> {
  // Throws (a failed pass, so /health fails) when the funding account cannot fund a bid.
  await chain.assertFundingAccount();
  const accounts = await chain.discoverAccounts();
  const actions: Action[] = [];
  let keeperCash = await chain.keeperCash();
  const rules: KeeperRules = {
    minSolventDiscountBps: config.MIN_SOLVENT_DISCOUNT_BPS,
    minBidPercent: BigInt(Math.round(config.MIN_BID_PERCENT * 1e16)),
    maxBidUsd: config.MAX_BID_USD,
    collateral: collateralRules(config, await chain.keeperCollateral()),
  };

  for (const accountId of accounts) {
    let action: Action;
    try {
      const view = await chain.readAccount(accountId);
      if (view.mm < 0n) summary.liquidatable.push(accountId);
      if (view.mtm < 0n) summary.insolvent.push(accountId);
      if (view.auction.ongoing) {
        summary.openAuctions.push(accountId);
        const openFor = Math.floor(now() / 1000) - Number(view.auction.startTime);
        if (openFor > config.AUCTION_OPEN_WARN_MS / 1000) {
          await alert(
            `auction-open-${accountId}`,
            `auction on account ${accountId} open for ${Math.floor(openFor / 60)} min (${view.auction.insolvent ? 'insolvent' : 'solvent'}; ` +
              `mm ${fmt(view.mm)}, bm ${fmt(view.bm)}): the owner cannot trade until it ends`,
          );
        }
      }
      action = decide(view, keeperCash, rules);
      const unpriced = view.collateral.filter((held) => held.price === null).map((held) => held.asset);
      if (unpriced.length > 0) {
        // Not a skip to stay quiet about: the engine cannot value this account either, so nobody can
        // liquidate it until the feed reports again.
        await alert(
          `collateral-unpriced-${unpriced.join('-')}`,
          `account ${accountId} holds ${unpriced.join(', ')} but its price feed cannot be read (stale?): no start, no bid until it reports`,
        );
      }
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
      // A bid spends keeper cash and may pay it in any collateral; re-read both before sizing the next one.
      if (action.kind === 'bid' && sent) {
        keeperCash = await chain.keeperCash();
        rules.collateral = collateralRules(config, await chain.keeperCollateral());
      }
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
    maxInventory: Object.fromEntries(config.COLLATERAL.map((asset) => [asset.asset, asset.maxInventory])),
  })) {
    await alert(problem.key, problem.message);
  }

  return actions;
}

/** decide()'s per-asset rules: each configured collateral's haircut and limit, with what the keeper holds of it. */
export function collateralRules(config: Config, inventory: Partial<Record<CollateralAsset, bigint>>): KeeperRules['collateral'] {
  const rules: KeeperRules['collateral'] = {};
  for (const asset of config.COLLATERAL) {
    rules[asset.asset] = { haircutBps: asset.haircutBps, inventory: inventory[asset.asset] ?? 0n, maxInventory: asset.maxInventory };
  }
  return rules;
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
    return `${action.insolvent ? 'insolvent ' : ''}${action.finishing ? 'finishing ' : ''}bid ${fmt(action.percent * 100n)}% (limit ${fmt(action.priceLimit)})`;
  }
  return action.kind;
}
