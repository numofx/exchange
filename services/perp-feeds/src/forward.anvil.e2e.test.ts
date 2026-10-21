/**
 * The forward publisher against the REAL contracts, deployed from risk-core's compiled artifacts onto
 * a local anvil: a LyraSpotFeed index, a LyraForwardFeed on it, a FutureAsset reading both, and the
 * OracleDataSubmitter. It proves the chain accepts what the publisher signs and encodes, and that
 * FutureAsset.pullMark turns it into the mark the publisher meant.
 *
 *   anvil --port 8599 &
 *   (cd ../../contracts/risk-core && forge build)
 *   ANVIL_RPC_URL=http://127.0.0.1:8599 pnpm test
 *
 * Skipped without ANVIL_RPC_URL.
 *
 * It shares the anvil, and so the chain clock, with the other anvil suites. `pnpm test` runs test files
 * one at a time (--test-concurrency=1) for that reason: run concurrently, one suite's evm_increaseTime
 * lands between another's signing and submission and expires its 60-second deadline
 * (BLF_DataExpired), or blows through its fixing window. The future's minMarkInterval here is 1 second
 * so the test needs no long jump; the hourly interval is the unit tests' to check.
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
import { carryForward, invert, ONE } from './forward-targets.js';

const RPC = process.env.ANVIL_RPC_URL;
const ARTIFACTS = join(import.meta.dirname, '../../../contracts/risk-core/out');
// anvil's second default account: each anvil suite deploys and relays from its own, so a stray
// concurrent run cannot race another for nonces.
const DEPLOYER_KEY = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d' as Hex;
const INDEX_SIGNER_KEY = keccak256(toHex('numo.future-feeds.e2e.index-signer'));
const FORWARD_SIGNER_KEY = keccak256(toHex('numo.future-feeds.e2e.forward-signer'));
const CARRY = (2n * ONE) / 10n;
const CONTRACT_SIZE = 1_000n * ONE;

const adminAbi = parseAbi([
  'function addSigner(address signer, bool isSigner)',
  'function setHeartbeat(uint64 heartbeat)',
  'function setIndexParams(address indexFeed, uint256 maxDev, uint256 minDev, uint256 narrowing, uint256 window, uint256 gap, uint256 fallbackDelay)',
  'function setMarkBounds(uint256 maxMarkDeviation, uint256 maxMarkDelay)',
  'function setForwardFeed(address forwardFeed, uint256 minMarkInterval)',
  'function setContract(uint64 expiry, uint64 lastTradeTime, uint256 initialMarkPrice) returns (uint96)',
  'function getSpot() view returns (uint256, uint256)',
]);

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const json = JSON.parse(readFileSync(join(ARTIFACTS, file, `${name}.json`), 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

describe('forward publisher against real contracts on anvil', { skip: !RPC }, () => {
  const chain = defineChain({
    id: 31337,
    name: 'anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC ?? ''] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(RPC) });
  const deployer = privateKeyToAccount(DEPLOYER_KEY);
  const wallet = createWalletClient({ account: deployer, chain, transport: http(RPC) });
  const at: Record<'submitter' | 'index' | 'forward' | 'future' | 'subAccounts', Address> = {} as never;
  let expiry: bigint;
  let indexUsdc: bigint;

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

  /** Publish the index as its own signer would: 1400 cNGN per USDC. */
  async function publishIndex() {
    const indexChain = createChain({ RPC_URL: RPC!, CHAIN_ID: 31337, RELAYER_KEY: DEPLOYER_KEY, DATA_SUBMITTER: at.submitter, FEED_SIGNER_KEY: INDEX_SIGNER_KEY });
    const now = await head();
    const update = await signFeedUpdate({
      signer: indexChain.signer,
      kind: 'LyraSpotFeed',
      feed: at.index,
      chainId: 31337,
      data: encodeSpotData(indexUsdc),
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
      DATA_SUBMITTER: at.submitter,
      INDEX_FEED: at.index,
      FORWARD_FEED: at.forward,
      FUTURE_ASSET: at.future,
      // no engine here: the deficit cover is not exercised
      FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
      FUTURE_SUB_ID: String(expiry),
      CARRY: String(CARRY),
      TIMESTAMP_SAFETY_SEC: '1',
      ...overrides,
    });
  }

  before(async () => {
    at.submitter = await deploy('OracleDataSubmitter.sol', 'OracleDataSubmitter');
    at.subAccounts = await deploy('SubAccounts.sol', 'SubAccounts', ['Accounts', 'ACC']);
    at.index = await deploy('LyraSpotFeed.sol', 'LyraSpotFeed');
    at.forward = await deploy('LyraForwardFeed.sol', 'LyraForwardFeed', [at.index]);
    at.future = await deploy('FutureAssetV1.sol', 'FutureAssetV1', [at.subAccounts, CONTRACT_SIZE]);

    await send(at.index, 'addSigner', [privateKeyToAccount(INDEX_SIGNER_KEY).address, true]);
    await send(at.index, 'setHeartbeat', [86_400n]);
    await send(at.forward, 'addSigner', [privateKeyToAccount(FORWARD_SIGNER_KEY).address, true]);
    await send(at.forward, 'setHeartbeat', [7_200n]);

    indexUsdc = invert(1400n * ONE);
    await advance(2);
    await publishIndex();

    const now = await head();
    expiry = now + 30n * 86_400n;
    await send(at.future, 'setIndexParams', [at.index, ONE / 10n, ONE / 100n, 14n * 86_400n, 3_600n, 900n, 86_400n]);
    await send(at.future, 'setMarkBounds', [ONE / 20n, 600n]);
    await send(at.future, 'setForwardFeed', [at.forward, 1n]);
    // listed at the carry forward, as the deploy script requires
    await send(at.future, 'setContract', [expiry, expiry - 3_600n, carryForward(invert(indexUsdc), CARRY, expiry - now)]);
  });

  async function contract() {
    return (await publicClient.readContract({ address: at.future, abi: futureAbi, functionName: 'futureContracts', args: [expiry] })) as {
      markPrice: bigint;
      lastMarkTime: bigint;
    };
  }

  it('signs a forward the LyraForwardFeed accepts, and pullMark turns it into the carry forward', async () => {
    await advance(2);
    const cfg = config();
    const signer = privateKeyToAccount(FORWARD_SIGNER_KEY);
    const before = await contract();

    const outcome = await new ForwardPublisher(cfg, createChain(cfg, signer), async () => {}, async () => []).tick();
    assert.equal(outcome, 'published');

    const after = await contract();
    assert.ok(after.lastMarkTime > before.lastMarkTime, 'a new mark landed');
    const expected = carryForward(invert(indexUsdc), CARRY, expiry - after.lastMarkTime);
    const error = after.markPrice > expected ? after.markPrice - expected : expected - after.markPrice;
    // tau moves by the seconds between the publisher's head and the pull's block
    assert.ok(error * 10n ** 6n <= expected, `mark ${after.markPrice} vs carry forward ${expected}`);
  });

  it('refuses a forward signed by any other key: the feed rejects it and the mark does not move', async () => {
    await advance(2);
    const cfg = config({ FORWARD_SIGNER_KEY: INDEX_SIGNER_KEY });
    const before = await contract();
    const alerts: string[] = [];
    const outcome = await new ForwardPublisher(cfg, createChain(cfg, privateKeyToAccount(INDEX_SIGNER_KEY)), async (key) => void alerts.push(key), async () => []).tick();
    assert.equal(outcome, 'pull-failed');
    assert.ok(alerts.includes('forward-pull-failed'));
    assert.equal((await contract()).lastMarkTime, before.lastMarkTime, 'no mark landed');
  });
});
