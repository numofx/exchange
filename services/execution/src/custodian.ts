import { getAddress, parseAbi } from 'viem';
import { z } from 'zod';

/**
 * BookCustodian (contracts/risk-core/src/periphery/BookCustodian.sol, docs/book-custodian-spec.md): the calls this
 * executor relays for app users, the venue paying gas. Every call either carries the wallet's (or, for a take, its
 * trading key's) EIP-712 signature, which the contract checks, or harms no one (`openAccount`: an empty account). The
 * policy here refuses what this executor should not spend a simulation or a queue slot on; the chain is the check.
 */

/** The custodian's relayed entry points and every revert below them, by name. Selectors pinned in custodian.test.ts. */
export const custodianAbi = parseAbi([
  'struct Take { uint256 accountId; address book; uint256 marketId; bool isBuy; uint256 amount; uint256 limitPrice; uint256 minFill; uint256 maxFee; uint64 deadline; uint16 maxLevels; bool reduceOnly; uint256 nonce; }',
  'function take(Take t, bytes signature, bytes reports) returns (uint256 filled, uint256 avgPrice)',
  'function openAccount(address wallet, address manager) returns (uint256 accountId)',
  'function depositWithPermit(uint256 accountId, address asset, uint256 amount, uint256 permitDeadline, uint8 v, bytes32 r, bytes32 s)',
  'function withdrawFor(uint256 accountId, address asset, uint256 amount, uint256 nonce, uint64 deadline, bytes signature)',
  'function exitFor(uint256 accountId, uint256 nonce, uint64 deadline, bytes signature)',
  'function setTradingKeyFor(address wallet, address key, uint64 validUntil, uint256 nonce, uint64 deadline, bytes signature)',
  'function accountOwner(uint256 accountId) view returns (address)',
  'event AccountOpened(uint256 indexed accountId, address indexed wallet, address manager)',
  'error BC_AccountLeft()',
  'error BC_BadSignature()',
  'error BC_Expired()',
  'error BC_GrantPersisted()',
  'error BC_NonceUsed()',
  'error BC_NotAllowed()',
  'error BC_NotHeld()',
  'error BC_NotOwnerSending()',
  'error BC_NotReducing()',
  'error BC_NotWallet()',
  'error BC_Paused()',
  'error BC_PermitFailed()',
  'error BC_ZeroAddress()',
  'error OB_MarketDisabled()',
  'error OB_Expired()',
  'error OB_TradingClosed()',
  'error OB_NotAuthorized()',
  'error OB_TakerAllowanceTooLow()',
  'error OB_FeeTooHigh()',
  'error OB_BelowMinFill()',
  'error OB_InvalidMarket()',
]);

/** A call this executor will not relay: it breaks policy or the chain would revert it. No gas spent. */
export class CustodianRejectedError extends Error {
  constructor(
    message: string,
    readonly revert?: string,
    /** 422 for policy or a revert; 503 while relaying is off or paused (gas budget or executor floor). */
    readonly status: 422 | 503 = 422,
  ) {
    super(message);
    this.name = 'CustodianRejectedError';
  }
}

const address = z.string().regex(/^0x[0-9a-fA-F]{40}$/, 'an address');
const uint = z.string().regex(/^(0|[1-9][0-9]{0,77})$/, 'a decimal unsigned integer');
const hex = z.string().regex(/^0x([0-9a-fA-F]{2})*$/, 'hex bytes');
const signature = z.string().regex(/^0x[0-9a-fA-F]{130,}$/, 'a signature');
const bytes32 = z.string().regex(/^0x[0-9a-fA-F]{64}$/, 'bytes32');

export const custodianRequestSchema = z.discriminatedUnion('call', [
  z.object({
    call: z.literal('take'),
    take: z.object({
      account_id: uint,
      book: address,
      market_id: uint,
      is_buy: z.boolean(),
      amount: uint,
      limit_price: uint,
      min_fill: uint,
      max_fee: uint,
      deadline: uint,
      max_levels: z.number().int().min(1).max(65_535),
      reduce_only: z.boolean(),
      nonce: uint,
    }),
    signature,
    reports: hex.default('0x'),
  }),
  z.object({ call: z.literal('open_account'), wallet: address }),
  z.object({
    call: z.literal('deposit_with_permit'),
    account_id: uint,
    asset: address,
    amount: uint,
    permit_deadline: uint,
    v: z.number().int().min(0).max(255),
    r: bytes32,
    s: bytes32,
  }),
  z.object({
    call: z.literal('withdraw_for'),
    account_id: uint,
    asset: address,
    amount: uint,
    nonce: uint,
    deadline: uint,
    signature,
  }),
  z.object({ call: z.literal('exit_for'), account_id: uint, nonce: uint, deadline: uint, signature }),
  z.object({
    call: z.literal('set_trading_key_for'),
    wallet: address,
    key: address,
    valid_until: uint,
    nonce: uint,
    deadline: uint,
    signature,
  }),
]);

export type CustodianRequest = z.infer<typeof custodianRequestSchema>;

export type CustodianPolicy = {
  /** The books takes are relayed on (BOOK_TAKE_BOOKS); the custodian's own allowlist is the chain's check. */
  bookAddresses: readonly `0x${string}`[];
  /** The deposit and withdrawal assets relayed (CUSTODIAN_ASSETS). */
  assetAddresses: readonly `0x${string}`[];
  /** The manager every relayed `openAccount` uses (MarginEngine v2). */
  manager: `0x${string}`;
  nowSeconds: number;
};

/** The longest a relayed take's deadline may run: a take is signed for the next minute, never for later. */
export const MAX_TAKE_DEADLINE_SECONDS = 600;
const UINT64_MAX = 2n ** 64n - 1n;

export type CustodianCall = { functionName: string; args: readonly unknown[]; accountId?: bigint };

const same = (a: string, b: string) => getAddress(a) === getAddress(b);

function deadlineOk(deadline: bigint, now: number, label: string) {
  if (deadline > UINT64_MAX) throw new CustodianRejectedError(`${label} does not fit a uint64`);
  if (deadline < BigInt(now)) throw new CustodianRejectedError(`${label} has passed`);
}

/** Policy, then the call to simulate and send. */
export function buildCustodianCall(request: CustodianRequest, policy: CustodianPolicy): CustodianCall {
  const now = policy.nowSeconds;
  switch (request.call) {
    case 'take': {
      const t = request.take;
      if (!policy.bookAddresses.some((b) => same(b, t.book))) {
        throw new CustodianRejectedError(`book ${getAddress(t.book)} is not traded through this executor`);
      }
      if (BigInt(t.account_id) === 0n) throw new CustodianRejectedError('account_id must not be 0');
      if (BigInt(t.amount) === 0n) throw new CustodianRejectedError('take amount must be greater than 0');
      if (BigInt(t.limit_price) === 0n) throw new CustodianRejectedError('limit_price must be greater than 0');
      deadlineOk(BigInt(t.deadline), now, 'take deadline');
      if (BigInt(t.deadline) > BigInt(now + MAX_TAKE_DEADLINE_SECONDS)) {
        throw new CustodianRejectedError(`take deadline is more than ${MAX_TAKE_DEADLINE_SECONDS}s away`);
      }
      const take = {
        accountId: BigInt(t.account_id),
        book: getAddress(t.book),
        marketId: BigInt(t.market_id),
        isBuy: t.is_buy,
        amount: BigInt(t.amount),
        limitPrice: BigInt(t.limit_price),
        minFill: BigInt(t.min_fill),
        maxFee: BigInt(t.max_fee),
        deadline: BigInt(t.deadline),
        maxLevels: t.max_levels,
        reduceOnly: t.reduce_only,
        nonce: BigInt(t.nonce),
      };
      return { functionName: 'take', args: [take, request.signature, request.reports], accountId: take.accountId };
    }
    case 'open_account': {
      if (BigInt(request.wallet) === 0n) throw new CustodianRejectedError('wallet must not be the zero address');
      return { functionName: 'openAccount', args: [getAddress(request.wallet), getAddress(policy.manager)] };
    }
    case 'deposit_with_permit': {
      assertAsset(request.asset, policy);
      if (BigInt(request.amount) === 0n) throw new CustodianRejectedError('amount must be greater than 0');
      deadlineOk(BigInt(request.permit_deadline), now, 'permit deadline');
      return {
        functionName: 'depositWithPermit',
        args: [
          BigInt(request.account_id),
          getAddress(request.asset),
          BigInt(request.amount),
          BigInt(request.permit_deadline),
          request.v,
          request.r,
          request.s,
        ],
        accountId: BigInt(request.account_id),
      };
    }
    case 'withdraw_for': {
      assertAsset(request.asset, policy);
      if (BigInt(request.amount) === 0n) throw new CustodianRejectedError('amount must be greater than 0');
      deadlineOk(BigInt(request.deadline), now, 'deadline');
      return {
        functionName: 'withdrawFor',
        args: [
          BigInt(request.account_id),
          getAddress(request.asset),
          BigInt(request.amount),
          BigInt(request.nonce),
          BigInt(request.deadline),
          request.signature,
        ],
        accountId: BigInt(request.account_id),
      };
    }
    case 'exit_for': {
      deadlineOk(BigInt(request.deadline), now, 'deadline');
      return {
        functionName: 'exitFor',
        args: [BigInt(request.account_id), BigInt(request.nonce), BigInt(request.deadline), request.signature],
        accountId: BigInt(request.account_id),
      };
    }
    case 'set_trading_key_for': {
      deadlineOk(BigInt(request.deadline), now, 'deadline');
      if (BigInt(request.valid_until) > UINT64_MAX) throw new CustodianRejectedError('valid_until does not fit a uint64');
      return {
        functionName: 'setTradingKeyFor',
        args: [
          getAddress(request.wallet),
          getAddress(request.key),
          BigInt(request.valid_until),
          BigInt(request.nonce),
          BigInt(request.deadline),
          request.signature,
        ],
      };
    }
  }
}

function assertAsset(asset: string, policy: CustodianPolicy) {
  if (!policy.assetAddresses.some((a) => same(a, asset))) {
    throw new CustodianRejectedError(`asset ${getAddress(asset)} is not relayed through this executor`);
  }
}
