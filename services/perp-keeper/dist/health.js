/**
 * Stack-wide conditions worth waking someone for, independent of any one account. Pure: the loop
 * reads the numbers, this decides which of them are alarms.
 */
const ONE = 10n ** 18n;
export function assessHealth(health, rules) {
    const alerts = [];
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
    if (health.keeperCngn > 0n) {
        const over = rules.maxCngnInventory !== null && health.keeperCngn > rules.maxCngnInventory;
        alerts.push({
            key: over ? 'keeper-cngn-over-limit' : 'keeper-cngn-inventory',
            message: over
                ? `keeper holds ${fmt(health.keeperCngn)} cNGN from liquidations, OVER its ${fmt(rules.maxCngnInventory)} limit: it will not take more; sell on spot or raise MAX_CNGN_INVENTORY`
                : `keeper holds ${fmt(health.keeperCngn)} cNGN from liquidations${rules.maxCngnInventory === null ? '' : ` (limit ${fmt(rules.maxCngnInventory)})`}: sell on spot or hold`,
        });
    }
    if (health.keeperAccountsUnderMargin.length > 0) {
        alerts.push({
            key: 'keeper-under-margin',
            message: `keeper account(s) ${health.keeperAccountsUnderMargin.join(', ')} below maintenance margin: top up or close before someone else liquidates them`,
        });
    }
    if (health.totalPositionCap > 0n && health.totalPosition * 10000n >= health.totalPositionCap * rules.capWarnBps) {
        alerts.push({
            key: 'oi-cap',
            message: `perp total position ${fmt(health.totalPosition)} is ${(health.totalPosition * 10000n) / health.totalPositionCap}bps of its cap`,
        });
    }
    return alerts;
}
/** 18dp to a short decimal for alert text. */
export function fmt(value) {
    const negative = value < 0n;
    const abs = negative ? -value : value;
    const whole = abs / ONE;
    const frac = ((abs % ONE) * 10000n) / ONE;
    return `${negative ? '-' : ''}${whole}.${frac.toString().padStart(4, '0')}`;
}
