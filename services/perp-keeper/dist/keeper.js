import { decide } from './decide.js';
import { assessHealth, fmt } from './health.js';
export async function runOnce(config, chain, alert, summary = { liquidatable: [], insolvent: [] }) {
    // Throws (a failed pass, so /health fails) when the funding account cannot fund a bid.
    await chain.assertFundingAccount();
    const accounts = await chain.discoverAccounts();
    const actions = [];
    let keeperCash = await chain.keeperCash();
    const rules = {
        minSolventDiscountBps: config.MIN_SOLVENT_DISCOUNT_BPS,
        minBidPercent: BigInt(Math.round(config.MIN_BID_PERCENT * 1e16)),
        maxBidUsd: config.MAX_BID_USD,
        cngnHaircutBps: config.CNGN_HAIRCUT_BPS,
        cngnInventory: await chain.keeperCngn(),
        maxCngnInventory: config.MAX_CNGN_INVENTORY,
    };
    for (const accountId of accounts) {
        let action;
        try {
            const view = await chain.readAccount(accountId);
            if (view.mm < 0n)
                summary.liquidatable.push(accountId);
            if (view.mtm < 0n)
                summary.insolvent.push(accountId);
            action = decide(view, keeperCash, rules);
        }
        catch (error) {
            await alert('margin-unreadable', `cannot read margin for account ${accountId} (stale feed?): ${error.message}`);
            continue;
        }
        actions.push(action);
        if (action.kind === 'none') {
            if (action.note)
                console.log(`[keeper] #${accountId}: ${action.note}`);
            continue;
        }
        let freshBidder = null;
        try {
            // A live bid goes from a fresh account funded for exactly this bid (plus 2% for the block it
            // lands in). A dry run simulates from the funding account, which is cash-only and so a valid
            // bidder, without creating anything.
            const bidder = action.kind === 'bid' && !config.DRY_RUN
                ? await chain.createBidAccount((action.bidderCash * 102n) / 100n + 1n)
                : config.KEEPER_ACCOUNT;
            if (action.kind === 'bid' && !config.DRY_RUN)
                freshBidder = bidder;
            const call = toCall(action, bidder);
            const { sent } = await chain.execute(call, config.DRY_RUN);
            console.log(`[keeper] #${accountId}: ${describe(action)} ${sent ? `tx=${sent}` : '(dry-run, simulated ok)'}`);
            await alert(`action-${action.kind}-${accountId}`, `${config.DRY_RUN ? 'DRY-RUN ' : ''}${describe(action)} on account ${accountId}`);
            // A bid spends keeper cash and may pay it in cNGN; re-read both before sizing the next one.
            if (action.kind === 'bid' && sent) {
                keeperCash = await chain.keeperCash();
                rules.cngnInventory = await chain.keeperCngn();
            }
        }
        catch (error) {
            // Funded but not bid from: still cash-only, so the next bid can use it.
            if (freshBidder !== null)
                chain.releaseBidAccount(freshBidder);
            await alert(`action-failed-${accountId}`, `${describe(action)} on account ${accountId} failed: ${error.message}`);
        }
    }
    const health = await chain.readHealth();
    for (const problem of assessHealth(health, {
        minSecurityModuleCash: config.MIN_SECURITY_MODULE_USD,
        minKeeperCash: config.MIN_KEEPER_CASH_USD,
        minKeeperEthWei: config.MIN_KEEPER_ETH,
        capWarnBps: config.OI_CAP_WARN_BPS,
        maxCngnInventory: config.MAX_CNGN_INVENTORY,
    })) {
        await alert(problem.key, problem.message);
    }
    return actions;
}
export function toCall(action, bidderAccount) {
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
function describe(action) {
    if (action.kind === 'bid') {
        return `${action.insolvent ? 'insolvent ' : ''}bid ${fmt(action.percent * 100n)}% (limit ${fmt(action.priceLimit)})`;
    }
    return action.kind;
}
