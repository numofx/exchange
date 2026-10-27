/**
 * The forward publisher in v2 mode against the REAL v2 contracts, deployed from risk-core's compiled
 * artifacts onto a local anvil: per series a LyraSpotFeed index, a LyraForwardFeed on it, a v2
 * FutureAsset (src/assets/FutureAsset.sol: USDC per unit of the base, a contract of the base, nothing
 * inverted) reading both, and the OracleDataSubmitter. The v1 suite (forward.anvil.e2e.test.ts) keeps
 * FutureAssetV1 until USDC-cNGN-30NOV26 settles.
 *
 * Two series, the same code and only config apart: cNGN (0.000724 USDC per cNGN, a 1,000,000 cNGN
 * contract, 11.8% carry: a forward discount, a negative diff) and EURC (1.1625 USDC per EURC, a 1,000
 * EURC contract, -1.5% carry: a forward premium, a positive diff).
 *
 *   anvil --port 8599 &
 *   (cd ../../contracts/risk-core && forge build)
 *   ANVIL_RPC_URL=http://127.0.0.1:8599 pnpm test
 *
 * Skipped without ANVIL_RPC_URL. Shares the chain clock with the other anvil suites, so test files run
 * one at a time (forward.anvil.e2e.test.ts says why).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

import { createChain } from './chain.js';
import { encodeManagerData, encodeSpotData, signFeedUpdate } from './feed-data.js';
import { loadForwardConfig } from './forward-config.js';
import { futureAbi, ForwardPublisher } from './forward-publisher.js';
import { discountForward, ONE } from './forward-targets.js';
import type { RestingOrder } from './mark-targets.js';

const RPC = process.env.ANVIL_RPC_URL;
const ARTIFACTS = join(import.meta.dirname, '../../../contracts/risk-core/out');
// anvil's fifth default account: each anvil suite deploys and relays from its own
const DEPLOYER_KEY = '0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a' as Hex;
const INDEX_SIGNER_KEY = keccak256(toHex('numo.future-feeds-v2.e2e.index-signer'));
const FORWARD_SIGNER_KEY = keccak256(toHex('numo.future-feeds-v2.e2e.forward-signer'));

const adminAbi = parseAbi([
  'function addSigner(address signer, bool isSigner)',
  'function setHeartbeat(uint64 heartbeat)',
  'function setIndexParams(address indexFeed, uint256 maxDev, uint256 minDev, uint256 narrowing, uint256 window, uint256 gap, uint256 fallbackDelay)',
  'function setMarkBounds(uint256 maxMarkDeviation, uint256 maxMarkDelay)',
  'function setForwardFeed(address forwardFeed, uint256 minMarkInterval)',
  'function setContract(uint64 expiry, uint64 lastTradeTime, uint256 initialMarkPrice) returns (uint96)',
]);
const forwardFeedAbi = parseAbi(['function getForwardPrice(uint64 expiry) view returns (uint256, uint256)']);

type Series = { base: string; indexUsdc: bigint; contractSize: bigint; carry: bigint };

const SERIES: Series[] = [
  { base: 'cNGN', indexUsdc: 724_089_970_981_047n, contractSize: 1_000_000n * ONE, carry: (118n * ONE) / 1000n },
  { base: 'EURC', indexUsdc: 1_162_500_000_000_000_000n, contractSize: 1_000n * ONE, carry: -(15n * ONE) / 1000n },
];

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const json = JSON.parse(readFileSync(join(ARTIFACTS, file, `${name}.json`), 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

describe('v2 forward publisher against real contracts on anvil', { skip: !RPC }, () => {
  const chain = defineChain({
    id: 31337,
    name: 'anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC ?? ''] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(RPC) });
  const deployer = privateKeyToAccount(DEPLOYER_KEY);
  const wallet = createWalletClient({ account: deployer, chain, transport: http(RPC) });
  let submitter: Address;
  let subAccounts: Address;

  async function deploy(file: string, name: string, args: unknown[] = []): Promise<Address> {
    const { abi, bytecode } = artifact(file, name);
    const hash = await wallet.deployContract({ abi, bytecode, args });
    return (await publicClient.waitForTransactionReceipt({ hash })).contractAddress!;
  }

  async function send(address: Address, functionName: string, args: unknown[]) {
    const hash = await wallet.writeContract({ address, abi: adminAbi, functionName, args } as never);
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, 'success', `${functionName} reverted`);
  }

  async function advance(seconds: number) {
    await publicClient.request({ method: 'evm_increaseTime' as never, params: [seconds] as never });
    await publicClient.request({ method: 'evm_mine' as never, params: [] as never });
  }

  async function head(): Promise<bigint> {
    return (await publicClient.getBlock({ blockTag: 'latest' })).timestamp;
  }

  before(async () => {
    submitter = await deploy('OracleDataSubmitter.sol', 'OracleDataSubmitter');
    subAccounts = await deploy('SubAccounts.sol', 'SubAccounts', ['Accounts', 'ACC']);
  });

  for (const series of SERIES) {
    describe(`${series.base}-<expiry>`, () => {
      const at: Record<'index' | 'forward' | 'future', Address> = {} as never;
      let expiry: bigint;

      async function publishIndex() {
        const indexChain = createChain({ RPC_URL: RPC!, CHAIN_ID: 31337, RELAYER_KEY: DEPLOYER_KEY, DATA_SUBMITTER: submitter, FEED_SIGNER_KEY: INDEX_SIGNER_KEY });
        const now = await head();
        const update = await signFeedUpdate({
          signer: indexChain.signer,
          kind: 'LyraSpotFeed',
          feed: at.index,
          chainId: 31337,
          data: encodeSpotData(series.indexUsdc),
          timestamp: now - 1n,
          deadline: now + 60n,
        });
        await indexChain.submit(encodeManagerData([update]));
      }

      function config(overrides: Record<string, string> = {}) {
        return loadForwardConfig({
          RPC_URL: RPC!,
          CHAIN_ID: '31337',
          RELAYER_KEY: DEPLOYER_KEY,
          FORWARD_SIGNER_KEY,
          FUTURE_VERSION: 'v2',
          BASE_SYMBOL: series.base,
          DATA_SUBMITTER: submitter,
          INDEX_FEED: at.index,
          FORWARD_FEED: at.forward,
          FUTURE_ASSET: at.future,
          // no engine here: the deficit cover is not exercised
          FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
          FUTURE_SUB_ID: String(expiry),
          CARRY: String(series.carry),
          TIMESTAMP_SAFETY_SEC: '1',
          ...overrides,
        });
      }

      async function contract() {
        return (await publicClient.readContract({ address: at.future, abi: futureAbi, functionName: 'futureContracts', args: [expiry] })) as {
          markPrice: bigint;
          lastMarkTime: bigint;
        };
      }

      function publisher(cfg = config(), book: RestingOrder[] = [], alerts: string[] = [], key = FORWARD_SIGNER_KEY) {
        return new ForwardPublisher(cfg, createChain(cfg, privateKeyToAccount(key)), async (k) => void alerts.push(k), async () => book);
      }

      before(async () => {
        at.index = await deploy('LyraSpotFeed.sol', 'LyraSpotFeed');
        at.forward = await deploy('LyraForwardFeed.sol', 'LyraForwardFeed', [at.index]);
        at.future = await deploy('FutureAsset.sol', 'FutureAsset', [subAccounts, series.contractSize]);

        await send(at.index, 'addSigner', [privateKeyToAccount(INDEX_SIGNER_KEY).address, true]);
        await send(at.index, 'setHeartbeat', [86_400n]);
        await send(at.forward, 'addSigner', [privateKeyToAccount(FORWARD_SIGNER_KEY).address, true]);
        await send(at.forward, 'setHeartbeat', [7_200n]);

        await advance(2);
        await publishIndex();

        const now = await head();
        expiry = now + 30n * 86_400n;
        await send(at.future, 'setIndexParams', [at.index, ONE / 10n, ONE / 100n, 14n * 86_400n, 3_600n, 900n, 86_400n]);
        await send(at.future, 'setMarkBounds', [ONE / 20n, 600n]);
        await send(at.future, 'setForwardFeed', [at.forward, 1n]);
        // listed at index / (1 + carry * tau), as deploy-margin-engine-v2.s.sol requires
        await send(at.future, 'setContract', [expiry, expiry - 3_600n, discountForward(series.indexUsdc, series.carry, expiry - now)]);
      });

      it('passes the startup units check, which refuses the same contract run as v1', async () => {
        await publisher().checkUnits();
        await assert.rejects(() => publisher(config({ FUTURE_VERSION: 'v1', CARRY: '0' })).checkUnits(), /FUTURE_VERSION=v1 does not match/);
      });

      it('signs index + diff the feed accepts, and pullMark reads it as is: the carry forward', async () => {
        await advance(2);
        const before = await contract();
        assert.equal(await publisher().tick(), 'published');

        const after = await contract();
        assert.ok(after.lastMarkTime > before.lastMarkTime, 'a new mark landed');
        const expected = discountForward(series.indexUsdc, series.carry, expiry - after.lastMarkTime);
        const error = after.markPrice > expected ? after.markPrice - expected : expected - after.markPrice;
        // tau moves by the seconds between the publisher's head and the pull's block
        assert.ok(error * 10n ** 6n <= expected, `mark ${after.markPrice} vs carry forward ${expected}`);
        // the feed holds the forward itself, in the future's units: below the index for cNGN, above it for EURC
        const [forward] = await publicClient.readContract({ address: at.forward, abi: forwardFeedAbi, functionName: 'getForwardPrice', args: [expiry] });
        assert.equal(forward, after.markPrice);
        assert.equal(forward < series.indexUsdc, series.carry > 0n, `forward ${forward} vs index ${series.indexUsdc}`);
      });

      it('marks to a book whose sides each fill the depth, valuing a contract at contractSize x price', async () => {
        await advance(2);
        const fair = discountForward(series.indexUsdc, series.carry, expiry - (await head()));
        const step = fair / 1000n; // 10 bps
        // contracts (18dp) worth 3,000 USDC at the fair price: over the 2,000 depth, and well under it read as v1's USDC contracts
        const contracts = (3_000n * ONE * ONE) / ((series.contractSize * fair) / ONE);
        const book: RestingOrder[] = [
          { side: 'buy', price: fair - step, remaining: contracts },
          { side: 'sell', price: fair + 3n * step, remaining: contracts },
        ];
        assert.equal(await publisher(config(), book).tick(), 'published');
        const { markPrice } = await contract();
        const mid = fair + step;
        const error = markPrice > mid ? markPrice - mid : mid - markPrice;
        assert.ok(error * 10n ** 5n <= mid, `mark ${markPrice} vs book mid ${mid}`);
      });

      it('refuses a forward signed by any other key: the feed rejects it and the mark does not move', async () => {
        await advance(2);
        const before = await contract();
        const alerts: string[] = [];
        const cfg = config({ FORWARD_SIGNER_KEY: INDEX_SIGNER_KEY });
        assert.equal(await publisher(cfg, [], alerts, INDEX_SIGNER_KEY).tick(), 'pull-failed');
        assert.ok(alerts.includes('forward-pull-failed'));
        assert.equal((await contract()).lastMarkTime, before.lastMarkTime, 'no mark landed');
      });
    });
  }
});
