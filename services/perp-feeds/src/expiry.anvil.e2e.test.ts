/**
 * The expiry keeper against a REAL FutureAsset on anvil: it samples the index through a fixing
 * window and fixes the settlement price from those samples, with nothing but permissionless calls.
 *
 * The contract is listed with a 40-second window and a 20-second gap limit so the whole fixing runs
 * in a minute of chain time, stepped 5 seconds at a time. That only holds if nothing else moves the
 * clock meanwhile: the anvil suites share one node, which is why `pnpm test` runs files one at a time
 * (--test-concurrency=1). Run concurrently, the perp suite's 60-second jump lands inside this window.
 *
 * Close-out is not here: it needs a full MarginEngine stack (cash, cNGN escrow, perp, auction), which
 * risk-core's fork suite (MarginEngineDeployFork) runs on real Base contracts. The keeper's scan and
 * batching are unit-tested in expiry-keeper.test.ts.
 *
 * Skipped without ANVIL_RPC_URL.
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
import { ExpiryKeeper } from './expiry-keeper.js';
import { encodeManagerData, encodeSpotData, signFeedUpdate } from './feed-data.js';
import { loadForwardConfig } from './forward-config.js';
import { futureAbi } from './forward-publisher.js';
import { invert, ONE } from './forward-targets.js';

const RPC = process.env.ANVIL_RPC_URL;
const ARTIFACTS = join(import.meta.dirname, '../../../contracts/risk-core/out');
// anvil's fourth default account: each anvil suite deploys and relays from its own.
const DEPLOYER_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6' as Hex;
const INDEX_SIGNER_KEY = keccak256(toHex('numo.expiry-keeper.e2e.index-signer'));
const WINDOW = 40n;
const GAP = 20n;

const adminAbi = parseAbi([
  'function addSigner(address signer, bool isSigner)',
  'function setHeartbeat(uint64 heartbeat)',
  'function setIndexParams(address indexFeed, uint256 maxDev, uint256 minDev, uint256 narrowing, uint256 window, uint256 gap, uint256 fallbackDelay)',
  'function setContract(uint64 expiry, uint64 lastTradeTime, uint256 initialMarkPrice) returns (uint96)',
]);

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const json = JSON.parse(readFileSync(join(ARTIFACTS, file, `${name}.json`), 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

describe('expiry keeper against a real FutureAsset on anvil', { skip: !RPC }, () => {
  const chain = defineChain({
    id: 31337,
    name: 'anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC ?? ''] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(RPC) });
  const wallet = createWalletClient({ account: privateKeyToAccount(DEPLOYER_KEY), chain, transport: http(RPC) });
  const at: Record<'submitter' | 'index' | 'future' | 'subAccounts', Address> = {} as never;
  const indexUsdc = invert(1388n * ONE);
  let expiry: bigint;

  async function deploy(file: string, name: string, args: unknown[] = []): Promise<Address> {
    const { abi, bytecode } = artifact(file, name);
    const hash = await wallet.deployContract({ abi, bytecode, args });
    return (await publicClient.waitForTransactionReceipt({ hash })).contractAddress!;
  }

  async function send(address: Address, functionName: string, args: unknown[]) {
    const hash = await wallet.writeContract({ address, abi: adminAbi, functionName, args } as never);
    assert.equal((await publicClient.waitForTransactionReceipt({ hash })).status, 'success', `${functionName} reverted`);
  }

  async function step() {
    await publicClient.request({ method: 'evm_increaseTime' as never, params: [5] as never });
    await publicClient.request({ method: 'evm_mine' as never, params: [] as never });
  }

  async function head(): Promise<bigint> {
    return (await publicClient.getBlock({ blockTag: 'latest' })).timestamp;
  }

  before(async () => {
    at.submitter = await deploy('OracleDataSubmitter.sol', 'OracleDataSubmitter');
    at.subAccounts = await deploy('SubAccounts.sol', 'SubAccounts', ['Accounts', 'ACC']);
    at.index = await deploy('LyraSpotFeed.sol', 'LyraSpotFeed');
    at.future = await deploy('FutureAssetV1.sol', 'FutureAssetV1', [at.subAccounts, 1_000n * ONE]);
    await send(at.index, 'addSigner', [privateKeyToAccount(INDEX_SIGNER_KEY).address, true]);
    await send(at.index, 'setHeartbeat', [86_400n]);

    // the index, as its own signer would publish it
    const indexChain = createChain({ RPC_URL: RPC!, CHAIN_ID: 31337, RELAYER_KEY: DEPLOYER_KEY, DATA_SUBMITTER: at.submitter, FEED_SIGNER_KEY: INDEX_SIGNER_KEY });
    await step();
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

    expiry = (await head()) + 60n;
    await send(at.future, 'setIndexParams', [at.index, ONE / 10n, ONE / 100n, 0n, WINDOW, GAP, 3_600n]);
    await send(at.future, 'setContract', [expiry, expiry - WINDOW, invert(indexUsdc)]);
  });

  it('samples the window and fixes the settlement price from the index', async () => {
    const cfg = loadForwardConfig({
      RPC_URL: RPC!,
      CHAIN_ID: '31337',
      RELAYER_KEY: DEPLOYER_KEY,
      FORWARD_SIGNER_KEY: keccak256(toHex('numo.expiry-keeper.e2e.forward-signer')),
      DATA_SUBMITTER: at.submitter,
      INDEX_FEED: at.index,
      FORWARD_FEED: at.index,
      FUTURE_ASSET: at.future,
      // no engine here: the deficit cover is not exercised
      FUTURE_MANAGER: '0x00000000000000000000000000000000000000E9',
      FUTURE_SUB_ID: String(expiry),
      CARRY: '0',
      FIXING_SAMPLE_INTERVAL_MS: '8000',
    });
    const alerts: string[] = [];
    const keeper = new ExpiryKeeper(cfg, createChain(cfg, privateKeyToAccount(cfg.FORWARD_SIGNER_KEY as Hex)), async (key) => void alerts.push(key));
    await keeper.checkSampleInterval();

    const outcomes: string[] = [];
    for (let i = 0; i < 40; i++) {
      const outcome = await keeper.tick();
      outcomes.push(outcome);
      if (outcome === 'fixed' || outcome === 'fixing-incomplete') break;
      await step();
    }

    assert.ok(outcomes.includes('sampled'), `it sampled: ${outcomes.join(',')}`);
    assert.equal(outcomes.at(-1), 'fixed', `it fixed: ${outcomes.join(',')}`);
    assert.deepEqual(alerts, [], 'no sample failed and the fixing was complete');

    const contract = (await publicClient.readContract({ address: at.future, abi: futureAbi, functionName: 'futureContracts', args: [expiry] })) as {
      settled: boolean;
      markPrice: bigint;
    };
    assert.equal(contract.settled, true);
    assert.equal(contract.markPrice, invert(indexUsdc), 'a flat index settles at the index');

    // and once settled, with nobody holding the series, the keeper has nothing left to do
    assert.equal(await keeper.tick(), 'done');
  });
});
