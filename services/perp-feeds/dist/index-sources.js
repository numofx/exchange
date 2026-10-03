import { BybitP2PProvider, QuidaxProvider, TextileProvider } from 'cngn-rate-picker';
/** A fiat NGN per USDT quote, as cNGN per USDT at redemption parity. */
export function fiatNgnAtParity(provider) {
    return {
        name: provider.name,
        async read(ctx) {
            const quote = await provider.getPriceInNgn({ signal: ctx.signal, fetch: ctx.fetch });
            return { source: provider.name, cngnPerUsdt: quote.price };
        },
    };
}
export function buildIndexSources(config) {
    return [
        fiatNgnAtParity(new QuidaxProvider({ baseUrl: config.QUIDAX_API_URL, market: 'usdtngn' })),
        fiatNgnAtParity(new TextileProvider()),
        fiatNgnAtParity(new BybitP2PProvider()),
    ];
}
