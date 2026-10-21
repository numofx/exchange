import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import {
  custom,
  decodeFunctionData,
  encodeAbiParameters,
  encodeEventTopics,
  encodeFunctionResult,
  getAddress,
  keccak256,
  parseAbi,
  toHex,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import { createKeeperChain } from './chain.js';
import { loadConfig, type Config } from './config.js';
import { runOnce } from './keeper.js';

const ENGINE = '0xA19E296021c9DF25b90D96C2A0793CC3D0800758';
const SRM = '0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4';
const base = {
  RPC_URL: 'http://127.0.0.1:1',
  KEEPER_KEY: keccak256(toHex('numo.engine-keeper.test')),
  KEEPER_ACCOUNT: '40',
  SUB_ACCOUNTS: '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843',
  AUCTION: '0xd07176B006cE8246e930d37b8bc44B1154f8c4cE',
  CASH: '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272',
  PERP: '0xC74EfC8B4808803dBCF439E76Fde076d56625b8E',
  SECURITY_MODULE_ACCOUNT: '21',
  START_BLOCK: '100',
};

describe('the manager a keeper liquidates', () => {
  test('SRM alone is still the perp keeper', () => {
    assert.equal(loadConfig({ ...base, SRM }).MANAGER, SRM);
  });
  test('MANAGER names the engine', () => {
    assert.equal(loadConfig({ ...base, MANAGER: ENGINE }).MANAGER, ENGINE);
  });
  test('two that disagree, or none, are refused', () => {
    assert.throws(() => loadConfig({ ...base, MANAGER: ENGINE, SRM }), /disagree/);
    assert.throws(() => loadConfig({ ...base }), /MANAGER \(or SRM\) is required/);
  });
});

// Placeholders: EURC_SPOT.json is not deployed, so these are test addresses, not the escrow or the feed.
const CNGN_ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98';
const EURC_ESCROW = getAddress('0x00000000000000000000000000000000000e0c01');
const EURC_SPOT_FEED = getAddress('0x00000000000000000000000000000000000e0c02');

describe('collateral configuration', () => {
  test('cNGN alone is the one asset it always was: priced at the perp index, its own haircut and limit', () => {
    const config = loadConfig({ ...base, MANAGER: ENGINE, CNGN_ESCROW, MAX_CNGN_INVENTORY: '8000000' });
    assert.deepEqual(config.COLLATERAL, [
      { asset: 'cNGN', escrow: CNGN_ESCROW, price: { kind: 'perpIndex', address: base.PERP }, haircutBps: 1_000n, maxInventory: 8_000_000n * 10n ** 18n },
    ]);
    assert.deepEqual(loadConfig({ ...base, MANAGER: ENGINE }).COLLATERAL, [], 'neither: cash only');
  });

  test('EURC is priced from its spot feed, 2% haircut by default, limit in whole EURC', () => {
    const config = loadConfig({ ...base, MANAGER: ENGINE, CNGN_ESCROW, EURC_ESCROW, EURC_SPOT_FEED, MAX_EURC_INVENTORY: '25000' });
    assert.deepEqual(config.COLLATERAL.map((c) => c.asset), ['cNGN', 'EURC']);
    assert.deepEqual(config.COLLATERAL[1], {
      asset: 'EURC', escrow: EURC_ESCROW, price: { kind: 'spotFeed', address: EURC_SPOT_FEED }, haircutBps: 200n, maxInventory: 25_000n * 10n ** 18n,
    });
    assert.equal(loadConfig({ ...base, MANAGER: ENGINE, EURC_ESCROW, EURC_SPOT_FEED, EURC_HAIRCUT_BPS: '500' }).COLLATERAL[0]!.haircutBps, 500n);
  });

  test('half an EURC setup is refused', () => {
    assert.throws(() => loadConfig({ ...base, MANAGER: ENGINE, EURC_ESCROW }), /EURC_ESCROW and EURC_SPOT_FEED are set together/);
    assert.throws(() => loadConfig({ ...base, MANAGER: ENGINE, EURC_SPOT_FEED }), /EURC_ESCROW and EURC_SPOT_FEED are set together/);
    assert.throws(() => loadConfig({ ...base, MANAGER: ENGINE, MAX_EURC_INVENTORY: '1000' }), /MAX_EURC_INVENTORY is set without EURC_ESCROW/);
    assert.throws(() => loadConfig({ ...base, MANAGER: ENGINE, CNGN_ESCROW, EURC_ESCROW: CNGN_ESCROW, EURC_SPOT_FEED }), /same address/);
  });
});

// A chain where the EURC feed is stale: getSpot reverts, and so does the engine's margin read for the one
// account that holds EURC (#50). #51 holds nothing and is under maintenance; #52 holds cNGN. The keeper's
// funding account #40 holds 300 EURC from an earlier liquidation.
function staleEurcChain() {
  const keeperAddress = privateKeyToAccount(base.KEEPER_KEY).address;
  const abi = parseAbi([
    'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
    'function ownerOf(uint256 accountId) view returns (address)',
    'function manager(uint256 accountId) view returns (address)',
    'function getMarginAndMarkToMarket(uint256 accountId, uint256 scenarioId) view returns (int256 mm, int256 bm, int256 mtm)',
    'function getAuction(uint256 accountId) view returns ((uint256 accountId, uint256 scenarioId, bool insolvent, bool ongoing, uint256 cachedMM, uint256 startTime, uint256 reservedCash))',
    'function startAuction(uint256 accountId, uint256 scenarioId)',
    'function totalInsolventMM() view returns (uint256)',
    'function getCashToStableExchangeRate() view returns (uint256)',
    'function temporaryWithdrawFeeEnabled() view returns (bool)',
    'function getIndexPrice() view returns (uint256, uint256)',
    'function totalPosition(address manager) view returns (uint256)',
    'function totalPositionCap(address manager) view returns (uint256)',
    'function getSpot() view returns (uint256, uint256)',
  ]);
  const E18 = 10n ** 18n;
  const spotReads: string[] = [];
  const balances: Record<string, bigint> = { [`50:${EURC_ESCROW}`]: 1_000n * E18, [`52:${CNGN_ESCROW}`]: 1_000_000n * E18, [`40:${EURC_ESCROW}`]: 300n * E18 };
  const created = [50n, 51n, 52n].map((accountId) => ({
    address: base.SUB_ACCOUNTS, data: '0x', blockNumber: '0x64', transactionHash: keccak256('0x02'), transactionIndex: '0x0',
    blockHash: keccak256('0x03'), logIndex: toHex(Number(accountId)), removed: false,
    topics: encodeEventTopics({
      abi: parseAbi(['event AccountCreated(address indexed owner, uint256 indexed accountId, address indexed manager)']),
      eventName: 'AccountCreated',
      args: { owner: '0x0000000000000000000000000000000000000001', accountId, manager: ENGINE },
    }),
  }));
  const result = (functionName: string, value: unknown) => encodeFunctionResult({ abi, functionName: functionName as never, result: value as never });
  const call = (to: Address, data: Hex): Hex => {
    const { functionName, args } = decodeFunctionData({ abi, data });
    const a = (args ?? []) as readonly unknown[];
    switch (functionName) {
      case 'getBalance': return result(functionName, balances[`${a[0]}:${getAddress(a[1] as string)}`] ?? 0n);
      case 'ownerOf': return result(functionName, keeperAddress);
      case 'manager': return result(functionName, ENGINE);
      case 'getMarginAndMarkToMarket':
        if (a[0] === 50n) throw new Error('execution reverted: CLF_DataTooOld()');
        return result(functionName, a[0] === 51n ? [-1n * E18, -2n * E18, 500n * E18] : [100n * E18, 50n * E18, 1_000n * E18]);
      case 'getAuction': return result(functionName, { accountId: a[0], scenarioId: 0n, insolvent: false, ongoing: false, cachedMM: 0n, startTime: 0n, reservedCash: 0n });
      case 'startAuction': return '0x';
      case 'totalInsolventMM': return result(functionName, 0n);
      case 'getCashToStableExchangeRate': return result(functionName, E18);
      case 'temporaryWithdrawFeeEnabled': return result(functionName, false);
      case 'getIndexPrice': return result(functionName, [72n * E18 / 100_000n, E18]);
      case 'totalPosition': return result(functionName, 0n);
      case 'totalPositionCap': return result(functionName, 50_000_000n * E18);
      case 'getSpot':
        spotReads.push(to);
        throw new Error('execution reverted: CLF_DataTooOld()');
      default: throw new Error(`unexpected ${functionName}`);
    }
  };
  const request = async ({ method, params }: { method: string; params?: unknown[] }) => {
    const p = (params ?? []) as Record<string, unknown>[];
    switch (method) {
      case 'eth_chainId': return toHex(31337);
      case 'eth_blockNumber': return toHex(1_000n);
      case 'eth_getBalance': return toHex(E18);
      case 'eth_getLogs': {
        // Only the AccountCreated query (topic0 = AccountCreated) has entries; the manager moves have none.
        const topic0 = (p[0].topics as Hex[] | undefined)?.[0];
        return topic0 === created[0]!.topics[0] ? created : [];
      }
      case 'eth_call': return call(getAddress(p[0].to as string), p[0].data as Hex);
      default: throw new Error(`unexpected ${method}`);
    }
  };
  // No retries: each revert is one logical read, so spotReads counts reads, not transport attempts.
  return { transport: custom({ request } as never, { retryCount: 0 }), spotReads };
}

describe('a stale EURC feed', () => {
  const config = () =>
    loadConfig({ ...base, MANAGER: ENGINE, CHAIN_ID: '31337', START_BLOCK: '900', CNGN_ESCROW, EURC_ESCROW, EURC_SPOT_FEED, MAX_EURC_INVENTORY: '250' });

  test('holds back only the account holding EURC, with a note and an alert, and the pass goes on', async () => {
    const { transport, spotReads } = staleEurcChain();
    const alerts: { key: string; message: string }[] = [];
    const actions = await runOnce(config(), createKeeperChain(config(), transport), async (key, message) => void alerts.push({ key, message }));
    assert.deepEqual(actions, [
      { kind: 'none', accountId: 50n, note: 'cannot price EURC (feed unreadable, stale?): no bid' },
      { kind: 'start', accountId: 51n },
      { kind: 'none', accountId: 52n },
    ]);
    assert.deepEqual(spotReads, [EURC_SPOT_FEED], 'the feed is read for the EURC holder only');
    const keys = alerts.map((a) => a.key);
    assert.ok(keys.includes('collateral-unpriced-EURC'), `alerted: ${keys}`);
    assert.ok(!keys.includes('margin-unreadable'), 'not reported as an unreadable margin');
    // The keeper's 300 EURC is over its 250 limit: the per-asset health alert fires under EURC's key.
    assert.ok(keys.includes('keeper-eurc-over-limit'), `health: ${keys}`);
  });

  test('an account whose margin is unreadable for any other reason is still margin-unreadable', async () => {
    const { transport } = staleEurcChain();
    // Without EURC configured, #50's revert is an ordinary unreadable margin, as it always was.
    const cngnOnly = loadConfig({ ...base, MANAGER: ENGINE, CHAIN_ID: '31337', START_BLOCK: '900', CNGN_ESCROW });
    const alerts: string[] = [];
    const actions = await runOnce(cngnOnly, createKeeperChain(cngnOnly, transport), async (key) => void alerts.push(key));
    assert.deepEqual(actions.map((a) => a.accountId), [51n, 52n]);
    assert.ok(alerts.includes('margin-unreadable'));
    assert.ok(!alerts.some((k) => k.startsWith('keeper-eurc')), 'no EURC alerts when EURC is not configured');
  });
});

// A load-balanced RPC whose read node lags: eth_blockNumber answers HEAD, a call at "latest" reads the state
// before the keeper's own transaction, and a call pinned to the receipt's block is refused once ("header not
// found") before it is answered. Logs are answered for any range, and every requested range is recorded.
function rpc(head: bigint) {
  const ranges: { from: bigint; to: bigint }[] = [];
  const calls: { block?: string }[] = [];
  let mined = false;
  let refusals = 0;
  const createdTopics = encodeEventTopics({
    abi: parseAbi(['event AccountCreated(address indexed owner, uint256 indexed accountId, address indexed manager)']),
    eventName: 'AccountCreated',
    args: { owner: '0x0000000000000000000000000000000000000001', accountId: 77n, manager: ENGINE },
  });
  const receipt = (block: string) => ({
    status: '0x1', blockNumber: block, blockHash: keccak256('0x03'), transactionHash: keccak256('0x02'), transactionIndex: '0x0',
    gasUsed: '0x5208', cumulativeGasUsed: '0x5208', effectiveGasPrice: '0x1', type: '0x2', contractAddress: null,
    from: '0x0000000000000000000000000000000000000001', to: base.SUB_ACCOUNTS, logsBloom: `0x${'0'.repeat(512)}`,
    logs: [{ address: base.SUB_ACCOUNTS, topics: createdTopics, data: '0x', blockNumber: block, transactionHash: keccak256('0x02'),
             transactionIndex: '0x0', blockHash: keccak256('0x03'), logIndex: '0x0', removed: false }],
  });
  const request = async ({ method, params }: { method: string; params?: unknown[] }) => {
    const p = (params ?? []) as Record<string, unknown>[];
    switch (method) {
      case 'eth_chainId': return toHex(31337);
      case 'eth_blockNumber': return toHex(head);
      case 'eth_getLogs':
        ranges.push({ from: BigInt(p[0].fromBlock as string), to: BigInt(p[0].toBlock as string) });
        return [];
      case 'eth_getTransactionCount': return '0x0';
      case 'eth_gasPrice': case 'eth_maxPriorityFeePerGas': return '0x1';
      case 'eth_getBlockByNumber': return { baseFeePerGas: '0x1', number: toHex(head), timestamp: '0x1', transactions: [], hash: keccak256('0x01') };
      case 'eth_estimateGas': return '0x5208';
      case 'eth_sendRawTransaction': mined = true; return keccak256('0x02');
      case 'eth_getTransactionReceipt': return mined ? receipt(toHex(head + 5n)) : null;
      case 'eth_call': {
        const block = (params as unknown[])[1] as string | undefined;
        calls.push({ block });
        if (block === 'latest' || block === undefined) return encodeAbiParameters([{ type: 'int256' }], [0n]); // stale
        if (BigInt(block) === head + 5n && refusals++ === 0) throw new Error('header not found');
        return encodeAbiParameters([{ type: 'int256' }], [BigInt(block) >= head + 5n ? 1_000n * 10n ** 18n : 0n]);
      }
      default: throw new Error(`unexpected ${method}`);
    }
  };
  return { transport: custom({ request } as never), ranges, calls };
}

describe('the keeper behind a load-balanced RPC', () => {
  test('account discovery never scans the last SCAN_CONFIRMATIONS blocks', async () => {
    const { transport, ranges } = rpc(1_000n);
    const config: Config = loadConfig({ ...base, MANAGER: ENGINE, CHAIN_ID: '31337', START_BLOCK: '900' });
    await createKeeperChain(config, transport).discoverAccounts();
    assert.ok(ranges.length > 0, 'it scanned');
    assert.equal(ranges.at(-1)!.to, 997n, 'up to head - 3, where a lagging node already has the logs');
  });

  test('cash read after its own funding transfer is the new balance, not the lagging node\'s', async () => {
    const { transport, calls } = rpc(1_000n);
    const config: Config = loadConfig({ ...base, MANAGER: ENGINE, CHAIN_ID: '31337' });
    const chain = createKeeperChain(config, transport);
    assert.equal(await chain.keeperCash(), 0n, 'before any transaction of its own: latest, as before');
    await chain.createBidAccount(10n ** 18n);
    assert.equal(await chain.keeperCash(), 1_000n * 10n ** 18n, 'read at the receipt\'s block');
    assert.equal(calls.at(-1)!.block, toHex(1_005n));
  });
});

export type { Address };
