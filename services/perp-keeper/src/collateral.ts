import type { Address } from 'viem';

/**
 * Base collateral the keeper can be paid in. An auction bid takes a share of ALL the account's assets,
 * so every escrow the manager credits as margin is something the keeper ends up holding: each has its
 * own price source, haircut and inventory limit. Order is the order notes and alerts list them in.
 */
export const COLLATERAL_ASSETS = ['cNGN', 'EURC'] as const;
export type CollateralAsset = (typeof COLLATERAL_ASSETS)[number];

/** Where an asset's USD price (18dp per whole unit) is read from. */
export type PriceSource =
  /** PerpAsset.getIndexPrice(): USDC per cNGN, the index the perp and the SRM value cNGN at. */
  | { kind: 'perpIndex'; address: Address }
  /** ISpotFeed.getSpot(): the manager's spot feed for the asset's market (ChainlinkSpotFeed for EURC). */
  | { kind: 'spotFeed'; address: Address };

export type CollateralConfig = {
  asset: CollateralAsset;
  /** WrappedERC20Asset escrow; balances in it are 18dp whatever the token's decimals. */
  escrow: Address;
  price: PriceSource;
  /** Haircut on this asset when the keeper is paid in it, bps of its price. */
  haircutBps: bigint;
  /** Most of it the keeper will hold across its accounts, 18dp; null for no limit. */
  maxInventory: bigint | null;
};

/** The env var that sets an asset's inventory limit, for alert text: MAX_CNGN_INVENTORY, MAX_EURC_INVENTORY. */
export function maxInventoryEnv(asset: CollateralAsset): string {
  return `MAX_${asset.toUpperCase()}_INVENTORY`;
}
