import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { lateAwaiting, optionExpiry, planOptionSettlement, type OptionHolding } from './options.js';

const EXPIRY = 1796047200n;
const OPTION = '0x00000000000000000000000000000000000000A1';
const OTHER = '0x00000000000000000000000000000000000000A2';
/** OptionEncoding.toSubId */
const subId = (expiry: bigint, strike: bigint, isCall: boolean) => expiry | ((strike / 10n ** 10n) << 32n) | ((isCall ? 1n : 0n) << 95n);
const PUT = subId(EXPIRY, 721_650_000_000_000n, false);
const CALL = subId(EXPIRY, 721_650_000_000_000n, true);

const holding = (over: Partial<OptionHolding>): OptionHolding => ({
  account: 44n,
  option: OPTION,
  subId: PUT,
  balance: 10n ** 24n,
  priceSettled: true,
  ...over,
});

describe('expired options', () => {
  it('reads the expiry out of a sub id, whatever the strike and side', () => {
    assert.equal(optionExpiry(PUT), EXPIRY);
    assert.equal(optionExpiry(CALL), EXPIRY);
  });

  it('settles a settled expiry once per (account, option), long or short', () => {
    const plan = planOptionSettlement(
      [holding({}), holding({ subId: CALL }), holding({ account: 45n, balance: -(10n ** 24n) }), holding({ account: 45n, option: OTHER })],
      EXPIRY + 60n,
    );
    assert.deepEqual(plan.settle, [
      { account: 44n, option: OPTION },
      { account: 45n, option: OPTION },
      { account: 45n, option: OTHER },
    ]);
    assert.deepEqual(plan.awaiting, []);
  });

  it('leaves unexpired and empty holdings alone, and reports an unfixed price as awaiting', () => {
    const plan = planOptionSettlement(
      [holding({ subId: subId(EXPIRY + 86_400n, 1n * 10n ** 14n, false) }), holding({ balance: 0n }), holding({ account: 46n, priceSettled: false })],
      EXPIRY + 60n,
    );
    assert.deepEqual(plan.settle, []);
    assert.deepEqual(plan.awaiting, [{ account: 46n, option: OPTION, expiry: EXPIRY }]);
  });

  it('settles nothing at the expiry second itself unless the price is fixed', () => {
    assert.deepEqual(planOptionSettlement([holding({ priceSettled: false })], EXPIRY).awaiting.length, 1);
    assert.deepEqual(planOptionSettlement([holding({})], EXPIRY - 1n), { settle: [], awaiting: [] });
  });

  it('warns only once an unfixed price is older than the warning age', () => {
    const plan = planOptionSettlement([holding({ priceSettled: false })], EXPIRY + 60n);
    assert.equal(lateAwaiting(plan, EXPIRY + 60n, 7_200n).length, 0);
    assert.equal(lateAwaiting(plan, EXPIRY + 7_201n, 7_200n).length, 1);
  });
});
