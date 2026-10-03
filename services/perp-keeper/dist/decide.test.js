import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { decide } from './decide.js';
import { assessHealth, fmt } from './health.js';
const E18 = 10n ** 18n;
const rules = { maxBidUsd: null, minSolventDiscountBps: 200n, minBidPercent: E18 / 100n, cngnHaircutBps: 1000n, cngnInventory: 0n, maxCngnInventory: null };
function account(overrides) {
    return {
        accountId: 7n,
        mm: 100n * E18,
        bm: 0n,
        mtm: 1000n * E18,
        auction: { ongoing: false, insolvent: false, reservedCash: 0n },
        canTerminate: false,
        bidPrice: null,
        maxProportion: null,
        collateral: null,
        ...overrides,
    };
}
/** 10M cNGN at 0.00072 USDC/cNGN: $7,200 of collateral, $720 of haircut at 10%. */
const tenMillionCngn = { cngn: 10000000n * E18, indexPrice: 72n * E18 / 100000n };
describe('decide', () => {
    it('leaves a healthy account alone', () => {
        assert.deepEqual(decide(account({}), 10000n * E18, rules), { kind: 'none', accountId: 7n });
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
        assert.deepEqual(decide(view, 10000n * E18, rules), { kind: 'terminate', accountId: 7n });
    });
    it('bids on a solvent auction at a real discount, capped by the max proportion', () => {
        const view = account({
            mm: -50n * E18,
            bm: -200n * E18,
            mtm: 1000n * E18,
            auction: { ongoing: true, insolvent: false, reservedCash: 0n },
            bidPrice: 950n * E18, // 5% under mark
            maxProportion: E18 / 2n,
        });
        const action = decide(view, 10000n * E18, rules);
        assert.equal(action.kind, 'bid');
        assert.equal(action.kind === 'bid' && action.percent, E18 / 2n);
        assert.equal(action.kind === 'bid' && action.priceLimit, 475n * E18 + 1n);
        // price 950 + buffer 200 per unit, for half the account
        assert.equal(action.kind === 'bid' && action.bidderCash, 575n * E18);
    });
    it('does not bid a discount thinner than the rule', () => {
        const view = account({
            mm: -50n * E18,
            mtm: 1000n * E18,
            auction: { ongoing: true, insolvent: false, reservedCash: 0n },
            bidPrice: 990n * E18, // 1%
            maxProportion: E18,
        });
        assert.equal(decide(view, 10000n * E18, rules).kind, 'none');
    });
    it('sizes a solvent bid to the cash DutchAuction will demand (price + |bm − reserved|)', () => {
        const view = account({
            mm: -50n * E18,
            bm: -500n * E18,
            mtm: 1000n * E18,
            auction: { ongoing: true, insolvent: false, reservedCash: 0n },
            bidPrice: 500n * E18,
            maxProportion: E18,
        });
        // 500 cash against 1,000 per unit (500 price + 500 buffer): half the account
        const action = decide(view, 500n * E18, rules);
        assert.equal(action.kind === 'bid' && action.percent, E18 / 2n);
    });
    it('says an auction is nearly sold out rather than blaming keeper cash', () => {
        // Still under maintenance margin, so this is not the finishing bid below.
        const view = account({
            mm: -10n * E18,
            bm: -1n * E18,
            mtm: 1000n * E18,
            auction: { ongoing: true, insolvent: false, reservedCash: 100n * E18 },
            bidPrice: 900n * E18,
            maxProportion: E18 / 2000n,
        });
        const action = decide(view, 20000n * E18, rules);
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
        assert.equal(decide(view, 10000n * E18, rules).kind, 'none');
        // Covering the deficit exactly is not enough either: the keeper wants its margin on top.
        assert.equal(decide({ ...view, bidPrice: -300n * E18 }, 10000n * E18, rules).kind, 'none');
        assert.equal(decide({ ...view, bidPrice: -306n * E18 }, 10000n * E18, rules).kind, 'bid');
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
    it('sizes a solvent bid down to the max bid, not away', () => {
        const view = account({
            mm: -50n * E18,
            bm: -500n * E18,
            mtm: 1000n * E18,
            auction: { ongoing: true, insolvent: false, reservedCash: 0n },
            bidPrice: 500n * E18,
            maxProportion: E18,
        });
        // 1,000 of margin per unit (500 price + 500 buffer); a $250 cap takes a quarter.
        const action = decide(view, 20000n * E18, { ...rules, maxBidUsd: 250n * E18 });
        assert.equal(action.kind === 'bid' && action.percent, E18 / 4n);
        assert.equal(action.kind === 'bid' && action.bidderCash, 250n * E18);
    });
    it('caps an insolvent bid by the margin of the share taken, though the payout means little cash moves', () => {
        const view = account({
            mm: -800n * E18,
            mtm: -300n * E18,
            auction: { ongoing: true, insolvent: true, reservedCash: 0n },
            bidPrice: -700n * E18,
        });
        // |mm| 800 per unit; $200 cap = a quarter, even though the keeper would put up only $25 for it.
        const action = decide(view, 20000n * E18, { ...rules, maxBidUsd: 200n * E18 });
        assert.equal(action.kind === 'bid' && action.percent, E18 / 4n);
    });
    it('waits on an insolvent cNGN portfolio until the payout also covers the haircut on the cNGN', () => {
        const view = account({
            mm: -800n * E18,
            mtm: -300n * E18,
            auction: { ongoing: true, insolvent: true, reservedCash: 0n },
            bidPrice: -306n * E18, // covers the $300 deficit + 2%, but not the $720 haircut on 10M cNGN
            collateral: tenMillionCngn,
        });
        assert.equal(decide(view, 10000n * E18, rules).kind, 'none');
        assert.equal(decide({ ...view, bidPrice: -1026n * E18 }, 10000n * E18, rules).kind, 'bid');
        // Without a haircut the cNGN is taken at the index, as a cash-only portfolio would be.
        assert.equal(decide(view, 10000n * E18, { ...rules, cngnHaircutBps: 0n }).kind, 'bid');
    });
    it('bids a solvent cNGN portfolio at the index discount, carrying the cNGN as inventory', () => {
        // Equity under the haircut: netting it would make this unbiddable until the auction ran out.
        const view = account({
            mm: -50n * E18,
            bm: -200n * E18,
            mtm: 69n * E18, // 10M cNGN against a settled loss: $69 of equity, $720 of haircut
            auction: { ongoing: true, insolvent: false, reservedCash: 0n },
            bidPrice: 65n * E18, // 5.8% under
            maxProportion: E18,
            collateral: tenMillionCngn,
        });
        assert.equal(decide(view, 100000n * E18, rules).kind, 'bid');
        assert.equal(decide({ ...view, bidPrice: 68n * E18 }, 100000n * E18, rules).kind, 'none'); // 1.4% is under the rule
    });
    it('sizes a cNGN bid down to the inventory room left, and stops at the limit', () => {
        const view = account({
            mm: -800n * E18,
            mtm: -300n * E18,
            auction: { ongoing: true, insolvent: true, reservedCash: 0n },
            bidPrice: -1100n * E18,
            collateral: tenMillionCngn,
        });
        const limited = { ...rules, cngnInventory: 8000000n * E18, maxCngnInventory: 10500000n * E18 };
        const action = decide(view, 10000n * E18, limited);
        assert.equal(action.kind === 'bid' && action.percent, E18 / 4n); // 2.5M of room against 10M
        const full = decide(view, 10000n * E18, { ...limited, cngnInventory: 10500000n * E18 });
        assert.equal(full.kind, 'none');
        assert.match(full.kind === 'none' ? full.note ?? '' : '', /inventory/);
    });
    it('finishes a solvent auction whose sliver is under the minimum once the account is above MM', () => {
        const view = account({
            mm: 5n * E18, // above maintenance margin after an earlier bid
            bm: -1n * E18 / 1000000n, // a millionth under buffer margin: the auction will not end on its own
            mtm: 43n * E18,
            auction: { ongoing: true, insolvent: false, reservedCash: 42n * E18 },
            bidPrice: 3n * E18 / 10n,
            maxProportion: E18 / 100000n, // 0.001%: all the auction has left; pays in 3 millionths
        });
        const action = decide(view, 10000n * E18, rules);
        assert.equal(action.kind, 'bid');
        assert.equal(action.kind === 'bid' && action.percent, E18 / 100000n);
        // Still under margin: a sliver is not finished, it is a keeper out of cash or an auction sold out.
        assert.equal(decide({ ...view, mm: -5n * E18 }, 10000n * E18, rules).kind, 'none');
        // A price decayed too far to restore buffer margin: bidding would loop for nothing; the sliver
        // waits for the solvent window to end, when maintenance margin is enough to terminate.
        assert.equal(decide({ ...view, bm: -1n * E18 / 1000n }, 10000n * E18, rules).kind, 'none');
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
    const healthy = {
        securityModuleCash: 10000n * E18,
        totalInsolventMM: 0n,
        cashExchangeRate: E18,
        temporaryWithdrawFeeEnabled: false,
        keeperCash: 5000n * E18,
        keeperEthWei: E18 / 10n,
        keeperPerpPosition: 0n,
        keeperCngn: 0n,
        keeperAccountsUnderMargin: [],
        totalPosition: 0n,
        totalPositionCap: 50000000n * E18,
    };
    const healthRules = { minSecurityModuleCash: 1000n * E18, minKeeperCash: 1000n * E18, minKeeperEthWei: E18 / 100n, capWarnBps: 8000n, maxCngnInventory: 10000000n * E18 };
    it('is quiet when nothing is wrong', () => {
        assert.deepEqual(assessHealth(healthy, healthRules), []);
    });
    it('reports cNGN the keeper was paid in, and says when it is over the limit', () => {
        const held = assessHealth({ ...healthy, keeperCngn: 3000000n * E18 }, healthRules);
        assert.deepEqual(held.map((a) => a.key), ['keeper-cngn-inventory']);
        const over = assessHealth({ ...healthy, keeperCngn: 12000000n * E18 }, healthRules);
        assert.deepEqual(over.map((a) => a.key), ['keeper-cngn-over-limit']);
    });
    it('raises a socialized loss, an SM that cannot cover live insolvency, and keeper inventory', () => {
        const keys = assessHealth({
            ...healthy,
            cashExchangeRate: E18 - 1n,
            temporaryWithdrawFeeEnabled: true,
            totalInsolventMM: 20000n * E18,
            keeperPerpPosition: 5000000n * E18,
            totalPosition: 45000000n * E18,
        }, healthRules).map((alert) => alert.key);
        assert.deepEqual(keys, ['socialized-loss', 'withdraw-fee', 'sm-short', 'keeper-inventory', 'oi-cap']);
    });
    it('formats 18dp amounts for humans', () => {
        assert.equal(fmt(1234500000000000000000n), '1234.5000');
        assert.equal(fmt(-E18 / 2n), '-0.5000');
    });
});
