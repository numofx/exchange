/**
 * Stack-wide conditions worth waking someone for, independent of any one account. Pure: the loop
 * reads the numbers, this decides which of them are alarms.
 */

import { COLLATERAL_ASSETS, maxInventoryEnv, type CollateralAsset } from './collateral.js';

export type StackHealth = {
  /** Security module's cash balance, 18dp. */
  securityModuleCash: bigint;
  /** Sum of maintenance margin across live insolvent auctions (DutchAuction.totalInsolventMM). */
  totalInsolventMM: bigint;
  /** CashAsset.getCashToStableExchangeRate(): below 1e18 means a loss was socialized. */
  cashExchangeRate: bigint;
  temporaryWithdrawFeeEnabled: boolean;
  keeperCash: bigint;
  keeperEthWei: bigint;
  /** Net perp across the keeper's bid accounts, NGN 18dp: inventory inherited from liquidations. */
  keeperPerpPosition: bigint;
  /** Each configured collateral across the keeper's accounts, 18dp: what it was paid in by liquidations. */
  keeperCollateral: Partial<Record<CollateralAsset, bigint>>;
  /** Keeper-owned accounts below maintenance margin: the liquidator itself needs liquidating. */
  keeperAccountsUnderMargin: bigint[];
  /** PerpAsset totalPosition for the SRM against its cap: both count |long| + |short|. */
  totalPosition: bigint;
  totalPositionCap: bigint;
  /** FutureAsset totalPosition under MANAGER against its cap (0 and 0 when no FUTURE is configured). */
  futureTotalPosition: bigint;
  futureTotalPositionCap: bigint;
};

export type HealthRules = {
  minSecurityModuleCash: bigint;
  minKeeperCash: bigint;
  minKeeperEthWei: bigint;
  /** Alert when total position reaches this share of the cap, in bps. */
  capWarnBps: bigint;
  /** Most of each collateral the keeper means to hold, 18dp; null (or absent) for no limit. */
  maxInventory: Partial<Record<CollateralAsset, bigint | null>>;
};

export type HealthAlert = { key: string; message: string };

const ONE = 10n ** 18n;

export function assessHealth(health: StackHealth, rules: HealthRules): HealthAlert[] {
  const alerts: HealthAlert[] = [];

  if (health.cashExchangeRate < ONE) {
    alerts.push({
      key: 'socialized-loss',
      message: `cash exchange rate ${fmt(health.cashExchangeRate)} < 1: a loss was socialized across every depositor`,
    });
  }
  if (health.temporaryWithdrawFeeEnabled) {
    alerts.push({ key: 'withdraw-fee', message: 'CashAsset temporary withdraw fee is ON (insolvency path ran)' });
  }
  if (health.totalInsolventMM > 0n && health.securityModuleCash < health.totalInsolventMM) {
    alerts.push({
      key: 'sm-short',
      message: `security module holds ${fmt(health.securityModuleCash)} against ${fmt(health.totalInsolventMM)} of live insolvent MM: the next bid socializes`,
    });
  }
  if (health.securityModuleCash < rules.minSecurityModuleCash) {
    alerts.push({
      key: 'sm-low',
      message: `security module holds ${fmt(health.securityModuleCash)} (floor ${fmt(rules.minSecurityModuleCash)})`,
    });
  }
  if (health.keeperCash < rules.minKeeperCash) {
    alerts.push({
      key: 'keeper-cash-low',
      message: `keeper account holds ${fmt(health.keeperCash)} cash (floor ${fmt(rules.minKeeperCash)}): it cannot bid on large auctions`,
    });
  }
  if (health.keeperEthWei < rules.minKeeperEthWei) {
    alerts.push({ key: 'keeper-gas-low', message: `keeper EOA has ${fmt(health.keeperEthWei)} ETH for gas` });
  }
  if (health.keeperPerpPosition !== 0n) {
    alerts.push({
      key: 'keeper-inventory',
      message: `keeper holds ${fmt(health.keeperPerpPosition)} cNGN of perp inherited from liquidations: close or hedge it`,
    });
  }
  // One alert per asset, under its own key, so EURC over its limit does not hide behind a cNGN one
  // still in cooldown (keeper-cngn-inventory, keeper-cngn-over-limit, keeper-eurc-...).
  for (const asset of COLLATERAL_ASSETS) {
    const held = health.keeperCollateral[asset] ?? 0n;
    if (held <= 0n) continue;
    const limit = rules.maxInventory[asset] ?? null;
    const over = limit !== null && held > limit;
    const slug = asset.toLowerCase();
    alerts.push({
      key: over ? `keeper-${slug}-over-limit` : `keeper-${slug}-inventory`,
      message: over
        ? `keeper holds ${fmt(held)} ${asset} from liquidations, OVER its ${fmt(limit)} limit: it will not take more; sell on spot or raise ${maxInventoryEnv(asset)}`
        : `keeper holds ${fmt(held)} ${asset} from liquidations${limit === null ? '' : ` (limit ${fmt(limit)})`}: sell on spot or hold`,
    });
  }
  if (health.keeperAccountsUnderMargin.length > 0) {
    alerts.push({
      key: 'keeper-under-margin',
      message: `keeper account(s) ${health.keeperAccountsUnderMargin.join(', ')} below maintenance margin: top up or close before someone else liquidates them`,
    });
  }
  if (health.totalPositionCap > 0n && health.totalPosition * 10_000n >= health.totalPositionCap * rules.capWarnBps) {
    alerts.push({
      key: 'oi-cap',
      message: `perp total position ${fmt(health.totalPosition)} is ${(health.totalPosition * 10_000n) / health.totalPositionCap}bps of its cap`,
    });
  }
  if (health.futureTotalPositionCap > 0n && health.futureTotalPosition * 10_000n >= health.futureTotalPositionCap * rules.capWarnBps) {
    alerts.push({
      key: 'future-oi-cap',
      message: `future total position ${fmt(health.futureTotalPosition)} is ${(health.futureTotalPosition * 10_000n) / health.futureTotalPositionCap}bps of its cap`,
    });
  }
  return alerts;
}

/** 18dp to a short decimal for alert text. */
export function fmt(value: bigint): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const whole = abs / ONE;
  const frac = ((abs % ONE) * 10_000n) / ONE;
  return `${negative ? '-' : ''}${whole}.${frac.toString().padStart(4, '0')}`;
}
