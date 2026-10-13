import {
  defineChain,
  createPublicClient,
  createWalletClient,
  http,
  nonceManager,
  parseAbi,
  type Abi,
  type Address,
  type Hex,
  type Transport,
} from 'viem';
import { privateKeyToAccount, type LocalAccount } from 'viem/accounts';
import { base } from 'viem/chains';

import type { Config } from './config.js';
import { readAtOrAfter } from './pinned-read.js';

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

/** Chain plus arbitrary contract reads and relayer writes, which the forward publisher needs. */
export type ContractChain = Chain & {
  /** A view call. */
  read<T>(address: Address, abi: Abi, functionName: string, args?: readonly unknown[]): Promise<T>;
  /** A transaction from the relayer, queued behind every other submission, awaited to its receipt. */
  write(address: Address, abi: Abi, functionName: string, args?: readonly unknown[]): Promise<Hex>;
};

/** What createChain reads. FEED_SIGNER_KEY is only needed when no signer account is passed in. */
export type ChainConfig = Pick<Config, 'RPC_URL' | 'CHAIN_ID' | 'RELAYER_KEY' | 'DATA_SUBMITTER'> & {
  FEED_SIGNER_KEY?: string;
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

/**
 * @param signer The feed signer. Omitted, it is FEED_SIGNER_KEY; the forward publisher passes a KMS
 *   account instead, so its key never enters the process.
 */
export function createChain(config: ChainConfig, signer?: LocalAccount, transportOverride?: Transport): ContractChain {
  if (!signer && !config.FEED_SIGNER_KEY) throw new Error('createChain needs a signer or FEED_SIGNER_KEY');
  const submitOneAtATime = serialized();
  const transport = transportOverride ?? http(config.RPC_URL);
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

  // The highest block a transaction of this process has landed in. The RPC is load-balanced: the node
  // that returned a receipt is not always the one that answers next, and one behind it reads the state
  // before the transaction (the VM sweep straight after a mark, pullMark's estimate straight after
  // submitData). Every read and every estimate is at an explicit block no older than this: a node that
  // has the block answers with it, one that has not refuses it and is retried (readAtOrAfter).
  let landed = 0n;
  const noteLanded = (block: bigint) => {
    if (block > landed) landed = block;
  };
  /** The block to read at: the head, or the last landed block if the answering node is behind it. */
  const readBlock = async (): Promise<bigint | undefined> => {
    if (landed === 0n) return undefined;
    const head = await publicClient.getBlockNumber({ cacheTime: 0 });
    return head > landed ? head : landed;
  };
  const pinned = async <T>(read: (at: { blockNumber?: bigint }) => Promise<T>): Promise<T> => readAtOrAfter(await readBlock(), read);
  /** Gas for a relayer transaction, estimated at the read block, with a fifth on top. */
  const gasFor = async (request: { address: Address; abi: Abi; functionName: string; args: readonly unknown[] }) => {
    const estimate = await pinned((at) =>
      publicClient.estimateContractGas({ account: relayer, ...request, ...at } as never),
    );
    return (estimate * 6n) / 5n;
  };

  return {
    signer: signer ?? privateKeyToAccount(config.FEED_SIGNER_KEY as Hex),
    relayer,
    chainId: config.CHAIN_ID,
    async headTimestamp() {
      const block = await publicClient.getBlock({ blockTag: 'latest' });
      return block.timestamp;
    },
    async readIndex(feed) {
      try {
        const [price] = await pinned((at) => publicClient.readContract({ address: feed, abi: feedAbi, functionName: 'getSpot', ...at }));
        return price;
      } catch {
        return null;
      }
    },
    async readDiffFeed(feed) {
      try {
        const at = await readBlock();
        const [[result], details] = await Promise.all([
          readAtOrAfter(at, (b) => publicClient.readContract({ address: feed, abi: feedAbi, functionName: 'getResult', ...b })),
          readAtOrAfter(at, (b) => publicClient.readContract({ address: feed, abi: feedAbi, functionName: 'spotDiffDetails', ...b })),
        ]);
        return { result, updatedAt: details[2] };
      } catch {
        return null;
      }
    },
    read<T>(address: Address, abi: Abi, functionName: string, args: readonly unknown[] = []) {
      return pinned((at) => publicClient.readContract({ address, abi, functionName, args, ...at } as never) as Promise<T>);
    },
    write(address, abi, functionName, args = []) {
      return submitOneAtATime(async () => {
        const gas = await gasFor({ address, abi, functionName, args });
        const hash = await wallet.writeContract({ account: relayer, chain, address, abi, functionName, args, gas } as never);
        const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
        if (receipt.status !== 'success') throw new Error(`${functionName} reverted: ${hash}`);
        noteLanded(receipt.blockNumber);
        return hash;
      });
    },
    submit(managerData) {
      return submitOneAtATime(async () => {
        const request = { address: config.DATA_SUBMITTER, abi: submitterAbi as Abi, functionName: 'submitData', args: [managerData] };
        const gas = await gasFor(request);
        const hash = await wallet.writeContract({
          account: relayer,
          chain,
          address: config.DATA_SUBMITTER,
          abi: submitterAbi,
          functionName: 'submitData',
          args: [managerData],
          gas,
        });
        const receipt = await publicClient.waitForTransactionReceipt({ hash, timeout: 60_000 });
        if (receipt.status !== 'success') throw new Error(`submitData reverted: ${hash}`);
        noteLanded(receipt.blockNumber);
        return hash;
      });
    },
  };
}
