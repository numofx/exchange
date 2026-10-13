import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { custom, encodeAbiParameters, encodeEventTopics, keccak256, parseAbi, toHex, type Address } from 'viem';

import { createKeeperChain } from './chain.js';
import { loadConfig, type Config } from './config.js';

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
