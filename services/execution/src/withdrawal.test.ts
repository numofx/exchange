import test from 'node:test';
import assert from 'node:assert/strict';

import { ContractFunctionRevertedError, encodeAbiParameters, encodeErrorResult, toFunctionSelector } from 'viem';

import type { WithdrawRequest } from './types.js';
import {
  WithdrawalRejectedError,
  assertWithdrawalPolicy,
  buildWithdrawArgs,
  decodeWithdrawalData,
  describeSimulationRevert,
  withdrawalRevertErrorsAbi,
} from './withdrawal.js';

const WITHDRAWAL_MODULE = '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB';
const TRADE_MODULE = '0x12423B366F6F07130961900bE00d05Ea63Acd071';
const WRAPPED_USDC = '0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84';
const WRAPPED_CNGN = '0x9D806fD040a719D27a8E5E77dc5aE0ED1e089493';
const LEGACY_CASH_ASSET = '0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6';
const OWNER = '0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA';
const NOW = 1_789_400_000;

const POLICY = { moduleAddress: WITHDRAWAL_MODULE, assetAddresses: [WRAPPED_USDC, WRAPPED_CNGN], nowSeconds: NOW } as const;

function withdrawalData(asset: string = WRAPPED_USDC, amount = 1_999_575n) {
  return encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [asset as `0x${string}`, amount]);
}

/** Subaccount #19's USDC, as a trader would sign it: 1.999575 USDC in native 6 decimals. */
function withdrawRequest(action: Partial<WithdrawRequest['action']> = {}): WithdrawRequest {
  return {
    action: {
      subaccount_id: '19',
      nonce: '7328734720000000',
      module: WITHDRAWAL_MODULE,
      data: withdrawalData(),
      expiry: String(NOW + 600),
      owner: OWNER,
      signer: OWNER,
      ...action,
    },
    signature: `0x${'ab'.repeat(65)}`,
  };
}

function rejectionOf(run: () => void): string {
  try {
    run();
  } catch (error) {
    assert.ok(error instanceof WithdrawalRejectedError, `expected a WithdrawalRejectedError, got ${error}`);
    return error.message;
  }
  assert.fail('expected the withdrawal to be rejected');
}

test('an allowlisted asset withdrawn to its owner passes policy', () => {
  assertWithdrawalPolicy(withdrawRequest(), POLICY);
  assertWithdrawalPolicy(withdrawRequest({ data: withdrawalData(WRAPPED_CNGN, 3_890_685_234n) }), POLICY);
});

test('withdrawal data decodes to exactly an asset and an amount', () => {
  assert.deepEqual(decodeWithdrawalData(withdrawalData()), { asset: WRAPPED_USDC, amount: 1_999_575n });
});

test('withdrawal data that is not exactly two words is refused', () => {
  const data = withdrawalData();
  for (const malformed of [`${data}00`, data.slice(0, -2), '0x', `0x${'00'.repeat(96)}`]) {
    assert.match(rejectionOf(() => decodeWithdrawalData(malformed)), /exactly 64 bytes/);
  }
});

test('an asset word with dirty high bits is refused rather than simulated', () => {
  const dirty = `0xff${withdrawalData().slice(4)}`;
  assert.match(rejectionOf(() => decodeWithdrawalData(dirty)), /left-padded address/);
});

test('each policy violation is refused before simulation', () => {
  const cases: [string, Partial<WithdrawRequest['action']>, RegExp][] = [
    ['another module', { module: TRADE_MODULE }, /must be the withdrawal module/],
    ['subaccount 0', { subaccount_id: '0' }, /must not be 0/],
    ['a signer other than the owner', { signer: '0x00000000000000000000000000000000000000cc' }, /session-key withdrawals/],
    ['an expired action', { expiry: String(NOW - 1) }, /expired/],
    ['an asset off the allowlist', { data: withdrawalData(LEGACY_CASH_ASSET) }, /not withdrawable/],
    ['a zero amount', { data: withdrawalData(WRAPPED_USDC, 0n) }, /greater than 0/],
  ];
  for (const [name, action, expected] of cases) {
    assert.match(rejectionOf(() => assertWithdrawalPolicy(withdrawRequest(action), POLICY)), expected, name);
  }
});

test('an action expiring this very second is still valid, as on chain', () => {
  assertWithdrawalPolicy(withdrawRequest({ expiry: String(NOW) }), POLICY);
});

test('the asset allowlist and module compare addresses regardless of casing', () => {
  assertWithdrawalPolicy(withdrawRequest({ module: WITHDRAWAL_MODULE.toLowerCase(), owner: OWNER.toLowerCase(), signer: OWNER }), {
    ...POLICY,
    assetAddresses: [WRAPPED_USDC.toLowerCase() as `0x${string}`],
  });
});

test('a withdrawal submits one action, one signature and empty action data', () => {
  const [actions, signatures, actionData] = buildWithdrawArgs(withdrawRequest());
  assert.equal(actions.length, 1);
  assert.equal(actions[0]!.subaccountId, 19n);
  assert.equal(actions[0]!.module, WITHDRAWAL_MODULE);
  assert.equal(signatures.length, 1);
  assert.equal(actionData, '0x');
});

test('every revert in the ABI carries the selector the contracts emit', () => {
  // Derived with `cast sig` from contracts/execution and contracts/risk-core.
  const expected: Record<string, string> = {
    BM_NonceAlreadyUsed: '0xdfad89e3',
    BM_OnlyMatching: '0x7222a918',
    WM_InvalidFromAccount: '0xc7ee13e3',
    WM_InvalidWithdrawalActionLength: '0xef7a2dc2',
    WERC_CannotBeNegative: '0xe5b25796',
    WERC_InvalidSubId: '0xabaa58b3',
    WERC_OnlyAccountOwner: '0x58341a4d',
    MW_UnknownManager: '0xbd8ac1f7',
    BM_AccountUnderLiquidation: '0x72d35b56',
    BM_AdjustmentsPaused: '0x83d3980b',
    BM_AssetCapExceeded: '0x8102bcdc',
    SRM_NoNegativeCash: '0x703701fb',
    SRM_PortfolioBelowMargin: '0x09598580',
  };
  assert.equal(withdrawalRevertErrorsAbi.length, Object.keys(expected).length);
  for (const item of withdrawalRevertErrorsAbi) {
    assert.equal(toFunctionSelector(`${item.name}()`), expected[item.name], item.name);
  }
});

test('a simulated revert is described by name, reason or selector', () => {
  const revert = (data: `0x${string}`) =>
    new ContractFunctionRevertedError({ abi: withdrawalRevertErrorsAbi, data, functionName: 'verifyAndMatch' });

  // Withdrawing more than the account holds.
  assert.equal(describeSimulationRevert(revert('0xe5b25796')), 'WERC_CannotBeNegative');

  const insufficientEscrow = encodeErrorResult({
    abi: [{ type: 'error', name: 'Error', inputs: [{ name: 'message', type: 'string' }] }],
    errorName: 'Error',
    args: ['ERC20: transfer amount exceeds balance'],
  });
  assert.equal(describeSimulationRevert(revert(insufficientEscrow)), 'ERC20: transfer amount exceeds balance');

  assert.match(describeSimulationRevert(revert('0xdeadbeef')) ?? '', /0xdeadbeef/);
});

test('a failure that is not a revert is not described as one', () => {
  assert.equal(describeSimulationRevert(new Error('fetch failed')), undefined);
  assert.equal(describeSimulationRevert('timeout'), undefined);
});
