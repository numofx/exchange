import { createServer } from 'node:http';
import { createAlerter } from './alert.js';
import { createKeeperChain } from './chain.js';
import { loadConfig } from './config.js';
import { runOnce } from './keeper.js';
/**
 * USDCcNGN-PERP liquidation keeper: watches every account under the perp SRM, starts auctions on
 * those below maintenance margin, bids on them (solvent at a discount, insolvent for the security
 * module's payout), converts and terminates auctions as they run out or recover, and alerts on the
 * stack's solvency. Dry run (simulate, never send) until DRY_RUN=false.
 */
async function main() {
    const config = loadConfig();
    const chain = createKeeperChain(config);
    const alert = createAlerter(config.ALERT_WEBHOOK_URL || undefined, undefined, undefined, undefined, config.ALERT_PREFIX);
    // The RPC must be the chain CHAIN_ID names: a keeper configured for a fork must not reach Base,
    // and one configured for Base must not quietly run against a fork.
    const rpcChainId = await chain.rpcChainId();
    if (rpcChainId !== config.CHAIN_ID) {
        throw new Error(`RPC_URL is chain ${rpcChainId} but CHAIN_ID is ${config.CHAIN_ID}: refusing to start`);
    }
    console.log(`[keeper] eoa=${chain.keeper.address} account=${config.KEEPER_ACCOUNT} dryRun=${config.DRY_RUN}`);
    // What /health reports. A pass that throws is recorded as failed, so a keeper looping on an
    // error reads as unhealthy rather than merely alive.
    const health = {
        lastPassAt: 0,
        lastPassOk: false,
        passes: 0,
        // From the last pass that read them: the pager (check_perp_pager.py) pages on any insolvent one.
        liquidatableAccounts: [],
        insolventAccounts: [],
    };
    const tick = async () => {
        try {
            const summary = { liquidatable: [], insolvent: [] };
            await runOnce(config, chain, alert, summary);
            health.liquidatableAccounts = summary.liquidatable.map(String);
            health.insolventAccounts = summary.insolvent.map(String);
            health.lastPassOk = true;
        }
        catch (error) {
            health.lastPassOk = false;
            console.error(`[keeper] ${error.stack ?? error}`);
            await alert('keeper-error', `keeper pass failed: ${error.message}`);
        }
        finally {
            health.lastPassAt = Math.floor(Date.now() / 1000);
            health.passes += 1;
        }
    };
    if (config.HEALTH_PORT !== undefined) {
        createServer((request, response) => {
            if (request.url !== '/health') {
                response.writeHead(404).end();
                return;
            }
            response.writeHead(200, { 'content-type': 'application/json' });
            response.end(JSON.stringify({
                ...health,
                dryRun: config.DRY_RUN,
                keeperAccount: config.KEEPER_ACCOUNT.toString(),
                keeperAddress: chain.keeper.address,
                maxBidUsd: config.MAX_BID_USD?.toString() ?? null,
                pollIntervalMs: config.POLL_INTERVAL_MS,
                // The cNGN escrow this keeper bids for (null: cash-only); the batch-5 gate reads it.
                cngnEscrow: config.CNGN_ESCROW ?? null,
                cngnHaircutBps: config.CNGN_HAIRCUT_BPS.toString(),
                maxCngnInventory: config.MAX_CNGN_INVENTORY?.toString() ?? null,
            }));
        }).listen(config.HEALTH_PORT, config.HEALTH_HOST);
        console.log(`[keeper] health on http://${config.HEALTH_HOST}:${config.HEALTH_PORT}/health`);
    }
    if (process.argv.includes('--settle-frozen')) {
        const { settled, underLiquidation } = await chain.settleFrozenPositions(config.DRY_RUN);
        const verb = config.DRY_RUN ? 'would settle' : 'settled';
        console.log(`[keeper] ${verb} ${settled.length} frozen position(s): ${settled.join(', ') || 'none'}`);
        if (underLiquidation.length > 0) {
            console.log(`[keeper] under liquidation, not settled: ${underLiquidation.join(', ')}; let the keeper finish their auctions, then run again`);
            process.exitCode = 2;
        }
        return;
    }
    await tick();
    if (process.argv.includes('--once'))
        return;
    let running = false;
    setInterval(async () => {
        if (running)
            return;
        running = true;
        try {
            await tick();
        }
        finally {
            running = false;
        }
    }, config.POLL_INTERVAL_MS);
}
main().catch((error) => {
    console.error(error);
    process.exit(1);
});
