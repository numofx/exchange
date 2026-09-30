/**
 * Stack-wide conditions worth waking someone for, independent of any one account. Pure: the loop
 * reads the numbers, this decides which of them are alarms.
 */

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
  /** Keeper-owned accounts below maintenance margin: the liquidator itself needs liquidating. */
  keeperAccountsUnderMargin: bigint[];
  /** PerpAsset totalPosition for the SRM against its cap: both count |long| + |short|. */
  totalPosition: bigint;
  totalPositionCap: bigint;
};

export type HealthRules = {
  minSecurityModuleCash: bigint;
  minKeeperCash: bigint;
  minKeeperEthWei: bigint;
  /** Alert when total position reaches this share of the cap, in bps. */
  capWarnBps: bigint;
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
