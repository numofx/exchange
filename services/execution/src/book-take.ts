import { decodeAbiParameters, getAddress, parseAbi } from 'viem';

import type { WithdrawRequest } from './types.js';

/** A signed BookTakeModule action has the same shape as a withdrawal's: one action and its signature. */
export type BookTakeRequest = WithdrawRequest;

/**
 * Custom errors a book take can revert with below Matching: BookTakeModule and its base, risk-core's OnchainBook,
 * and the account's MarginEngine. Listed so a refused take is reported by name; `book-take.test.ts` pins every
 * selector against the compiled contracts.
 */
export const bookTakeRevertErrorsAbi = parseAbi([
  'error BM_NonceAlreadyUsed()',
  'error BM_OnlyMatching()',
  'error BTM_InvalidActionLength()',
  'error BTM_InvalidAccount()',
  'error BTM_BookNotAllowed()',
  'error BTM_NotReducing()',
  'error OB_MarketDisabled()',
  'error OB_Expired()',
  'error OB_TradingClosed()',
  'error OB_NotAuthorized()',
  'error OB_TakerAllowanceTooLow()',
  'error OB_FeeTooHigh()',
  'error OB_BelowMinFill()',
  'error OB_InvalidMarket()',
]);

/** A take this executor will not submit: it breaks policy or the chain would revert it. No gas spent. */
export class BookTakeRejectedError extends Error {
  constructor(
    message: string,
    /** The revert the simulation hit, by name when known. Absent for a policy rejection. */
    readonly revert?: string,
    /** 422 for policy or a revert; 503 while takes are paused (gas budget or executor floor). */
    readonly status: 422 | 503 = 422,
  ) {
    super(message);
    this.name = 'BookTakeRejectedError';
  }
}

export type BookTakePolicy = {
  moduleAddress: `0x${string}`;
  /** The books this executor submits takes on: BookTakeModule's own allowlist is the chain's check, this is ours. */
  bookAddresses: readonly `0x${string}`[];
  nowSeconds: number;
};

/** IBookTakeModule.BookTakeData, field for field. */
export type BookTakeData = {
  book: `0x${string}`;
  marketId: bigint;
  isBuy: boolean;
  amount: bigint;
  limitPrice: bigint;
  minFill: bigint;
  maxFee: bigint;
  deadline: bigint;
  maxLevels: number;
  reduceOnly: boolean;
};

const BOOK_TAKE_DATA_TYPES = [
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

const BOOK_TAKE_DATA_PATTERN = /^0x[0-9a-fA-F]{640}$/;

/**
 * `abi.encode(BookTakeData)`: ten static words and nothing else. Solidity's abi.decode reverts on a word with dirty
 * high bits (an address, a bool, a uint64 or uint16); this refuses one here rather than simulate it.
 */
export function decodeBookTakeData(data: string): BookTakeData {
  if (!BOOK_TAKE_DATA_PATTERN.test(data)) {
    throw new BookTakeRejectedError('action.data must be abi.encode(BookTakeData): exactly ten 32-byte words');
  }
  const word = (i: number) => data.slice(2 + i * 64, 2 + (i + 1) * 64);
  const padded = (i: number, bytes: number) => /^0+$/.test(word(i).slice(0, 64 - bytes * 2));
  if (!padded(0, 20)) throw new BookTakeRejectedError('action.data book word is not a left-padded address');
  for (const [i, name] of [[2, 'isBuy'], [9, 'reduceOnly']] as const) {
    if (!/^0{63}[01]$/.test(word(i))) throw new BookTakeRejectedError(`action.data ${name} is not a bool`);
  }
  if (!padded(7, 8)) throw new BookTakeRejectedError('action.data deadline is not a uint64');
  if (!padded(8, 2)) throw new BookTakeRejectedError('action.data maxLevels is not a uint16');
  const [book, marketId, isBuy, amount, limitPrice, minFill, maxFee, deadline, maxLevels, reduceOnly] =
    decodeAbiParameters(BOOK_TAKE_DATA_TYPES, data as `0x${string}`);
  return { book: getAddress(book), marketId, isBuy, amount, limitPrice, minFill, maxFee, deadline, maxLevels, reduceOnly };
}

/**
 * The checks made before a take is simulated. The chain enforces the signature, the owner's custody of the account,
 * the nonce, the module's book allowlist, and the book's own limits; these refuse what this executor should not
 * spend a simulation, or a queue slot, on.
 */
export function assertBookTakePolicy(request: BookTakeRequest, policy: BookTakePolicy): BookTakeData {
  const { action } = request;
  const expectedModule = getAddress(policy.moduleAddress);
  if (getAddress(action.module) !== expectedModule) {
    throw new BookTakeRejectedError(`action.module must be the book-take module ${expectedModule}, got ${getAddress(action.module)}`);
  }
  if (BigInt(action.subaccount_id) === 0n) {
    throw new BookTakeRejectedError('action.subaccount_id must not be 0');
  }
  // Until session keys are checked off-chain too, only the owner may sign a take.
  if (getAddress(action.owner) !== getAddress(action.signer)) {
    throw new BookTakeRejectedError('action.signer must be action.owner; session-key takes are not supported');
  }
  if (BigInt(action.expiry) < BigInt(policy.nowSeconds)) {
    throw new BookTakeRejectedError('action has expired');
  }
  const data = decodeBookTakeData(action.data);
  if (!policy.bookAddresses.some((allowed) => getAddress(allowed) === data.book)) {
    throw new BookTakeRejectedError(`book ${data.book} is not traded through this executor`);
  }
  if (data.amount === 0n) throw new BookTakeRejectedError('take amount must be greater than 0');
  if (data.limitPrice === 0n) throw new BookTakeRejectedError('limitPrice must be greater than 0');
  if (data.maxLevels === 0) throw new BookTakeRejectedError('maxLevels must be greater than 0');
  if (data.deadline < BigInt(policy.nowSeconds)) throw new BookTakeRejectedError('take deadline has passed');
  return data;
}
