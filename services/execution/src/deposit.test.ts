import test from 'node:test';
import assert from 'node:assert/strict';

import { encodeAbiParameters, encodeEventTopics, parseAbi, type Log } from 'viem';

import { buildApp } from './app.js';
import type { AppConfig } from './config.js';
import {
  DepositRejectedError,
  assertDepositPolicy,
  assertPermitPolicy,
  buildPermitArgs,
  creditedSubaccount,
  decodeDepositData,
  depositActionHash,
  depositUnitsToLedger,
  formatDepositUnits,
} from './deposit.js';
import type { DepositRequest } from './types.js';

const DEPOSIT_MODULE = '0x6540f8d9Eb599b045C05E45cb6a5B1730a806658';
const WITHDRAWAL_MODULE = '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB';
const MATCHING = '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191';
const PERP_CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272';
const PERP_SRM = '0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4';
const OLD_SRM = '0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b';
const CNGN_ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98';
const ZERO = '0x0000000000000000000000000000000000000000';
const OWNER = '0xeaBca823B4d35d8F2eac09edB55C42D8077fbFcA';
const OTHER = '0x1661AA54fA390cd916722F971e4A9Fe4c01889fB';
const NOW = 1_789_400_000;
const MAX = (1n << 256n) - 1n;

const POLICY = {
  moduleAddress: DEPOSIT_MODULE,
  assetAddresses: [PERP_CASH],
  managerAddress: PERP_SRM,
  minAmount: 10_000_000n,
  nowSeconds: NOW,
} as const;

function depositData(amount = 1_000_000_000n, asset: string = PERP_CASH, manager: string = PERP_SRM) {
  return encodeAbiParameters(
    [{ type: 'uint256' }, { type: 'address' }, { type: 'address' }],
    [amount, asset as `0x${string}`, manager as `0x${string}`],
  );
}

/** Open a perp account with 1,000 USDC, as a trader would sign it. */
function request(action: Partial<DepositRequest['action']> = {}): DepositRequest {
  return {
    action: {
      subaccount_id: '0',
      nonce: '7',
      module: DEPOSIT_MODULE,
      data: depositData(),
      expiry: String(NOW + 600),
      owner: OWNER,
      signer: OWNER,
      ...action,
    },
    signature: `0x${'ab'.repeat(65)}`,
  };
}

function rejects(req: DepositRequest, pattern: RegExp) {
  assert.throws(() => assertDepositPolicy(req, POLICY), (e: unknown) => e instanceof DepositRejectedError && pattern.test(e.message));
}

test('a well-formed new-account deposit passes, decoded in 6-decimal units', () => {
  const data = assertDepositPolicy(request(), POLICY);
  assert.equal(data.amount, 1_000_000_000n);
  assert.equal(data.asset, PERP_CASH);
  assert.equal(data.manager, PERP_SRM);
});

// One rule each, by breaking exactly one field of a passing request.
test('another module is refused', () => rejects(request({ module: WITHDRAWAL_MODULE }), /deposit module/));
test('a signer that is not the owner is refused, even a would-be session key', () =>
  rejects(request({ signer: OTHER }), /session-key deposits are not supported/));
test('an expired action is refused', () => rejects(request({ expiry: String(NOW - 1) }), /expired/));
// Accepted on chain (DepositModuleFork.testContractAcceptsADifferentWrappedAsset): only policy stops it.
test('the cNGN escrow is refused: only the perp CashAsset is depositable', () =>
  rejects(request({ data: depositData(1_000_000_000n, CNGN_ESCROW) }), /not depositable/));
// On chain the max sentinel deposits the whole balance (testContractTreatsMaxAmountAsTheWholeBalance).
test('the max sentinel is refused: the amount must be explicit', () =>
  rejects(request({ data: depositData(MAX) }), /must be explicit/));
test('an amount below the minimum is refused, named in USDC', () =>
  rejects(request({ data: depositData(9_999_999n) }), /9\.999999 USDC is below the minimum 10\.000000 USDC/));
// The perp CashAsset would revert MW_UnknownManager (testCashAssetRejectsADifferentManager); refuse it up front.
test('a new account under another manager is refused', () =>
  rejects(request({ data: depositData(1_000_000_000n, PERP_CASH, OLD_SRM) }), /perp risk manager/));
test('a top-up may carry a zero manager word', () =>
  assert.doesNotThrow(() => assertDepositPolicy(request({ subaccount_id: '24', data: depositData(1_000_000_000n, PERP_CASH, ZERO) }), POLICY)));
test('a top-up naming some other manager is refused as a client bug', () =>
  rejects(request({ subaccount_id: '24', data: depositData(1_000_000_000n, PERP_CASH, OLD_SRM) }), /or zero for an existing account/));

test('data that is not exactly three words is refused', () => rejects(request({ data: '0x1234' }), /exactly 96 bytes/));
test('a dirty address word is refused rather than simulated', () => {
  const dirty = `${depositData().slice(0, 66)}ff${depositData().slice(68)}`;
  assert.throws(() => decodeDepositData(dirty), /left-padded/);
});

// Matching.getActionHash for this exact action on Base (cast call, 2026-10-09). The idempotency key is the chain's
// own hash of the action, not a digest of the JSON, so two encodings of one action are one request.
test('the action hash is Matching.getActionHash', () => {
  assert.equal(depositActionHash(request({ expiry: '1789400600' })), '0x1a818d052cdee2d89d3ce55092946f7ae24a0d22a3324c646c1d88ee74aba98c');
});

test('units change in one place: 6-decimal USDC to the 18-decimal ledger', () => {
  assert.equal(depositUnitsToLedger(1_000_000_000n), 1_000n * 10n ** 18n);
  assert.equal(formatDepositUnits(1_000_000_000n), '1000.000000');
  assert.equal(formatDepositUnits(10_000_001n), '10.000001');
});

function depositedLog(emitter: string, accountId: bigint, owner: string): Log {
  const topics = encodeEventTopics({
    abi: parseAbi(['event DepositedSubAccount(uint256 indexed accountId, address indexed owner)']),
    eventName: 'DepositedSubAccount',
    args: { accountId, owner: owner as `0x${string}` },
  });
  return { address: emitter, topics, data: '0x' } as unknown as Log;
}

test('a new account is read from Matching\'s DepositedSubAccount for this owner', () => {
  const logs = [depositedLog(DEPOSIT_MODULE, 99n, OWNER), depositedLog(MATCHING, 98n, OTHER), depositedLog(MATCHING, 27n, OWNER)];
  assert.equal(creditedSubaccount(request(), MATCHING, logs), '27');
});
test('a top-up reports the account it named', () => assert.equal(creditedSubaccount(request({ subaccount_id: '24' }), MATCHING, []), '24'));
test('a missing event is reported as unknown, never guessed', () => assert.equal(creditedSubaccount(request(), MATCHING, []), undefined));


const appConfig = {
  port: 0, host: '127.0.0.1', rpcUrl: 'http://127.0.0.1:1', chainId: 8453,
  executorAddress: '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A', dryRun: true, waitForReceipt: false,
  receiptTimeoutMs: 60_000, withdrawalAssetAddresses: [], withdrawalReceiptTimeoutMs: 30_000,
} as unknown as AppConfig;

function app(depositor?: { deposit: (r: DepositRequest) => Promise<never> }) {
  return buildApp({
    config: appConfig,
    executor: { execute: async () => ({ accepted: true, tx_hash: '0x' }) },
    matchingAddress: MATCHING,
    tradeModuleAddress: DEPOSIT_MODULE,
    depositor: depositor as never,
  });
}

test('POST /deposit answers 503 when deposits are off', async () => {
  const res = await app().inject({ method: 'POST', url: '/deposit', payload: request() });
  assert.equal(res.statusCode, 503);
});

test('POST /deposit answers a refusal with its own status and the revert name', async () => {
  const refused = await app({ deposit: async () => { throw new DepositRejectedError('deposit would revert: MW_UnknownManager', 'MW_UnknownManager'); } })
    .inject({ method: 'POST', url: '/deposit', payload: request() });
  assert.equal(refused.statusCode, 422);
  assert.deepEqual(refused.json(), { error: 'deposit would revert: MW_UnknownManager', revert: 'MW_UnknownManager' });

  const paused = await app({ deposit: async () => { throw new DepositRejectedError('deposits are paused', undefined, 503); } })
    .inject({ method: 'POST', url: '/deposit', payload: request() });
  assert.equal(paused.statusCode, 503);
});

test('POST /deposit refuses a malformed body with a 400', async () => {
  const res = await app({ deposit: async () => { throw new Error('not reached'); } }).inject({ method: 'POST', url: '/deposit', payload: { action: {} } });
  assert.equal(res.statusCode, 400);
});

// ---- Phase 2: the permit path

const SIG = `0x${'11'.repeat(32)}${'22'.repeat(32)}1b` as const;

test('a permit must cover the deposit amount', () => {
  assert.throws(() => assertPermitPolicy({ value: '999999999', deadline: String(NOW + 60), signature: SIG }, 1_000_000_000n, NOW), /below the deposit amount/);
  assert.doesNotThrow(() => assertPermitPolicy({ value: '1000000000', deadline: String(NOW + 60), signature: SIG }, 1_000_000_000n, NOW));
});

test('an expired permit is refused', () => {
  assert.throws(() => assertPermitPolicy({ value: '1000000000', deadline: String(NOW - 1), signature: SIG }, 1_000_000_000n, NOW), /permit has expired/);
});

test('the permit is submitted with the DepositModule as spender and the signature split into v, r, s', () => {
  const args = buildPermitArgs({ ...request(), permit: { value: '1000000000', deadline: '1789400600', signature: SIG } }, DEPOSIT_MODULE);
  assert.deepEqual(args, [OWNER, DEPOSIT_MODULE, 1_000_000_000n, 1_789_400_600n, 27, `0x${'11'.repeat(32)}`, `0x${'22'.repeat(32)}`]);
  // A 0/1 recovery id is normalised to 27/28.
  assert.equal(buildPermitArgs({ ...request(), permit: { value: '1', deadline: '1', signature: `${SIG.slice(0, 130)}01` } }, DEPOSIT_MODULE)[4], 28);
});
