import {
  decodeAbiParameters,
  encodeAbiParameters,
  getAddress,
  keccak256,
  parseAbi,
  parseEventLogs,
  toHex,
  type Log,
} from 'viem';

import type { DepositRequest } from './types.js';

/**
 * Signed deposits: a user-signed DepositModule action that opens a perp margin account (subaccount_id 0) or tops
 * one up, submitted through Matching.verifyAndMatch with the venue paying gas.
 *
 * What the chain does and does not check, from contracts/execution/test/modules/DepositModuleFork.t.sol against
 * the live deployment: Matching and ActionVerifier check the signer, the expiry and, for an existing account, that
 * action.owner owns it; the module checks the nonce; the perp CashAsset refuses an account under any manager but
 * the perp SRM (MW_UnknownManager). Nothing on chain refuses another wrapped asset, or the max sentinel (which
 * deposits the owner's whole balance). This policy pins all of it before anything is simulated.
 */

/** Base USDC's decimals. A deposit names its amount in these; the ledger credits it at 18. */
export const DEPOSIT_TOKEN_DECIMALS = 6;
const LEDGER_SCALE = 10n ** BigInt(18 - DEPOSIT_TOKEN_DECIMALS);
const MAX_UINT256 = (1n << 256n) - 1n;
const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';

/** The one place a deposit amount changes units: 6-decimal USDC base units to the ledger's 18. */
export function depositUnitsToLedger(units: bigint): bigint {
  return units * LEDGER_SCALE;
}

/** "1000.000000" for 1_000_000_000 base units. */
export function formatDepositUnits(units: bigint): string {
  const scale = 10n ** BigInt(DEPOSIT_TOKEN_DECIMALS);
  return `${units / scale}.${(units % scale).toString().padStart(DEPOSIT_TOKEN_DECIMALS, '0')}`;
}

/**
 * Errors a deposit can revert with below Matching (whose own M_* and OV_* are in its ABI): the module's base, the
 * CashAsset's manager whitelist and caps, and the account's manager. Listed so a refused deposit is reported by name.
 * USDC reverts with require strings ("ERC20: transfer amount exceeds allowance"), which viem surfaces as the reason.
 */
export const depositRevertErrorsAbi = parseAbi([
  'error BM_NonceAlreadyUsed()',
  'error BM_OnlyMatching()',
  'error DM_InvalidDepositActionLength()',
  'error MW_UnknownManager()',
  'error BM_AdjustmentsPaused()',
  'error BM_AssetCapExceeded()',
]);

const DEPOSITED_SUBACCOUNT_EVENT = parseAbi(['event DepositedSubAccount(uint256 indexed accountId, address indexed owner)']);

/** A deposit this executor will not submit. `status` is the HTTP status the API should answer with. */
export class DepositRejectedError extends Error {
  constructor(
    message: string,
    /** The revert a simulation hit, by name when known. Absent for a policy rejection. */
    readonly revert?: string,
    readonly status: 422 | 503 = 422,
  ) {
    super(message);
    this.name = 'DepositRejectedError';
  }
}

export type DepositPolicy = {
  moduleAddress: `0x${string}`;
  /** Wrapped assets a deposit may pay into. Only the perp CashAsset for now. */
  assetAddresses: readonly `0x${string}`[];
  /** The only manager a new account may be opened under: the perp SRM. */
  managerAddress: `0x${string}`;
  /** In 6-decimal base units. */
  minAmount: bigint;
  nowSeconds: number;
};

export type DepositData = { amount: bigint; asset: `0x${string}`; manager: `0x${string}` };

const DEPOSIT_DATA_PATTERN = /^0x[0-9a-fA-F]{192}$/;
const ADDRESS_WORD_PADDING = '0'.repeat(24);

/** `abi.encode(DepositData{uint256 amount; address asset; address managerForNewAccount})`: exactly three static words. */
export function decodeDepositData(data: string): DepositData {
  if (!DEPOSIT_DATA_PATTERN.test(data)) {
    throw new DepositRejectedError(
      'action.data must be abi.encode(uint256 amount, address asset, address managerForNewAccount): exactly 96 bytes',
    );
  }
  // Solidity's abi.decode reverts on an address word with dirty high bits; refuse it rather than simulate it.
  if (data.slice(66, 90) !== ADDRESS_WORD_PADDING || data.slice(130, 154) !== ADDRESS_WORD_PADDING) {
    throw new DepositRejectedError('action.data address words are not left-padded addresses');
  }
  const [amount, asset, manager] = decodeAbiParameters(
    [{ type: 'uint256' }, { type: 'address' }, { type: 'address' }],
    data as `0x${string}`,
  );
  return { amount, asset: getAddress(asset), manager: getAddress(manager) };
}

export function assertDepositPolicy(request: DepositRequest, policy: DepositPolicy): DepositData {
  const { action } = request;

  const expectedModule = getAddress(policy.moduleAddress);
  if (getAddress(action.module) !== expectedModule) {
    throw new DepositRejectedError(`action.module must be the deposit module ${expectedModule}`);
  }
  // On chain a session key may sign a deposit that pulls USDC from the owner's wallet. Not supported here.
  if (getAddress(action.owner) !== getAddress(action.signer)) {
    throw new DepositRejectedError('action.signer must be action.owner; session-key deposits are not supported');
  }
  if (BigInt(action.expiry) < BigInt(policy.nowSeconds)) {
    throw new DepositRejectedError('action has expired');
  }

  const data = decodeDepositData(action.data);
  if (!policy.assetAddresses.some((allowed) => getAddress(allowed) === data.asset)) {
    throw new DepositRejectedError(`asset ${data.asset} is not depositable through this executor`);
  }
  if (data.amount === MAX_UINT256) {
    throw new DepositRejectedError('amount must be explicit; the max sentinel (deposit the whole balance) is not accepted');
  }
  if (data.amount < policy.minAmount) {
    throw new DepositRejectedError(
      `amount ${formatDepositUnits(data.amount)} USDC is below the minimum ${formatDepositUnits(policy.minAmount)} USDC`,
    );
  }
  const manager = getAddress(policy.managerAddress);
  if (BigInt(action.subaccount_id) === 0n) {
    if (data.manager !== manager) {
      throw new DepositRejectedError(`a new account must be opened under the perp risk manager ${manager}`);
    }
  } else if (data.manager !== manager && data.manager !== ZERO_ADDRESS) {
    // Ignored by the module for an existing account, but a value that is neither is a client bug worth naming.
    throw new DepositRejectedError(`managerForNewAccount must be ${manager} or zero for an existing account`);
  }
  return data;
}

const ACTION_TYPEHASH = keccak256(
  toHex('Action(uint256 subaccountId,uint256 nonce,address module,bytes data,uint256 expiry,address owner,address signer)'),
);

/**
 * The action's EIP-712 struct hash -- Matching.getActionHash -- which is what makes a retried request the same
 * request. deposit.test.ts pins it against the live contract.
 */
export function depositActionHash(request: DepositRequest): `0x${string}` {
  const { action } = request;
  return keccak256(
    encodeAbiParameters(
      [
        { type: 'bytes32' },
        { type: 'uint256' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'bytes32' },
        { type: 'uint256' },
        { type: 'address' },
        { type: 'address' },
      ],
      [
        ACTION_TYPEHASH,
        BigInt(action.subaccount_id),
        BigInt(action.nonce),
        getAddress(action.module),
        keccak256(action.data as `0x${string}`),
        BigInt(action.expiry),
        getAddress(action.owner),
        getAddress(action.signer),
      ],
    ),
  );
}

/** `verifyAndMatch` arguments for one deposit. The module ignores `actionData`. */
export function buildDepositArgs(request: DepositRequest) {
  const { action } = request;
  return [
    [
      {
        subaccountId: BigInt(action.subaccount_id),
        nonce: BigInt(action.nonce),
        module: getAddress(action.module),
        data: action.data as `0x${string}`,
        expiry: BigInt(action.expiry),
        owner: getAddress(action.owner),
        signer: getAddress(action.signer),
      },
    ],
    [request.signature as `0x${string}`],
    '0x',
  ] as const;
}

/**
 * The account a mined deposit credited: the given one, or for a new account the id in Matching's
 * DepositedSubAccount for this owner. Undefined if the event is missing, which a caller reports rather than guesses.
 */
export function creditedSubaccount(
  request: DepositRequest,
  matching: `0x${string}`,
  logs: readonly Log[],
): string | undefined {
  if (BigInt(request.action.subaccount_id) !== 0n) {
    return request.action.subaccount_id;
  }
  const owner = getAddress(request.action.owner);
  const events = parseEventLogs({ abi: DEPOSITED_SUBACCOUNT_EVENT, logs: [...logs], strict: true });
  const event = events.find((e) => getAddress(e.address) === getAddress(matching) && getAddress(e.args.owner) === owner);
  return event?.args.accountId.toString();
}
