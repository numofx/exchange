import assert from 'node:assert/strict';
import { test } from 'node:test';

import { custom, encodeAbiParameters, keccak256, parseAbi, toHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import { createChain } from './chain.js';

const abi = parseAbi(['function poke()', 'function value() view returns (uint256)']);
const target = '0x00000000000000000000000000000000000000c1' as Address;

// A load-balanced RPC where the node answering reads is a block behind the one that mined: after the
// relayer's transaction lands in block 10, eth_blockNumber still says 9, a call at "latest" reads the
// state before it, and a call pinned to block 10 is refused once ("header not found") before it is
// answered. The 2026-10-13 sweep-after-mark and pullMark-after-submitData reads, in miniature.
function laggingRpc() {
  const seen: { method: string; block?: string }[] = [];
  let mined = false;
  let pinnedRefusals = 0;
  const word = (v: bigint) => encodeAbiParameters([{ type: 'uint256' }], [v]);
  const request = async ({ method, params }: { method: string; params?: unknown[] }) => {
    const p = (params ?? []) as unknown[];
    switch (method) {
      case 'eth_chainId':
        return toHex(31337);
      case 'eth_getTransactionCount':
        return '0x0';
      case 'eth_gasPrice':
      case 'eth_maxPriorityFeePerGas':
        return '0x1';
      case 'eth_getBlockByNumber':
        return { baseFeePerGas: '0x1', number: mined ? '0xa' : '0x9', timestamp: '0x1', transactions: [], hash: keccak256('0x01') };
      case 'eth_blockNumber':
        seen.push({ method });
        return '0x9'; // the lagging node, behind the receipt's block 10
      case 'eth_estimateGas': {
        const block = p[1] as string | undefined;
        seen.push({ method, block });
        return '0x5208';
      }
      case 'eth_sendRawTransaction':
        mined = true;
        return keccak256('0x02');
      case 'eth_getTransactionReceipt':
        return mined
          ? { status: '0x1', blockNumber: '0xa', blockHash: keccak256('0x03'), transactionHash: keccak256('0x02'), logs: [],
              transactionIndex: '0x0', gasUsed: '0x5208', cumulativeGasUsed: '0x5208', effectiveGasPrice: '0x1', type: '0x2',
              from: '0x0000000000000000000000000000000000000001', to: target, contractAddress: null, logsBloom: `0x${'0'.repeat(512)}` }
          : null;
      case 'eth_call': {
        const block = p[1] as string | undefined;
        seen.push({ method, block });
        if (block === 'latest' || block === undefined) return word(0n); // stale: the state before the transaction
        if (block === '0xa' && pinnedRefusals++ === 0) throw new Error('header not found');
        return word(BigInt(block) >= 10n ? 1n : 0n);
      }
      default:
        throw new Error(`unexpected ${method}`);
    }
  };
  return { transport: custom({ request } as never), seen };
}

test('a read after the relayer\'s own transaction sees it, behind a lagging node', async () => {
  const { transport, seen } = laggingRpc();
  const signer = privateKeyToAccount(keccak256(toHex('signer')) as Hex);
  const chain = createChain(
    { RPC_URL: 'http://unused', CHAIN_ID: 31337, RELAYER_KEY: keccak256(toHex('relayer')), DATA_SUBMITTER: target } as never,
    signer,
    transport,
  );
  // Before any transaction of its own, reads are at latest, as they always were.
  assert.equal(await chain.read<bigint>(target, abi, 'value'), 0n);
  await chain.write(target, abi, 'poke');
  assert.equal(await chain.read<bigint>(target, abi, 'value'), 1n, 'read the post-transaction state, not the lagging node\'s');
  const after = seen.slice(seen.findIndex((s) => s.method === 'eth_blockNumber'));
  assert.ok(after.filter((s) => s.method === 'eth_call').every((s) => s.block === '0xa'), `pinned to block 10: ${JSON.stringify(after)}`);
  // and the next transaction's gas is estimated at block 10 too, not at latest
  await chain.write(target, abi, 'poke');
  const estimates = seen.filter((s) => s.method === 'eth_estimateGas');
  assert.equal(estimates.at(-1)?.block, '0xa', `estimate pinned: ${JSON.stringify(estimates)}`);
});
