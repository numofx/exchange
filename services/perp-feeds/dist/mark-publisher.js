import { parseUnits } from 'viem';
import { fetchPerpBook } from './book.js';
import { encodeManagerData, encodeSpotDiffData, signFeedUpdate } from './feed-data.js';
import { computeMarkTargets, toSpotDiff } from './mark-targets.js';
/**
 * Whether a diff feed needs a new value: it moved far enough, or it is getting old. The BTC
 * template published on movement alone, which lets a quiet market's feed run past its heartbeat and
 * halt trading while nothing is wrong.
 */
export function needsUpdate(current, target, nowSec, thresholdBps, maxAgeSec) {
    if (current === null)
        return true;
    if (nowSec - current.updatedAt >= maxAgeSec)
        return true;
    const reference = current.result === 0n ? 1n : current.result;
    const moveBps = ((target > current.result ? target - current.result : current.result - target) * 10000n) / reference;
    return moveBps >= thresholdBps;
}
export class MarkPublisher {
    config;
    chain;
    alert;
    readBook;
    constructor(config, chain, alert, readBook = (nowSec) => fetchPerpBook(config.MARKETS_SERVICE_URL, config.markets.perp, nowSec)) {
        this.config = config;
        this.chain = chain;
        this.alert = alert;
        this.readBook = readBook;
    }
    async publish() {
        // Mark and impacts are diffs on the index; with no live index there is nothing to anchor them to.
        const index = await this.chain.readIndex(this.config.INDEX_FEED);
        if (index === null) {
            await this.alert('mark-no-index', 'mark not published: index feed is unset or stale');
            return;
        }
        const head = await this.chain.headTimestamp();
        let orders;
        try {
            orders = await this.readBook(Number(head));
        }
        catch (error) {
            // No book is not a reason to let the mark go stale: publish it at the index, which is what
            // an empty book would give anyway, and say so.
            console.warn(`[mark] book unavailable, anchoring to index: ${error.message}`);
            await this.alert('mark-no-book', `perp book unavailable, mark anchored to index: ${error.message}`);
            orders = [];
        }
        const targets = computeMarkTargets(index, orders, {
            maxBasisBps: BigInt(this.config.MARK_MAX_BASIS_BPS),
            impactNotional: parseUnits(String(this.config.IMPACT_NOTIONAL_USD), 18),
        });
        const timestamp = head - BigInt(this.config.TIMESTAMP_SAFETY_SEC);
        const deadline = head + BigInt(this.config.DEADLINE_SEC);
        const threshold = BigInt(this.config.MARK_UPDATE_THRESHOLD_BPS);
        const maxAge = BigInt(Math.floor(this.config.MARK_MAX_AGE_MS / 1000));
        const plan = [
            { feed: this.config.MARK_FEED, target: targets.mark, label: `mark(${targets.basis.mark})` },
            { feed: this.config.IMPACT_ASK_FEED, target: targets.impactAsk, label: `impactAsk(${targets.basis.impactAsk})` },
            { feed: this.config.IMPACT_BID_FEED, target: targets.impactBid, label: `impactBid(${targets.basis.impactBid})` },
        ];
        const updates = [];
        for (const item of plan) {
            const current = await this.chain.readDiffFeed(item.feed);
            if (!needsUpdate(current, item.target, head, threshold, maxAge))
                continue;
            updates.push(await signFeedUpdate({
                signer: this.chain.signer,
                kind: 'LyraSpotDiffFeed',
                feed: item.feed,
                chainId: this.chain.chainId,
                data: encodeSpotDiffData(toSpotDiff(item.target, index)),
                timestamp,
                deadline,
            }));
            console.log(`[mark] queue ${item.label}=${item.target} (index ${index})`);
        }
        if (updates.length === 0)
            return;
        if (this.config.DRY_RUN) {
            console.log(`[mark] dry-run: would publish ${updates.length} update(s)`);
            return;
        }
        const tx = await this.chain.submit(encodeManagerData(updates));
        console.log(`[mark] published ${updates.length} update(s) tx=${tx}`);
    }
}
