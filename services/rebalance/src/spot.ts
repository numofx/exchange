/**
 * The spot market's contracts, as the venue serves them and the chain confirms them.
 *
 * These used to be constants here, and the 2026-10-04 unified cutover moved spot onto the perp
 * stack without them: the rebalance kept reading the retired escrows and defaulting to account 15,
 * so a `deposit --execute` would have credited cNGN to an account the market maker no longer
 * trades. /v1/markets is served from the same Terraform variables the venue and the makers run
 * on, so reading it here means the next cutover moves this too.
 *
 * The API names the contracts; the chain has the final say. A deposit target taken on trust from
 * an HTTP response is a transfer to whoever controls that response, so every address is checked
 * against the manager that actually holds the configured subaccount before anything is used.
 */
import type { Hex, PublicClient } from 'viem';
import { MANAGER_ABI, SUBACCOUNTS, SUBACCOUNTS_ABI } from './venue.js';

export type SpotVenue = {
  /** WrappedERC20Asset for cNGN: the spot market's asset_address, and the deposit target. */
  cngnEscrow: Hex;
  /** What the spot market's quote leg settles in: the manager's CashAsset. */
  quoteAsset: Hex;
  /** The margin manager the market and the market maker's subaccount both live under. */
  manager: Hex;
};

type Market = {
  contract_type?: string;
  base_asset_symbol?: string;
  asset_address?: string;
  quote_asset_address?: string;
  margin_manager_address?: string;
};

export type FetchMarkets = (apiUrl: string) => Promise<Market[]>;

export const fetchMarkets: FetchMarkets = async (apiUrl) => {
  const response = await fetch(new URL('/v1/markets', apiUrl), { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) throw new Error(`GET /v1/markets returned ${response.status}`);
  return (await response.json()) as Market[];
};

const same = (a: string, b: string) => a.toLowerCase() === b.toLowerCase();

export async function resolveSpotVenue(
  apiUrl: string,
  subaccount: bigint,
  publicClient: Pick<PublicClient, 'readContract'>,
  fetch: FetchMarkets = fetchMarkets,
): Promise<SpotVenue> {
  const spot = (await fetch(apiUrl)).filter((m) => m.contract_type === 'spot' && m.base_asset_symbol === 'cNGN');
  if (spot.length !== 1) throw new Error(`expected one cNGN spot market on ${apiUrl}, found ${spot.length}`);
  const { asset_address: cngnEscrow, quote_asset_address: quoteAsset, margin_manager_address: manager } = spot[0]!;
  if (!cngnEscrow || !quoteAsset || !manager) {
    throw new Error('the cNGN spot market does not report asset_address, quote_asset_address and margin_manager_address');
  }

  // The check that catches a retired account: 15 is still under the old spot manager.
  const held = (await publicClient.readContract({
    address: SUBACCOUNTS, abi: SUBACCOUNTS_ABI, functionName: 'manager', args: [subaccount],
  })) as Hex;
  if (!same(held, manager)) {
    throw new Error(
      `subaccount ${subaccount} is under manager ${held}, not the spot market's ${manager} -- ` +
        'MM_SUBACCOUNT_ID points at an account the market maker does not trade from',
    );
  }

  const [detail, cash] = await Promise.all([
    publicClient.readContract({ address: manager as Hex, abi: MANAGER_ABI, functionName: 'assetDetails', args: [cngnEscrow as Hex] }),
    publicClient.readContract({ address: manager as Hex, abi: MANAGER_ABI, functionName: 'cashAsset' }),
  ]);
  if (!(detail as { isWhitelisted: boolean }).isWhitelisted) {
    throw new Error(`${cngnEscrow} is not whitelisted on manager ${manager}; refusing to treat it as the cNGN escrow`);
  }
  if (!same(cash as string, quoteAsset)) {
    throw new Error(`the spot market quotes in ${quoteAsset}, but manager ${manager}'s cash is ${String(cash)}`);
  }
  return { cngnEscrow: cngnEscrow as Hex, quoteAsset: quoteAsset as Hex, manager: manager as Hex };
}
