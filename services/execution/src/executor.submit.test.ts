import test from 'node:test';
import assert from 'node:assert/strict';

import { encodeAbiParameters, parseAbi } from 'viem';

import type { AppConfig } from './config.js';
import { MatchExecutor } from './executor.js';
import { SignerNotOwnerError } from './signer-guard.js';
import type { ExecuteMatchRequest, WithdrawRequest } from './types.js';
import { WithdrawalRejectedError } from './withdrawal.js';

const TRADE_MODULE = '0x12423B366F6F07130961900bE00d05Ea63Acd071';
const WITHDRAWAL_MODULE = '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB';
const WRAPPED_USDC = '0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84';
const MATCHING = '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191';
const OWNER = '0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B';
const OTHER = '0x1661AA54fA390cd916722F971e4A9Fe4c01889fB';

/**
 * Port 1 is closed, so any RPC use fails immediately and unmistakably.
 *
 * That is the point: the guard runs before the queue and before `simulateContract`, so a refused
 * submission must surface as SignerNotOwnerError and never as a connection error. An owner-signed
 * one must do the opposite. These tests distinguish the two by which error arrives, which is what
 * pins the guard to the submit boundary rather than to either handler.
 */
const config: AppConfig = {
  port: 8081,
  host: '127.0.0.1',
  rpcUrl: 'http://127.0.0.1:1',
  privateKey: '0x1111111111111111111111111111111111111111111111111111111111111111',
  chainId: 8453,
  executorAddress: '0x19E7E376E7C213B7E7e7e46cc70A5dD086DAff2A',
  expectedActionOwner: undefined,
  // Left unset exactly as infra/ leaves it: the settlement path's own signer check is inert here,
  // which is why the boundary guard has to be the thing that fires.
  expectedActionSigner: undefined,
  dryRun: true,
  waitForReceipt: false,
  receiptTimeoutMs: 60_000,
  withdrawalAssetAddresses: [],
  withdrawalReceiptTimeoutMs: 30_000,
};

const deps = {
  // Components are NAMED, matching @numo/abis. viem encodes a tuple by name when the ABI has
  // them and positionally when it does not, so an unnamed ABI here makes every action encode as
  // undefined -- which fails before the RPC and would make the "reaches the RPC" tests below pass
  // for the wrong reason.
  matchingAbi: parseAbi([
    'function verifyAndMatch((uint256 subaccountId,uint256 nonce,address module,bytes data,uint256 expiry,address owner,address signer)[] actions,bytes[] signatures,bytes actionData)',
  ]),
  matchingAddress: MATCHING as `0x${string}`,
  tradeModuleAddress: TRADE_MODULE as `0x${string}`,
  withdrawal: { moduleAddress: WITHDRAWAL_MODULE as `0x${string}`, assetAddresses: [WRAPPED_USDC as `0x${string}`] },
};

const executor = () => MatchExecutor.create({ ...config }, deps);

function matchRequest(signer: string = OWNER): ExecuteMatchRequest {
  const action = (nonce: string) => ({
    subaccount_id: '15',
    nonce,
    module: TRADE_MODULE,
    data: '0x' as const,
    expiry: '1789999999',
    owner: OWNER,
    signer,
  });
  return {
    market: 'USDCcNGN-SPOT',
    asset_address: WRAPPED_USDC,
    module_address: TRADE_MODULE,
    maker_order_id: 'maker-1',
    taker_order_id: 'taker-1',
    actions: [action('1'), action('2')],
    signatures: [`0x${'ab'.repeat(65)}`, `0x${'cd'.repeat(65)}`],
    order_data: {
      taker_account: '19',
      taker_fee: '0',
      fill_details: [{ filled_account: '15', amount_filled: '1', price: '1', fee: '0' }],
      manager_data: '0x',
    },
  } as ExecuteMatchRequest;
}

function withdrawRequest(signer: string = OWNER): WithdrawRequest {
  return {
    action: {
      subaccount_id: '15',
      nonce: '7328734720000000',
      module: WITHDRAWAL_MODULE,
      data: encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [WRAPPED_USDC, 1_000_000n]),
      expiry: String(Math.floor(Date.now() / 1000) + 600),
      owner: OWNER,
      signer,
    },
    signature: `0x${'ab'.repeat(65)}`,
  } as WithdrawRequest;
}

async function errorFrom(run: () => Promise<unknown>): Promise<unknown> {
  try {
    await run();
  } catch (error) {
    return error;
  }
  assert.fail('expected a rejection, got none');
}

test('settlement: a non-owner signer is refused at the boundary, before any RPC', async () => {
  const error = await errorFrom(() => executor().then((e) => e.execute(matchRequest(OTHER))));
  assert.ok(error instanceof SignerNotOwnerError, `expected SignerNotOwnerError, got ${String(error)}`);
  assert.equal(error.owner, OWNER);
  assert.equal(error.signer, OTHER);
  assert.equal(error.module, TRADE_MODULE);
});

test('settlement: an owner-signed match is unchanged — it reaches the RPC', async () => {
  // Asserting the failure is the DEAD SOCKET, not merely "not SignerNotOwnerError". An earlier
  // version of this test checked only the latter and passed while the request was dying in
  // encoding, never reaching the RPC at all -- green for a reason that had nothing to do with the
  // guard. Pinning the transport error is what makes this prove the guard let it through.
  const error = await errorFrom(() => executor().then((e) => e.execute(matchRequest(OWNER))));
  assert.ok(!(error instanceof SignerNotOwnerError), `guard rejected owner-signed traffic: ${String(error)}`);
  assert.match(String((error as Error).message), /HTTP request failed/);
});

test('withdrawal: an owner-signed withdrawal is unchanged — it reaches the RPC', async () => {
  const error = await errorFrom(() => executor().then((e) => e.withdraw(withdrawRequest(OWNER))));
  assert.ok(!(error instanceof SignerNotOwnerError), `guard rejected owner-signed traffic: ${String(error)}`);
  // describeSimulationRevert returns undefined for a transport failure, so the original error is
  // rethrown rather than being reported as a withdrawal that would revert.
  assert.ok(!(error instanceof WithdrawalRejectedError), `transport failure misreported as a revert: ${String(error)}`);
  assert.match(String((error as Error).message), /HTTP request failed/);
});

test('withdrawal: a non-owner signer is refused, by the pre-existing policy check', async () => {
  // Documents the overlap rather than hiding it. assertWithdrawalPolicy already rejects
  // signer != owner and runs first, so on this path the boundary guard is a backstop that never
  // fires today. It becomes load-bearing the moment that check is relaxed for a delegated signer,
  // which is exactly when a forgotten path would otherwise open.
  const error = await errorFrom(() => executor().then((e) => e.withdraw(withdrawRequest(OTHER))));
  assert.ok(error instanceof WithdrawalRejectedError, `expected WithdrawalRejectedError, got ${String(error)}`);
  assert.match(error.message, /signer must be action\.owner/);
});
