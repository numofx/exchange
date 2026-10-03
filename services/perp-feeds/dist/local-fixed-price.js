import { createPublicClient, http } from 'viem';
import { encodeManagerData, encodeSpotData, encodeSpotDiffData, signFeedUpdate } from './feed-data.js';
import { toUsdPerNgn } from './index-aggregation.js';
/**
 * `--local-fixed-price=<cNGN per USDC>`: publishes a constant index, with mark and impacts at zero
 * diff, and nothing else. It exists so the local venue (scripts/local-venue) has live feeds without
 * rate-picker sources or a book, and it skips every guard the real publishers apply -- which is why
 * it refuses to run anywhere but a local anvil.
 */
export const LOCAL_CHAIN_ID = 31337;
/**
 * Refuses unless both the configured chain and the chain actually behind the RPC are anvil's.
 * The RPC is asked, not trusted from config: a local CHAIN_ID over a mainnet RPC_URL is exactly the
 * mistake this has to catch.
 */
export function assertLocalChain(configured, reported) {
    for (const [what, id] of [
        ['CHAIN_ID', configured],
        ['the RPC', reported],
    ]) {
        if (id === 8453 || id === 84532) {
            throw new Error(`--local-fixed-price refuses ${what} = ${id} (Base): it publishes an unguarded constant price`);
        }
        if (id !== LOCAL_CHAIN_ID) {
            throw new Error(`--local-fixed-price runs only on a local anvil (${LOCAL_CHAIN_ID}); ${what} is ${id}`);
        }
    }
}
export function parseFixedPrice(argv) {
    const flag = argv.find((arg) => arg.startsWith('--local-fixed-price'));
    if (flag === undefined)
        return null;
    const value = Number(flag.split('=')[1]);
    if (!Number.isFinite(value) || value <= 0) {
        throw new Error(`--local-fixed-price needs a positive cNGN-per-USDC value, e.g. --local-fixed-price=1374 (got ${flag})`);
    }
    return value;
}
export async function assertRpcIsLocal(config) {
    const reported = await createPublicClient({ transport: http(config.RPC_URL) }).getChainId();
    assertLocalChain(config.CHAIN_ID, reported);
}
export async function publishFixedPrice(config, chain, ngnPerUsd) {
    const head = await chain.headTimestamp();
    const at = {
        signer: chain.signer,
        chainId: chain.chainId,
        timestamp: head - BigInt(config.TIMESTAMP_SAFETY_SEC),
        deadline: head + BigInt(config.DEADLINE_SEC),
    };
    const index = toUsdPerNgn(ngnPerUsd);
    const updates = await Promise.all([
        signFeedUpdate({ ...at, kind: 'LyraSpotFeed', feed: config.INDEX_FEED, data: encodeSpotData(index) }),
        ...[config.MARK_FEED, config.IMPACT_ASK_FEED, config.IMPACT_BID_FEED].map((feed) => signFeedUpdate({ ...at, kind: 'LyraSpotDiffFeed', feed, data: encodeSpotDiffData(0n) })),
    ]);
    const tx = await chain.submit(encodeManagerData(updates));
    console.log(`[local-fixed-price] published index ${index} (${ngnPerUsd} cNGN/USDC), zero diffs, tx=${tx}`);
}
/**
 * `--local-sources=<cNGN per USDC>`: three providers that all answer that price, in place of the real
 * ones, so the local venue can drive the REAL index publisher (sampling, TWAP, jump guard, the
 * index-step procedure) without the network. Same refusal as --local-fixed-price: 31337 only.
 */
export function parseLocalSources(argv) {
    const flag = argv.find((arg) => arg.startsWith('--local-sources'));
    if (flag === undefined)
        return null;
    const value = Number(flag.split('=')[1]);
    if (!Number.isFinite(value) || value <= 0) {
        throw new Error(`--local-sources needs a positive cNGN-per-USDC value, e.g. --local-sources=2290 (got ${flag})`);
    }
    return value;
}
export function localSources(cngnPerUsdc) {
    return ['local-a', 'local-b', 'local-c'].map((name) => ({
        name,
        read: async () => ({ source: name, cngnPerUsdt: cngnPerUsdc }),
    }));
}
/** The peg market for --local-sources: cNGN at parity, no network. */
export const localPegTicker = async () => ({ buy: 1, sell: 1 });
