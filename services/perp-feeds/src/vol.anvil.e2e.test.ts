/**
 * The vol publisher against the REAL contracts, deployed from risk-core's compiled artifacts onto a local anvil: a
 * LyraSpotFeed index, a LyraForwardFeed on it, the options' LyraVolFeed, and the OracleDataSubmitter. It proves the
 * chain accepts what the publisher signs and encodes, and that the feed then reads back the surface meant: the set ATM
 * vol at full confidence, and the floor at the degraded confidence. The engine is not deployed: tick() reads only the
 * feeds (checkStartup's engine reads are the unit tests' and the fork test's).
 *
 *   anvil --port 8599 &
 *   (cd ../../contracts/risk-core && forge build)
 *   ANVIL_RPC_URL=http://127.0.0.1:8599 pnpm test
 *
 * Skipped without ANVIL_RPC_URL. Runs one file at a time with the other anvil suites (they share the chain clock).
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { before, describe, it } from 'node:test';

import { createPublicClient, createWalletClient, defineChain, http, keccak256, parseAbi, toHex, type Abi, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import { createChain } from './chain.js';
import { encodeForwardData, encodeManagerData, encodeSpotData, signFeedUpdate } from './feed-data.js';
import { loadVolConfig } from './vol-config.js';
import { volFeedAbi, VolPublisher } from './vol-publisher.js';
import { ONE } from './vol-surface.js';

const RPC = process.env.ANVIL_RPC_URL;
const ARTIFACTS = join(import.meta.dirname, '../../../contracts/risk-core/out');
// anvil's fourth default account: each anvil suite deploys and relays from its own.
const DEPLOYER_KEY = '0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6' as Hex;
const INDEX_SIGNER_KEY = keccak256(toHex('numo.vol-feeds.e2e.index-signer'));
const FORWARD_SIGNER_KEY = keccak256(toHex('numo.vol-feeds.e2e.forward-signer'));
const VOL_SIGNER_KEY = keccak256(toHex('numo.vol-feeds.e2e.vol-signer'));
const INDEX = 720_000_000_000_000n; // 0.00072 USDC per cNGN
const STATUS = '/status.json';

const adminAbi = parseAbi(['function addSigner(address signer, bool isSigner)', 'function setHeartbeat(uint64 heartbeat)']);

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const json = JSON.parse(readFileSync(join(ARTIFACTS, file, `${name}.json`), 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

describe('vol publisher against real contracts on anvil', { skip: !RPC }, () => {
  const chain = defineChain({
    id: 31337,
    name: 'anvil',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC ?? ''] } },
  });
  const publicClient = createPublicClient({ chain, transport: http(RPC) });
  const wallet = createWalletClient({ account: privateKeyToAccount(DEPLOYER_KEY), chain, transport: http(RPC) });
  const at: Record<'submitter' | 'index' | 'forward' | 'vol', Address> = {} as never;
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

  async function head(): Promise<bigint> {
    return (await publicClient.getBlock({ blockTag: 'latest' })).timestamp;
  }

  async function advance(seconds: number) {
    await publicClient.request({ method: 'evm_increaseTime' as never, params: [seconds] as never });
    await publicClient.request({ method: 'evm_mine' as never, params: [] as never });
  }

  /** The index and a forward at it, as their own signers would publish them. */
  async function publishIndexAndForward() {
    const relay = createChain({ RPC_URL: RPC!, CHAIN_ID: 31337, RELAYER_KEY: DEPLOYER_KEY, DATA_SUBMITTER: at.submitter, FEED_SIGNER_KEY: INDEX_SIGNER_KEY });
    const now = await head();
    const index = await signFeedUpdate({
      signer: relay.signer, kind: 'LyraSpotFeed', feed: at.index, chainId: 31337, data: encodeSpotData(INDEX), timestamp: now - 1n, deadline: now + 60n,
    });
    const forward = await signFeedUpdate({
      signer: privateKeyToAccount(FORWARD_SIGNER_KEY), kind: 'LyraForwardFeed', feed: at.forward, chainId: 31337,
      data: encodeForwardData(expiry, 0n), timestamp: now - 1n, deadline: now + 60n,
    });
    await relay.submit(encodeManagerData([index, forward]));
  }

  function publisher(signerKey: Hex, statusJson: () => string) {
    const config = loadVolConfig({
      RPC_URL: RPC!,
      CHAIN_ID: '31337',
      RELAYER_KEY: DEPLOYER_KEY,
      VOL_SIGNER_KEY: signerKey,
      DATA_SUBMITTER: at.submitter,
      VOL_FEED: at.vol,
      FORWARD_FEED: at.forward,
      INDEX_FEED: at.index,
      ENGINE: '0x00000000000000000000000000000000000000E9', // not read by tick()
      EXPIRY: String(expiry),
      VOL_ATM: '400000000000000000',
      VOL_DEGRADED_ATM_FLOOR: '800000000000000000',
      INDEX_STATUS_FILE: STATUS,
      INDEX_STEP_AUDIT_FILE: '/none.jsonl',
      TIMESTAMP_SAFETY_SEC: '1',
    });
    const alerts: string[] = [];
    const p = new VolPublisher(
      config,
      createChain(config, privateKeyToAccount(signerKey)),
      async (key) => void alerts.push(key),
      Date.now,
      async (path) => {
        if (path === STATUS) return statusJson();
        throw new Error(`ENOENT ${path}`);
      },
      async () => {},
    );
    return { p, alerts };
  }

  async function atm(): Promise<{ vol: bigint; confidence: bigint }> {
    const strike = (INDEX / 10n ** 10n) * 10n ** 10n;
    const [vol] = (await publicClient.readContract({ address: at.vol, abi: volFeedAbi, functionName: 'getVol', args: [strike, expiry] })) as readonly bigint[];
    const confidence = (await publicClient.readContract({ address: at.vol, abi: volFeedAbi, functionName: 'getExpiryMinConfidence', args: [expiry] })) as bigint;
    return { vol, confidence };
  }

  const near = (x: bigint, y: bigint) => (x > y ? x - y : y - x) * 1000n <= y;
  const healthy = () => JSON.stringify({ at: Date.now(), pegGuardTripped: false, sample: { ok: true } });
  const tripped = () => JSON.stringify({ at: Date.now(), pegGuardTripped: true, sample: { ok: true } });

  before(async () => {
    at.submitter = await deploy('OracleDataSubmitter.sol', 'OracleDataSubmitter');
    at.index = await deploy('LyraSpotFeed.sol', 'LyraSpotFeed');
    at.forward = await deploy('LyraForwardFeed.sol', 'LyraForwardFeed', [at.index]);
    at.vol = await deploy('LyraVolFeed.sol', 'LyraVolFeed');
    await send(at.index, 'addSigner', [privateKeyToAccount(INDEX_SIGNER_KEY).address, true]);
    await send(at.index, 'setHeartbeat', [86_400n]);
    await send(at.forward, 'addSigner', [privateKeyToAccount(FORWARD_SIGNER_KEY).address, true]);
    await send(at.forward, 'setHeartbeat', [86_400n]);
    await send(at.vol, 'addSigner', [privateKeyToAccount(VOL_SIGNER_KEY).address, true]);
    await send(at.vol, 'setHeartbeat', [1_800n]);
    expiry = (await head()) + 29n * 86_400n;
    await advance(2);
    await publishIndexAndForward();
  });

  it('signs a surface the LyraVolFeed accepts: the set ATM vol, at full confidence', async () => {
    await advance(2);
    const { p, alerts } = publisher(VOL_SIGNER_KEY, healthy);
    assert.equal(await p.tick(), 'published');
    const read = await atm();
    assert.ok(near(read.vol, 4n * 10n ** 17n), `ATM ${read.vol}`);
    assert.equal(read.confidence, ONE);
    assert.deepEqual(alerts, [], 'and it reads back as published');
  });

  it('degrades on the peg tripwire: the floor, at the degraded confidence, read back from the feed', async () => {
    await advance(2);
    const { p, alerts } = publisher(VOL_SIGNER_KEY, tripped);
    assert.equal(await p.tick(), 'published');
    const read = await atm();
    assert.ok(near(read.vol, 8n * 10n ** 17n), `ATM ${read.vol}`);
    assert.equal(read.confidence, 5n * 10n ** 17n);
    assert.deepEqual(alerts, ['vol-degraded']);
  });

  it('refuses a surface signed by any other key: the relay reverts and the feed does not move', async () => {
    await advance(2);
    const before = await atm();
    const { p, alerts } = publisher(INDEX_SIGNER_KEY, healthy);
    assert.equal(await p.tick(), 'publish-failed');
    assert.deepEqual(alerts, ['vol-publish-failed']);
    assert.deepEqual(await atm(), before);
  });
});
