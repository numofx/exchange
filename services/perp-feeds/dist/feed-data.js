/**
 * Signed updates for the perp stack's Lyra feeds, and the batch the OracleDataSubmitter relays.
 *
 * Mirrors BaseLyraFeed: EIP-712 domain (name, "1", chainId, feed address) over
 * FeedData(bytes data,uint256 deadline,uint64 timestamp), signed by the whitelisted feed signer, and
 * relayed by a separate funded key. The signer never needs ETH; the relayer never needs to be
 * trusted with prices.
 */
import { encodeAbiParameters } from 'viem';
const FEED_DATA_TYPES = {
    FeedData: [
        { name: 'data', type: 'bytes' },
        { name: 'deadline', type: 'uint256' },
        { name: 'timestamp', type: 'uint64' },
    ],
};
export const FULL_CONFIDENCE = 10n ** 18n;
/** Inner payload of a LyraSpotFeed update: (uint96 price, uint64 confidence). */
export function encodeSpotData(price, confidence = FULL_CONFIDENCE) {
    if (price <= 0n || price >= 2n ** 96n)
        throw new Error(`price ${price} does not fit uint96`);
    return encodeAbiParameters([{ type: 'uint96' }, { type: 'uint64' }], [price, confidence]);
}
/** Inner payload of a LyraSpotDiffFeed update: (int96 diff, uint64 confidence). */
export function encodeSpotDiffData(diff, confidence = FULL_CONFIDENCE) {
    return encodeAbiParameters([{ type: 'int96' }, { type: 'uint64' }], [diff, confidence]);
}
/**
 * Signs one update. `timestamp` must not be ahead of the chain (the feed reverts
 * BLF_InvalidTimestamp) and the feed ignores anything not newer than what it holds.
 */
export async function signFeedUpdate(args) {
    const signature = await args.signer.signTypedData({
        domain: { name: args.kind, version: '1', chainId: args.chainId, verifyingContract: args.feed },
        types: FEED_DATA_TYPES,
        primaryType: 'FeedData',
        message: { data: args.data, deadline: args.deadline, timestamp: args.timestamp },
    });
    const encoded = encodeAbiParameters([
        {
            type: 'tuple',
            components: [
                { name: 'data', type: 'bytes' },
                { name: 'deadline', type: 'uint256' },
                { name: 'timestamp', type: 'uint64' },
                { name: 'signers', type: 'address[]' },
                { name: 'signatures', type: 'bytes[]' },
            ],
        },
    ], [
        {
            data: args.data,
            deadline: args.deadline,
            timestamp: args.timestamp,
            signers: [args.signer.address],
            signatures: [signature],
        },
    ]);
    return { feed: args.feed, data: encoded };
}
/** ManagerData[] for OracleDataSubmitter.submitData, or for a TradeModule fill's managerData. */
export function encodeManagerData(updates) {
    if (updates.length === 0)
        throw new Error('no updates to encode');
    return encodeAbiParameters([
        {
            type: 'tuple[]',
            components: [
                { name: 'receiver', type: 'address' },
                { name: 'data', type: 'bytes' },
            ],
        },
    ], [updates.map((update) => ({ receiver: update.feed, data: update.data }))]);
}
