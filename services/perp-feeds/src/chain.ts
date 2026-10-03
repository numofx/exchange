import {
  defineChain,
  createPublicClient,
  createWalletClient,
  http,
  nonceManager,
  parseAbi,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount, type LocalAccount } from 'viem/accounts';
import { base } from 'viem/chains';

import type { Config } from './config.js';

const feedAbi = parseAbi([
  'function getSpot() view returns (uint256, uint256)',
  'function getResult() view returns (uint256, uint256)',
  'function spotDiffDetails() view returns (int96 spotDiff, uint64 confidence, uint64 timestamp)',
]);
const submitterAbi = parseAbi(['function submitData(bytes managerData)']);

export type Chain = {
  signer: LocalAccount;
  relayer: LocalAccount;
  chainId: number;
  /** Head block timestamp, seconds. Feed timestamps are signed against this, not the local clock. */
  headTimestamp(): Promise<bigint>;
  /** The index as the chain holds it, or null when it is unset or stale (getSpot reverts). */
  readIndex(feed: Address): Promise<bigint | null>;
  /** A diff feed's result and the timestamp of its last accepted update, or null if unreadable. */
  readDiffFeed(feed: Address): Promise<{ result: bigint; updatedAt: bigint } | null>;
  submit(managerData: Hex): Promise<Hex>;
};

/**
 * Runs the tasks it is given one at a time, in order, each starting after the previous has settled.
 * The index and mark publishers tick on their own intervals and both pay gas from the one relayer;
 * two transactions sent in the same instant take the same nonce and the node drops the second as an
 * underpriced replacement. On 1-minute index publishes the ticks coincide every minute, and that is
 * what let the mark feed run past its heartbeat on 2026-10-03. Queueing the submissions behind one
 * another (each waits for its receipt) means they never share a nonce.
 */
export function serialized(): <T>(task: () => Promise<T>) => Promise<T> {
  let tail: Promise<unknown> = Promise.resolve();
  return (task) => {
    const run = tail.then(task, task);
    // A failure must not jam the queue: the next task starts whether this one settled or threw.
    tail = run.catch(() => undefined);
    return run;
  };
}

export function createChain(config: Config): Chain {
  const submitOneAtATime = serialized();
  const transport = http(config.RPC_URL);
  // Base in production; any other id (a local anvil, a fork) gets a minimal definition so the
  // relayer's transactions are signed for the chain actually behind RPC_URL.
  const chain =
    config.CHAIN_ID === base.id
      ? base
      : defineChain({
          id: config.CHAIN_ID,
          name: `chain-${config.CHAIN_ID}`,
          nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
          rpcUrls: { default: { http: [config.RPC_URL] } },
        });
  const publicClient = createPublicClient({ chain, transport });
  // The relayer tracks its own nonce. Submissions are already queued one behind another, but a
  // load-balanced RPC can answer the next nonce query from a node that has not yet seen the
  // transaction just mined, which hands out the nonce again and the node refuses the "replacement"
  // as underpriced (what kept failing the mark publish on 2026-10-03). viem's manager never returns
  // a nonce at or below the last one it issued, and forgets it when a send fails, so no gap is left.
  const relayer = privateKeyToAccount(config.RELAYER_KEY as Hex, { nonceManager });
  const wallet = createWalletClient({ account: relayer, chain, transport });

  return {
    signer: privateKeyToAccount(config.FEED_SIGNER_KEY as Hex),
    relayer,
    chainId: config.CHAIN_ID,
    async headTimestamp() {
      const block = await publicClient.getBlock({ blockTag: 'latest' });
      return block.timestamp;
    },
    async readIndex(feed) {
      try {
        const [price] = await publicClient.readContract({ address: feed, abi: feedAbi, functionName: 'getSpot' });
        return price;
      } catch {
        return null;
      }
    },
    async readDiffFeed(feed) {
      try {
        const [[result], details] = await Promise.all([
          publicClient.readContract({ address: feed, abi: feedAbi, functionName: 'getResult' }),
          publicClient.readContract({ address: feed, abi: feedAbi, functionName: 'spotDiffDetails' }),
        ]);
        return { result, updatedAt: details[2] };
      } catch {
        return null;
      }
    },
    submit(managerData) {
      return submitOneAtATime(async () => {
        const hash = await wallet.writeContract({
          account: relayer,
          chain,
          address: config.DATA_SUBMITTER,
          abi: submitterAbi,
          functionName: 'submitData',
          args: [managerData],
        });
        const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
        if (receipt.status !== 'success') throw new Error(`submitData reverted: ${hash}`);
        return hash;
      });
    },
  };
}
