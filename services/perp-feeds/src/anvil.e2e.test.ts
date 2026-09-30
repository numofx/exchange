/**
 * The publishers against the REAL feed contracts, deployed from risk-core's compiled artifacts onto
 * a local anvil. The unit tests prove the decisions; this proves the chain accepts what the service
 * signs and encodes, which no amount of agreeing with our own TypeScript can.
 *
 *   anvil --port 8599 &
 *   (cd ../../contracts/risk-core && forge build)
 *   ANVIL_RPC_URL=http://127.0.0.1:8599 pnpm test
 *
 * Skipped without ANVIL_RPC_URL.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { before, describe, it } from 'node:test';

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  keccak256,
  parseAbi,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { RateProvider } from 'cngn-rate-picker';

import { createChain } from './chain.js';
import { loadConfig } from './config.js';
import { IndexPublisher } from './index-publisher.js';
import { MarkPublisher } from './mark-publisher.js';
import type { RestingOrder } from './mark-targets.js';

const RPC = process.env.ANVIL_RPC_URL;
const ARTIFACTS = join(import.meta.dirname, '../../../contracts/risk-core/out');
// anvil's first default account: deploys, and relays.
const DEPLOYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' as Hex;
const SIGNER_KEY = keccak256(toHex('numo.perp-feeds.e2e.signer'));

const ownerAbi = parseAbi([
  'function addSigner(address signer, bool isSigner)',
  'function setHeartbeat(uint64 heartbeat)',
  'function setSpotDiffCap(uint256 cap)',
  'function getSpot() view returns (uint256, uint256)',
  'function getResult() view returns (uint256, uint256)',
]);

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const json = JSON.parse(readFileSync(join(ARTIFACTS, file, `${name}.json`), 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

describe('publishers against real feed contracts on anvil', { skip: !RPC }, () => {
  const chain = defineChain({
    id: 31337,
    name: 'anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC ?? ''] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(RPC) });
  const deployer = privateKeyToAccount(DEPLOYER_KEY);
  const wallet = createWalletClient({ account: deployer, chain, transport: http(RPC) });
  const signer = privateKeyToAccount(SIGNER_KEY);
  const feeds: Record<'submitter' | 'index' | 'mark' | 'ask' | 'bid', Address> = {} as never;

  async function deploy(file: string, name: string, args: unknown[] = []): Promise<Address> {
    const { abi, bytecode } = artifact(file, name);
    const hash = await wallet.deployContract({ abi, bytecode, args });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    return receipt.contractAddress!;
  }

  async function send(address: Address, functionName: 'addSigner' | 'setHeartbeat' | 'setSpotDiffCap', args: unknown[]) {
    const hash = await wallet.writeContract({ address, abi: ownerAbi, functionName, args: args as never });
    await publicClient.waitForTransactionReceipt({ hash });
  }

  function config(overrides: Record<string, string> = {}) {
    return loadConfig({
      RPC_URL: RPC!,
      CHAIN_ID: '31337',
      FEED_SIGNER_KEY: SIGNER_KEY,
      RELAYER_KEY: DEPLOYER_KEY,
      DATA_SUBMITTER: feeds.submitter,
      PERP_ASSET: '0x000000000000000000000000000000000000dEaD',
      INDEX_FEED: feeds.index,
      MARK_FEED: feeds.mark,
      IMPACT_ASK_FEED: feeds.ask,
      IMPACT_BID_FEED: feeds.bid,
      INDEX_STATE_FILE: join(tmpdir(), `perp-index-${Date.now()}-${Math.random()}.json`),
      INDEX_MIN_WINDOW_SAMPLES: '3',
      ...overrides,
    });
  }

  function fixedProviders(ngnPerUsdt: number[]): RateProvider[] {
    return ngnPerUsdt.map((price, i) => ({
      name: `fixed-${i}`,
      asset: 'USDT',
      getPriceInNgn: async () => ({ price }),
    }));
  }

  before(async () => {
    feeds.submitter = await deploy('OracleDataSubmitter.sol', 'OracleDataSubmitter');
    feeds.index = await deploy('LyraSpotFeed.sol', 'LyraSpotFeed');
    feeds.mark = await deploy('LyraSpotDiffFeed.sol', 'LyraSpotDiffFeed', [feeds.index]);
    feeds.ask = await deploy('LyraSpotDiffFeed.sol', 'LyraSpotDiffFeed', [feeds.index]);
    feeds.bid = await deploy('LyraSpotDiffFeed.sol', 'LyraSpotDiffFeed', [feeds.index]);
    for (const feed of [feeds.index, feeds.mark, feeds.ask, feeds.bid]) {
      await send(feed, 'addSigner', [signer.address, true]);
      await send(feed, 'setHeartbeat', [1200n]);
    }
    for (const feed of [feeds.mark, feeds.ask, feeds.bid]) {
      await send(feed, 'setSpotDiffCap', [60_000_000_000_000_000n]);
    }
    // Feed timestamps are signed TIMESTAMP_SAFETY_SEC behind the head; start the chain past that.
    await publicClient.request({ method: 'evm_increaseTime' as never, params: [60] as never });
    await publicClient.request({ method: 'evm_mine' as never, params: [] as never });
  });

  it('publishes an index the LyraSpotFeed accepts, inverted to USDC per cNGN', async () => {
    const cfg = config();
    const clock = { now: Date.now() };
    const publisher = new IndexPublisher(cfg, createChain(cfg), fixedProviders([1374, 1372, 1376]), async () => {}, () => clock.now);
    for (let i = 0; i < 3; i++) {
      await publisher.sample();
      clock.now += 60_000;
    }
    await publisher.publish();

    const [price] = (await publicClient.readContract({ address: feeds.index, abi: ownerAbi, functionName: 'getSpot' })) as [bigint, bigint];
    assert.equal(price, 10n ** 36n / 1374_000_000_000_000_000_000n, 'index = 1 / median(1374) at 18dp');
  });

  it('refuses to publish when the sources disagree, leaving the chain untouched', async () => {
    const cfg = config();
    const before = await publicClient.readContract({ address: feeds.index, abi: ownerAbi, functionName: 'getSpot' });
    const publisher = new IndexPublisher(cfg, createChain(cfg), fixedProviders([1374, 1372, 1500]), async () => {}, () => Date.now());
    for (let i = 0; i < 3; i++) await publisher.sample();
    await publisher.publish();
    const after = await publicClient.readContract({ address: feeds.index, abi: ownerAbi, functionName: 'getSpot' });
    assert.deepEqual(after, before);
  });

  it('publishes mark and impacts the LyraSpotDiffFeeds accept, from a book', async () => {
    const cfg = config();
    const [index] = (await publicClient.readContract({ address: feeds.index, abi: ownerAbi, functionName: 'getSpot' })) as [bigint, bigint];
    const E18 = 10n ** 18n;
    const at = (bps: bigint) => (index * (10_000n + bps)) / 10_000n;
    const book: RestingOrder[] = [
      { side: 'buy', price: at(-20n), remaining: (5_000n * E18 * E18) / at(-20n) },
      { side: 'sell', price: at(40n), remaining: (5_000n * E18 * E18) / at(40n) },
    ];
    await new MarkPublisher(cfg, createChain(cfg), async () => {}, async () => book).publish();

    const read = async (address: Address) =>
      ((await publicClient.readContract({ address, abi: ownerAbi, functionName: 'getResult' })) as [bigint, bigint])[0];
    assert.equal(await read(feeds.mark), (at(-20n) + at(40n)) / 2n, 'mark = book mid');
    assert.ok((await read(feeds.ask)) <= at(40n) && (await read(feeds.ask)) >= at(40n) - 1n, 'impact ask = ask depth');
    assert.ok((await read(feeds.bid)) <= at(-20n) && (await read(feeds.bid)) >= at(-20n) - 1n, 'impact bid = bid depth');
  });
});
