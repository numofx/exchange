import assert from 'node:assert/strict';
import { test } from 'node:test';

import { toEventSelector, toFunctionSelector, type AbiFunction } from 'viem';

import { buildApp } from './app.js';
import {
  CustodianRejectedError,
  type CustodianPolicy,
  type CustodianRequest,
  buildCustodianCall,
  custodianAbi,
  custodianRequestSchema,
} from './custodian.js';
import { openedAccountId } from './executor.js';

const CUSTODIAN = '0xD8EBF2216Fd4ECA79272E76ad22131592EA0dfd6';
const ENGINE = '0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950';
const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272';
const EURC = '0xfD2AFbF4eF6E7a7f34A04D16Ff6da249Ca086cD9';
const CNGN_BOOK = '0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4';
const EURC_BOOK = '0x83C5741a24d57189379E1215F7A22d9f048E89d5';
const WALLET = '0x1111111111111111111111111111111111111111';
const NOW = 1_795_100_000;
const SIG = `0x${'ab'.repeat(65)}`;

const policy: CustodianPolicy = {
  bookAddresses: [CNGN_BOOK, EURC_BOOK],
  assetAddresses: [CASH, EURC],
  manager: ENGINE,
  nowSeconds: NOW,
};

function take(over: Record<string, unknown> = {}): CustodianRequest {
  return custodianRequestSchema.parse({
    call: 'take',
    take: {
      account_id: '70',
      book: CNGN_BOOK,
      market_id: '1',
      is_buy: true,
      amount: '1000000000000000000',
      limit_price: '700000000000000',
      min_fill: '1000000000000000000',
      max_fee: '2000000000000000000',
      deadline: String(NOW + 60),
      max_levels: 255,
      reduce_only: false,
      nonce: '7',
      ...over,
    },
    signature: SIG,
  });
}

function refused(fn: () => unknown, pattern: RegExp) {
  assert.throws(fn, (error: unknown) => error instanceof CustodianRejectedError && pattern.test(error.message));
}

// `forge inspect BookCustodian methodIdentifiers` and `cast sig` (2026-11-19): the deployed contract's selectors.
test('every function and revert in the ABI carries the selector the deployed custodian uses', () => {
  const functions: Record<string, string> = {
    take: '0x9f7d6a55',
    openAccount: '0xfa15b389',
    depositWithPermit: '0xfdeeb287',
    withdrawFor: '0x46051ef5',
    exitFor: '0x0b0f4a4d',
    setTradingKeyFor: '0x24d30515',
    accountOwner: '0x6ed20f8c',
  };
  const errors: Record<string, string> = {
    BC_AccountLeft: '0x70272daa',
    BC_BadSignature: '0xa5e895d4',
    BC_Expired: '0x91d25b57',
    BC_GrantPersisted: '0x07aac4a2',
    BC_NonceUsed: '0xada3b0a3',
    BC_NotAllowed: '0x7e2a196a',
    BC_NotHeld: '0x1fd54d31',
    BC_NotOwnerSending: '0x5a03d838',
    BC_NotReducing: '0x71703c46',
    BC_NotWallet: '0x65a9e046',
    BC_Paused: '0x88d9cdb4',
    BC_PermitFailed: '0xe3b44afb',
    BC_ZeroAddress: '0xaa06a06d',
  };
  for (const item of custodianAbi) {
    if (item.type === 'function') {
      assert.equal(toFunctionSelector(item as AbiFunction), functions[item.name], item.name);
    } else if (item.type === 'error' && item.name.startsWith('BC_')) {
      assert.equal(toFunctionSelector(`${item.name}()`), errors[item.name], item.name);
    }
  }
  assert.equal(
    toEventSelector('AccountOpened(uint256,address,address)'),
    '0x812c1bdd74b680128ded3a18c4d75aad0accb01055fa1c8479fcc97bd3ae9cd2',
  );
});

test('a take becomes the custodian Take struct, field for field', () => {
  const call = buildCustodianCall(take(), policy);
  assert.equal(call.functionName, 'take');
  assert.equal(call.accountId, 70n);
  const [t, sig, reports] = call.args as [Record<string, unknown>, string, string];
  assert.deepEqual(t, {
    accountId: 70n,
    book: CNGN_BOOK,
    marketId: 1n,
    isBuy: true,
    amount: 10n ** 18n,
    limitPrice: 700_000_000_000_000n,
    minFill: 10n ** 18n,
    maxFee: 2n * 10n ** 18n,
    deadline: BigInt(NOW + 60),
    maxLevels: 255,
    reduceOnly: false,
    nonce: 7n,
  });
  assert.equal(sig, SIG);
  assert.equal(reports, '0x');
});

test('a take on an unlisted book, of nothing, at no price, or not for the next minutes is refused', () => {
  refused(() => buildCustodianCall(take({ book: '0x0000000000000000000000000000000000000bad' }), policy), /not traded/);
  refused(() => buildCustodianCall(take({ amount: '0' }), policy), /amount/);
  refused(() => buildCustodianCall(take({ limit_price: '0' }), policy), /limit_price/);
  refused(() => buildCustodianCall(take({ account_id: '0' }), policy), /account_id/);
  refused(() => buildCustodianCall(take({ deadline: String(NOW - 1) }), policy), /passed/);
  refused(() => buildCustodianCall(take({ deadline: String(NOW + 601) }), policy), /600s/);
});

test('openAccount always uses the configured manager, never one the caller names', () => {
  const call = buildCustodianCall(custodianRequestSchema.parse({ call: 'open_account', wallet: WALLET }), policy);
  assert.deepEqual(call.args, [WALLET, ENGINE]);
  refused(
    () =>
      buildCustodianCall(
        custodianRequestSchema.parse({ call: 'open_account', wallet: '0x0000000000000000000000000000000000000000' }),
        policy,
      ),
    /zero/,
  );
});

test('deposits and withdrawals are relayed only for the configured assets', () => {
  const deposit = (asset: string) =>
    custodianRequestSchema.parse({
      call: 'deposit_with_permit',
      account_id: '70',
      asset,
      amount: '100000000',
      permit_deadline: String(NOW + 600),
      v: 27,
      r: `0x${'11'.repeat(32)}`,
      s: `0x${'22'.repeat(32)}`,
    });
  assert.equal(buildCustodianCall(deposit(EURC), policy).functionName, 'depositWithPermit');
  refused(() => buildCustodianCall(deposit('0x0000000000000000000000000000000000000bad'), policy), /not relayed/);

  const withdraw = custodianRequestSchema.parse({
    call: 'withdraw_for',
    account_id: '70',
    asset: CASH,
    amount: '5000000',
    nonce: '1',
    deadline: String(NOW + 60),
    signature: SIG,
  });
  assert.deepEqual(buildCustodianCall(withdraw, policy).args, [70n, CASH, 5_000_000n, 1n, BigInt(NOW + 60), SIG]);
});

test('the schema refuses malformed requests before any policy', () => {
  assert.throws(() => custodianRequestSchema.parse({ call: 'sweep', account_id: '1' }));
  assert.throws(() => custodianRequestSchema.parse({ call: 'exit_for', account_id: '-1', nonce: '1', deadline: '1', signature: SIG }));
  assert.throws(() => custodianRequestSchema.parse({ call: 'exit_for', account_id: '1', nonce: '1', deadline: '1', signature: '0x12' }));
});

test('an opened account is read from the custodian event in the receipt, and only from the custodian', () => {
  const topic = toEventSelector('AccountOpened(uint256,address,address)');
  const id = `0x${(77n).toString(16).padStart(64, '0')}`;
  assert.equal(openedAccountId([{ address: CUSTODIAN.toLowerCase(), topics: [topic, id] }], CUSTODIAN), 77n);
  assert.equal(openedAccountId([{ address: CASH, topics: [topic, id] }], CUSTODIAN), undefined);
  assert.equal(openedAccountId([], CUSTODIAN), undefined);
});

test('POST /custodian: 503 when off, 400 malformed, 422 named revert, 200 receipt', async () => {
  const off = buildApp({ config: {} as never } as never);
  assert.equal((await off.inject({ method: 'POST', url: '/custodian', payload: { call: 'open_account', wallet: WALLET } })).statusCode, 503);

  const calls: CustodianRequest[] = [];
  const app = buildApp({
    config: {} as never,
    custodian: {
      custodian: async (request: CustodianRequest) => {
        calls.push(request);
        if (request.call === 'exit_for') throw new CustodianRejectedError('exitFor would revert: BC_BadSignature', 'BC_BadSignature');
        return { accepted: true, tx_hash: `0x${'cd'.repeat(32)}`, receipt_status: 'success', account_id: '77' } as never;
      },
    },
  } as never);
  const bad = await app.inject({ method: 'POST', url: '/custodian', payload: { call: 'open_account' } });
  assert.equal(bad.statusCode, 400);
  const ok = await app.inject({ method: 'POST', url: '/custodian', payload: { call: 'open_account', wallet: WALLET } });
  assert.equal(ok.statusCode, 200);
  assert.equal(ok.json().account_id, '77');
  const rejected = await app.inject({
    method: 'POST',
    url: '/custodian',
    payload: { call: 'exit_for', account_id: '70', nonce: '1', deadline: String(NOW), signature: SIG },
  });
  assert.equal(rejected.statusCode, 422);
  assert.equal(rejected.json().revert, 'BC_BadSignature');
  assert.equal(calls.length, 2);
});
