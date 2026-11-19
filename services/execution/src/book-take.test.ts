import assert from 'node:assert/strict';
import { test } from 'node:test';

import { encodeAbiParameters, toFunctionSelector } from 'viem';

import {
  BookTakeRejectedError,
  type BookTakeRequest,
  assertBookTakePolicy,
  bookTakeRevertErrorsAbi,
  decodeBookTakeData,
} from './book-take.js';
import { buildApp } from './app.js';

const MODULE = '0x1D1FcAa8C1677dF51dda4F26bc391B91b98dEBE3';
const CNGN_BOOK = '0x5a35f149005Ce74b874F7Cf07CC2618BFA4F8Bd4';
const EURC_BOOK = '0x83C5741a24d57189379E1215F7A22d9f048E89d5';
const OWNER = '0x1111111111111111111111111111111111111111';
const NOW = 1_795_100_000;

const TYPES = [
  { type: 'address' },
  { type: 'uint256' },
  { type: 'bool' },
  { type: 'uint256' },
  { type: 'uint256' },
  { type: 'uint256' },
  { type: 'uint256' },
  { type: 'uint64' },
  { type: 'uint16' },
  { type: 'bool' },
] as const;

function data(overrides: Partial<{ book: `0x${string}`; amount: bigint; limitPrice: bigint; deadline: bigint; maxLevels: number }> = {}) {
  return encodeAbiParameters(TYPES, [
    overrides.book ?? CNGN_BOOK,
    1n,
    true,
    overrides.amount ?? 10n ** 18n,
    overrides.limitPrice ?? 700_000_000_000_000n,
    10n ** 18n,
    2n * 10n ** 18n,
    overrides.deadline ?? BigInt(NOW + 60),
    overrides.maxLevels ?? 255,
    false,
  ]);
}

function request(over: Partial<BookTakeRequest['action']> = {}): BookTakeRequest {
  return {
    action: {
      subaccount_id: '61',
      nonce: '1',
      module: MODULE,
      data: data(),
      expiry: String(NOW + 600),
      owner: OWNER,
      signer: OWNER,
      ...over,
    },
    signature: `0x${'ab'.repeat(65)}`,
  };
}

const policy = { moduleAddress: MODULE, bookAddresses: [CNGN_BOOK, EURC_BOOK], nowSeconds: NOW } as const;

function refused(req: BookTakeRequest, pattern: RegExp) {
  assert.throws(() => assertBookTakePolicy(req, policy), (error: unknown) => error instanceof BookTakeRejectedError && pattern.test(error.message));
}

test('every revert in the ABI carries the selector the contracts emit', () => {
  // Derived with `cast sig`; each is in the compiled ABI of BookTakeModule or risk-core's OnchainBook.
  const expected: Record<string, string> = {
    BM_NonceAlreadyUsed: '0xdfad89e3',
    BM_OnlyMatching: '0x7222a918',
    BTM_InvalidActionLength: '0x65131b8a',
    BTM_InvalidAccount: '0x0f308aff',
    BTM_BookNotAllowed: '0xc0bb8f81',
    BTM_NotReducing: '0x732217c0',
    OB_MarketDisabled: '0x60352307',
    OB_Expired: '0x3ebcbd78',
    OB_TradingClosed: '0x68e1766b',
    OB_NotAuthorized: '0x8dd98f69',
    OB_TakerAllowanceTooLow: '0xb0032325',
    OB_FeeTooHigh: '0x42719bfd',
    OB_BelowMinFill: '0x1534b6d5',
    OB_InvalidMarket: '0x88630305',
  };
  assert.equal(bookTakeRevertErrorsAbi.length, Object.keys(expected).length);
  for (const item of bookTakeRevertErrorsAbi) {
    assert.equal(toFunctionSelector(`${item.name}()`), expected[item.name], item.name);
  }
});

test('the take data decodes field for field', () => {
  const d = decodeBookTakeData(data());
  assert.equal(d.book, CNGN_BOOK);
  assert.equal(d.marketId, 1n);
  assert.equal(d.isBuy, true);
  assert.equal(d.amount, 10n ** 18n);
  assert.equal(d.limitPrice, 700_000_000_000_000n);
  assert.equal(d.maxLevels, 255);
  assert.equal(d.reduceOnly, false);
});

test('a well-formed take on an allowed book passes policy', () => {
  assert.equal(assertBookTakePolicy(request(), policy).book, CNGN_BOOK);
  assert.equal(assertBookTakePolicy(request({ data: data({ book: EURC_BOOK }) }), policy).book, EURC_BOOK);
});

test('policy refuses what the executor should not simulate', () => {
  refused(request({ module: '0x2222222222222222222222222222222222222222' }), /book-take module/);
  refused(request({ subaccount_id: '0' }), /must not be 0/);
  refused(request({ signer: '0x3333333333333333333333333333333333333333' }), /signer must be action.owner/);
  refused(request({ expiry: String(NOW - 1) }), /expired/);
  refused(request({ data: data({ book: '0x4444444444444444444444444444444444444444' }) }), /not traded through this executor/);
  refused(request({ data: data({ amount: 0n }) }), /amount must be greater than 0/);
  refused(request({ data: data({ limitPrice: 0n }) }), /limitPrice/);
  refused(request({ data: data({ maxLevels: 0 }) }), /maxLevels/);
  refused(request({ data: data({ deadline: BigInt(NOW - 1) }) }), /deadline has passed/);
});

test('malformed take data is refused before it is simulated', () => {
  const good = data();
  refused(request({ data: good.slice(0, -64) }), /ten 32-byte words/);
  refused(request({ data: `${good}${'00'.repeat(32)}` }), /ten 32-byte words/);
  // a dirty high byte in the book's address word
  refused(request({ data: `0x01${good.slice(4)}` }), /left-padded address/);
  // isBuy word holding 2
  refused(request({ data: `0x${good.slice(2, 2 + 128)}${'0'.repeat(63)}2${good.slice(2 + 192)}` }), /isBuy is not a bool/);
});

test('POST /book-take answers 503 when book takes are not configured', async () => {
  const app = buildApp({
    config: { chainId: 8453, dryRun: false, waitForReceipt: false, executorAddress: OWNER } as never,
    executor: { execute: async () => ({ accepted: true }) } as never,
    matchingAddress: OWNER,
    tradeModuleAddress: OWNER,
    logStream: { write() {} },
  });
  const response = await app.inject({ method: 'POST', url: '/book-take', payload: request() });
  assert.equal(response.statusCode, 503);
  await app.close();
});

test('POST /book-take maps a refusal to 422 with the revert named', async () => {
  const app = buildApp({
    config: { chainId: 8453, dryRun: false, waitForReceipt: false, executorAddress: OWNER } as never,
    executor: { execute: async () => ({ accepted: true }) } as never,
    matchingAddress: OWNER,
    tradeModuleAddress: OWNER,
    bookTaker: {
      bookTake: async () => {
        throw new BookTakeRejectedError('take would revert: OB_BelowMinFill', 'OB_BelowMinFill');
      },
    },
    logStream: { write() {} },
  });
  const response = await app.inject({ method: 'POST', url: '/book-take', payload: request() });
  assert.equal(response.statusCode, 422);
  assert.equal(response.json().revert, 'OB_BelowMinFill');
  await app.close();
});

test('book-take config is all or nothing', async () => {
  const { parseBookTakeConfig } = await import('./config.js');
  const base = { BOOK_TAKE_BOOKS: '', BOOK_TAKE_MAX_GAS_ETH_PER_HOUR: '0.003', BOOK_TAKE_MIN_EXECUTOR_ETH: '0.004' };
  assert.equal(parseBookTakeConfig({ ...base }), undefined);
  assert.throws(() => parseBookTakeConfig({ ...base, BOOK_TAKE_MODULE_ADDRESS: MODULE }), /set together/);
  assert.throws(() => parseBookTakeConfig({ ...base, BOOK_TAKE_BOOKS: CNGN_BOOK }), /set together/);
  const on = parseBookTakeConfig({ ...base, BOOK_TAKE_MODULE_ADDRESS: MODULE, BOOK_TAKE_BOOKS: `${CNGN_BOOK},${EURC_BOOK}` })!;
  assert.deepEqual(on.bookAddresses, [CNGN_BOOK, EURC_BOOK]);
  assert.equal(on.minExecutorWei, 4_000_000_000_000_000n);
});
