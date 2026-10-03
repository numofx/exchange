import { parseUnits } from 'viem';
/**
 * The perp's resting orders from markets-service, in engine terms (USDC per cNGN, NGN amounts). The
 * book endpoint returns engine prices and amounts as decimals, the same shape spot's raw fields
 * have; the perp has no display inversion at this layer.
 */
export async function fetchPerpBook(marketsServiceUrl, perp, nowSec, fetchImpl = fetch) {
    const url = `${marketsServiceUrl}/v1/book?asset_address=${perp}&sub_id=0`;
    const response = await fetchImpl(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(8_000) });
    if (!response.ok)
        throw new Error(`markets-service book returned ${response.status}`);
    return parseBook((await response.json()), nowSec);
}
export function parseBook(body, nowSec) {
    const orders = [...(body.bids ?? []), ...(body.asks ?? [])];
    const resting = [];
    for (const order of orders) {
        // An order past its expiry no longer matches; the book can list it until it is swept.
        if (order.expiry !== undefined && order.expiry <= nowSec)
            continue;
        if (order.status !== undefined && order.status !== 'active')
            continue;
        const remaining = parseUnits(order.desired_amount, 18) - parseUnits(order.filled_amount, 18);
        if (remaining <= 0n)
            continue;
        resting.push({ side: order.side, price: parseUnits(order.limit_price, 18), remaining });
    }
    return resting;
}
