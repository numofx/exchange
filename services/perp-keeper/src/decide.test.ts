import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { decide, type AccountView } from './decide.js';
import { assessHealth, fmt, type StackHealth } from './health.js';

const E18 = 10n ** 18n;
const rules = { minSolventDiscountBps: 200n, minBidPercent: E18 / 100n };

function account(overrides: Partial<AccountView>): AccountView {
  return {
    accountId: 7n,
    mm: 100n * E18,
    bm: 0n,
    mtm: 1_000n * E18,
    auction: { ongoing: false, insolvent: false, reservedCash: 0n },
    canTerminate: false,
    bidPrice: null,
    maxProportion: null,
    ...overrides,
  };
}

describe('decide', () => {
  it('leaves a healthy account alone', () => {
    assert.deepEqual(decide(account({}), 10_000n * E18, rules), { kind: 'none', accountId: 7n });
  });

  it('starts an auction below maintenance margin', () => {
    assert.deepEqual(decide(account({ mm: -1n }), 0n, rules), { kind: 'start', accountId: 7n });
  });

  it('terminates an auction whose account recovered, before bidding on it', () => {
    const view = account({
      mm: 10n * E18,
      auction: { ongoing: true, insolvent: false, reservedCash: 0n },
      canTerminate: true,
      bidPrice: 900n * E18,
      maxProportion: E18,
    });
    assert.deepEqual(decide(view, 10_000n * E18, rules), { kind: 'terminate', accountId: 7n });
  });

  it('bids on a solvent auction at a real discount, capped by the max proportion', () => {
    const view = account({
      mm: -50n * E18,
      bm: -200n * E18,
      mtm: 1_000n * E18,
      auction: { ongoing: true, insolvent: false, reservedCash: 0n },
      bidPrice: 950n * E18, // 5% under mark
      maxProportion: E18 / 2n,
    });
    const action = decide(view, 10_000n * E18, rules);
    assert.equal(action.kind, 'bid');
    assert.equal(action.kind === 'bid' && action.percent, E18 / 2n);
    assert.equal(action.kind === 'bid' && action.priceLimit, 475n * E18 + 1n);
    // price 950 + buffer 200 per unit, for half the account
    assert.equal(action.kind === 'bid' && action.bidderCash, 575n * E18);
  });

  it('does not bid a discount thinner than the rule', () => {
    const view = account({
      mm: -50n * E18,
      mtm: 1_000n * E18,
      auction: { ongoing: true, insolvent: false, reservedCash: 0n },
      bidPrice: 990n * E18, // 1%
      maxProportion: E18,
    });
    assert.equal(decide(view, 10_000n * E18, rules).kind, 'none');
  });

  it('sizes a solvent bid to the cash DutchAuction will demand (price + |bm − reserved|)', () => {
    const view = account({
      mm: -50n * E18,
      bm: -500n * E18,
      mtm: 1_000n * E18,
      auction: { ongoing: true, insolvent: false, reservedCash: 0n },
      bidPrice: 500n * E18,
      maxProportion: E18,
    });
    // 500 cash against 1,000 per unit (500 price + 500 buffer): half the account
    const action = decide(view, 500n * E18, rules);
    assert.equal(action.kind === 'bid' && action.percent, E18 / 2n);
  });

  it('says an auction is nearly sold out rather than blaming keeper cash', () => {
    const view = account({
      mm: 10n * E18,
      bm: -1n * E18,
      mtm: 1_000n * E18,
      auction: { ongoing: true, insolvent: false, reservedCash: 100n * E18 },
      bidPrice: 900n * E18,
      maxProportion: E18 / 2_000n,
    });
    const action = decide(view, 20_000n * E18, rules);
    assert.equal(action.kind, 'none');
    assert.match(action.kind === 'none' ? action.note ?? '' : '', /left to sell/);
  });

  it('converts a solvent auction that ran out still under water', () => {
    const view = account({
      mm: -50n * E18,
      auction: { ongoing: true, insolvent: false, reservedCash: 0n },
      bidPrice: 0n,
    });
    assert.deepEqual(decide(view, 0n, rules), { kind: 'convert', accountId: 7n });
  });

  it('waits while the insolvent payout does not yet cover the deficit', () => {
    // No payout yet, or one that only covers the deficit: the keeper would carry the risk for nothing.
    const view = account({
      mm: -800n * E18,
      mtm: -300n * E18,
      auction: { ongoing: true, insolvent: true, reservedCash: 0n },
      bidPrice: 0n,
    });
    assert.equal(decide(view, 10_000n * E18, rules).kind, 'none');
    // Covering the deficit exactly is not enough either: the keeper wants its margin on top.
    assert.equal(decide({ ...view, bidPrice: -300n * E18 }, 10_000n * E18, rules).kind, 'none');
    assert.equal(decide({ ...view, bidPrice: -306n * E18 }, 10_000n * E18, rules).kind, 'bid');
  });

  it('takes an insolvent account in full when it can back it', () => {
    const view = account({
      mm: -800n * E18,
      mtm: -300n * E18,
      auction: { ongoing: true, insolvent: true, reservedCash: 0n },
      bidPrice: -500n * E18,
    });
    // needs |mm| − paid = 300 per unit
    const action = decide(view, 300n * E18, rules);
    assert.deepEqual(action, { kind: 'bid', accountId: 7n, percent: E18, priceLimit: 0n, insolvent: true, bidderCash: 300n * E18 });
  });

  it('takes a share of an insolvent account it cannot back in full', () => {
    const view = account({
      mm: -800n * E18,
      mtm: -300n * E18,
      auction: { ongoing: true, insolvent: true, reservedCash: 0n },
      bidPrice: -500n * E18,
    });
    const action = decide(view, 150n * E18, rules);
    assert.equal(action.kind === 'bid' && action.percent, E18 / 2n);
  });

  it('declines a bid too small to be worth its gas', () => {
    const view = account({
      mm: -800n * E18,
      auction: { ongoing: true, insolvent: true, reservedCash: 0n },
      bidPrice: -500n * E18,
    });
    assert.equal(decide(view, 1n * E18, rules).kind, 'none');
  });
});

describe('assessHealth', () => {
  const healthy: StackHealth = {
    securityModuleCash: 10_000n * E18,
    totalInsolventMM: 0n,
    cashExchangeRate: E18,
    temporaryWithdrawFeeEnabled: false,
    keeperCash: 5_000n * E18,
    keeperEthWei: E18 / 10n,
    keeperPerpPosition: 0n,
    keeperAccountsUnderMargin: [],
    totalPosition: 0n,
    totalPositionCap: 50_000_000n * E18,
  };
  const healthRules = { minSecurityModuleCash: 1_000n * E18, minKeeperCash: 1_000n * E18, minKeeperEthWei: E18 / 100n, capWarnBps: 8_000n };

  it('is quiet when nothing is wrong', () => {
    assert.deepEqual(assessHealth(healthy, healthRules), []);
  });

  it('raises a socialized loss, an SM that cannot cover live insolvency, and keeper inventory', () => {
    const keys = assessHealth(
      {
        ...healthy,
        cashExchangeRate: E18 - 1n,
        temporaryWithdrawFeeEnabled: true,
        totalInsolventMM: 20_000n * E18,
        keeperPerpPosition: 5_000_000n * E18,
        totalPosition: 45_000_000n * E18,
      },
      healthRules,
    ).map((alert) => alert.key);
    assert.deepEqual(keys, ['socialized-loss', 'withdraw-fee', 'sm-short', 'keeper-inventory', 'oi-cap']);
  });

  it('formats 18dp amounts for humans', () => {
    assert.equal(fmt(1_234_500_000_000_000_000_000n), '1234.5000');
    assert.equal(fmt(-E18 / 2n), '-0.5000');
  });
});
