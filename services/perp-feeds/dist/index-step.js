import { appendFile } from 'node:fs/promises';
import { encodeManagerData, encodeSpotData, signFeedUpdate } from './feed-data.js';
import { stepBps, toUsdPerNgn, windowTwap } from './index-aggregation.js';
/** The same liveness rule as the enable gate: a successful, non-dry-run pass within 3 polls (min 60s). */
export function checkKeeperHealth(health, nowSec) {
    if (health === null)
        return { ok: false, reason: 'keeper /health unreachable' };
    if (health.dryRun)
        return { ok: false, reason: 'keeper is in DRY_RUN: it would not liquidate' };
    const staleAfter = 3 * Math.max(Math.floor(health.pollIntervalMs / 1000), 20);
    const ageSec = nowSec - health.lastPassAt;
    if (!health.lastPassOk || ageSec > staleAfter) {
        return { ok: false, reason: `keeper last pass ok=${health.lastPassOk} ${ageSec}s ago (limit ${staleAfter}s)` };
    }
    return { ok: true, ageSec };
}
/** Every check that does not need the network: the sources, the operator's level, the step size. */
export function planIndexStep(args) {
    const { request, rules } = args;
    if (request.approvedBy.trim() === '')
        return { ok: false, reason: 'an approver is required (--approved-by)' };
    if (request.reason.trim() === '')
        return { ok: false, reason: 'a reason is required (--reason)' };
    if (!Number.isFinite(request.levelNgnPerUsd) || request.levelNgnPerUsd <= 0) {
        return { ok: false, reason: `--level must be a positive cNGN-per-USDC value (got ${request.levelNgnPerUsd})` };
    }
    if (args.onChain === null) {
        return { ok: false, reason: 'no reference index (chain stale and nothing published by this host): a first publish needs no override' };
    }
    const twap = windowTwap(args.samples, args.nowMs, {
        windowMs: rules.windowMs,
        minSamples: rules.minSamples,
        maxNewestAgeMs: rules.maxNewestAgeMs,
    });
    if (!twap.ok)
        return { ok: false, reason: `the sources do not support a publish: ${twap.reason}` };
    const next = toUsdPerNgn(twap.cngnPerUsdt);
    const confirmed = toUsdPerNgn(request.levelNgnPerUsd);
    const mismatch = Math.abs(stepBps(next, confirmed));
    if (mismatch > rules.matchBps) {
        return {
            ok: false,
            reason: `the sources' TWAP (${twap.cngnPerUsdt.toFixed(2)} cNGN/USDC) is ${mismatch}bps from the confirmed ${request.levelNgnPerUsd} (limit ${rules.matchBps}bps)`,
        };
    }
    const step = stepBps(next, args.onChain);
    if (Math.abs(step) <= rules.maxJumpBps) {
        return { ok: false, reason: `a ${step}bps move is inside the ${rules.maxJumpBps}bps guard: the publisher will publish it, no override needed` };
    }
    if (Math.abs(step) > rules.maxStepBps) {
        return { ok: false, reason: `a ${step}bps step is over INDEX_STEP_MAX_BPS (${rules.maxStepBps}bps)` };
    }
    return { ok: true, next, previous: args.onChain, twapCngnPerUsdt: twap.cngnPerUsdt, stepBps: step, samples: twap.samples };
}
/** Runs the procedure once. Throws with the reason on any refusal, so the command exits non-zero. */
export async function acceptIndexStep(deps) {
    const { config, chain, request } = deps;
    const now = deps.now ?? Date.now;
    const audit = deps.audit ?? ((record) => appendFile(config.INDEX_STEP_AUDIT_FILE, `${JSON.stringify(record)}\n`));
    const health = await deps.readKeeperHealth();
    const keeper = checkKeeperHealth(health, Math.floor(now() / 1000));
    if (!keeper.ok)
        throw new Error(`index step refused: ${keeper.reason}`);
    const plan = planIndexStep({
        samples: deps.samples,
        nowMs: now(),
        // A step usually comes after the jump guard has halted publishing long enough for the feed to go
        // stale (getSpot reverts), so fall back to what this publisher last published, as publish() does.
        onChain: (await chain.readIndex(config.INDEX_FEED)) ?? deps.lastPublished,
        request,
        rules: {
            windowMs: config.INDEX_TWAP_WINDOW_MS,
            minSamples: config.INDEX_MIN_WINDOW_SAMPLES,
            maxNewestAgeMs: config.INDEX_MAX_SAMPLE_AGE_MS,
            maxJumpBps: config.INDEX_MAX_JUMP_BPS,
            matchBps: config.INDEX_STEP_MATCH_BPS,
            maxStepBps: config.INDEX_STEP_MAX_BPS,
        },
    });
    if (!plan.ok)
        throw new Error(`index step refused: ${plan.reason}`);
    const record = {
        event: 'index-step',
        at: new Date(now()).toISOString(),
        approvedBy: request.approvedBy,
        reason: request.reason,
        confirmedNgnPerUsd: request.levelNgnPerUsd,
        twapCngnPerUsdt: plan.twapCngnPerUsdt,
        samples: plan.samples,
        previousUsdPerNgn: plan.previous.toString(),
        nextUsdPerNgn: plan.next.toString(),
        stepBps: plan.stepBps,
        keeper: { lastPassAt: health?.lastPassAt, account: health?.keeperAccount, ageSec: keeper.ageSec },
        signer: chain.signer.address,
        dryRun: config.DRY_RUN,
    };
    // Recorded before anything is sent: an approval that fails to land is still an approval made.
    await audit({ ...record, status: 'approved' });
    console.log(`[index-step] approved by ${request.approvedBy}: ${plan.stepBps}bps to ${plan.twapCngnPerUsdt.toFixed(2)} cNGN/USDC (${request.reason})`);
    if (config.DRY_RUN) {
        await audit({ ...record, status: 'dry-run' });
        return { tx: null, plan };
    }
    const head = await chain.headTimestamp();
    const update = await signFeedUpdate({
        signer: chain.signer,
        kind: 'LyraSpotFeed',
        feed: config.INDEX_FEED,
        chainId: chain.chainId,
        data: encodeSpotData(plan.next),
        timestamp: head - BigInt(config.TIMESTAMP_SAFETY_SEC),
        deadline: head + BigInt(config.DEADLINE_SEC),
    });
    const tx = await chain.submit(encodeManagerData([update]));
    await audit({ ...record, status: 'published', tx });
    await deps.alert('index-step', `index STEP published: ${plan.stepBps}bps to ${plan.twapCngnPerUsdt.toFixed(2)} cNGN/USDC, approved by ${request.approvedBy} (${request.reason}) tx=${tx}`);
    console.log(`[index-step] published ${plan.next} tx=${tx}`);
    return { tx, plan };
}
/** `--accept-index-step --level=<cNGN/USDC> --approved-by=<name> --reason=<text>`, or null without the flag. */
export function parseStepArgs(argv) {
    if (!argv.includes('--accept-index-step'))
        return null;
    const value = (name) => argv.find((arg) => arg.startsWith(`--${name}=`))?.slice(name.length + 3) ?? '';
    return { levelNgnPerUsd: Number(value('level')), approvedBy: value('approved-by'), reason: value('reason') };
}
export async function fetchKeeperHealth(url) {
    if (!url)
        return null;
    try {
        const response = await fetch(url, { signal: AbortSignal.timeout(5_000) });
        return response.ok ? (await response.json()) : null;
    }
    catch {
        return null;
    }
}
