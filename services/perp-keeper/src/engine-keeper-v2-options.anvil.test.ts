/**
 * The keeper's expired-option sweep (options.ts, chain.ts settleExpiredOptions) on the live MarginEngine v2, on an anvil
 * fork of Base. cNGN options are attached to market 1 as deploy-cngn-options-v2.s.sol's batches would (an OptionAsset
 * settling on a FutureFixingSettlementFeed over cNGN-30NOV26, a LyraVolFeed, market 1's oracles with the live spot
 * written back), bob writes alice a put and a call at the forward, and then, past expiry:
 *
 *   - before the future's price is fixed the sweep settles nothing and reports both accounts as awaiting;
 *   - once that lasts past OPTION_SETTLE_WARN_SEC it alerts `options-unsettled`;
 *   - after the vault's fallback fixes the future, it settles both, and cash moves only between them.
 *
 * It warps the fork a month, so it runs on an anvil of its own, and reverts its snapshot after:
 *
 *   (cd ../../contracts/risk-core && forge build)
 *   anvil --fork-url $BASE_RPC_URL --chain-id 31337 --port 8606 &
 *   OPTIONS_KEEPER_E2E_RPC_URL=http://127.0.0.1:8606 pnpm test
 *
 * Skipped without the env.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { after, before, describe, it } from 'node:test';

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  http,
  keccak256,
  pad,
  parseAbi,
  toHex,
  type Abi,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';

import { createKeeperChain, withGasHeadroom } from './chain.js';
import { loadConfig } from './config.js';
import { runOnce, sweepOptions, type PassSummary } from './keeper.js';

const RPC = process.env.OPTIONS_KEEPER_E2E_RPC_URL;
const ARTIFACTS = join(import.meta.dirname, '../../../contracts/risk-core/out');

// risk-core deployments/8453/MARGIN_ENGINE_V2.json
const ENGINE = '0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950' as Address;
const FUTURE = '0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75' as Address;
const FORWARD_FEED = '0x24474D8A95EB8Be9070ede58E09405B410c277Df' as Address;
const EXPIRY = 1796047200n;
const POOL_ACCOUNT = 37n;
const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272' as Address;
const CNGN_SPOT_FEED = '0xFaC420d160C7c219A72DC676971670980bAC20a5' as Address;
const AUCTION = '0xd07176B006cE8246e930d37b8bc44B1154f8c4cE' as Address;
const SECURITY_MODULE_ACCOUNT = 21n;
const SUB_ACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843' as Address;
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address;
const VAULT = '0x1dcA42ab54Bd3862853A821F84B29BF65245F435' as Address;
const USDC_BALANCE_SLOT = 9n;
const E18 = 10n ** 18n;
const SIZE = 1_000_000n * E18; // 1M cNGN of each option

const key = (label: string) => keccak256(toHex(`numo.engine-keeper-v2-options.e2e.${label}`));
const KEYS = { alice: key('alice'), bob: key('bob'), keeper: key('keeper'), operator: key('operator'), vol: key('vol') } as const;

const abi = parseAbi([
  'function setTotalPositionCap(address manager, uint256 cap)',
  'function setWhitelistManager(address manager, bool whitelisted)',
  'function addSigner(address signer, bool isSigner)',
  'function setHeartbeat(uint64 heartbeat)',
  'function acceptData(bytes data)',
  'function whitelistAsset(address asset, uint256 marketId, uint8 assetType)',
  'function setOptionMarginParams(uint256 marketId, (uint256,uint256,uint256,uint256,uint256,uint256,uint256,uint256) params)',
  'function setOraclesForMarket(uint256 marketId, address spot, address forward, address vol)',
  'function getForwardPrice(uint64 expiry) view returns (uint256, uint256)',
  'function fallbackDelay() view returns (uint256)',
  'function fallbackReference(uint96 subId) view returns (uint256)',
  'function setSettlementPrice(uint96 subId, uint256 settlementPrice)',
  'function settleInterest(uint256 accountId)',
  'function createAccountWithApproval(address owner, address spender, address manager) returns (uint256)',
  'function createAccount(address owner, address manager) returns (uint256)',
  'function lastAccountId() view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function deposit(uint256 recipientAccount, uint256 stableAmount)',
  'function submitTransfers((uint256 fromAcc, uint256 toAcc, address asset, uint256 subId, int256 amount, bytes32 assetData)[] transfers, bytes managerData) returns (uint256)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
]);

function artifact(file: string, name: string): { abi: Abi; bytecode: Hex } {
  const json = JSON.parse(readFileSync(join(ARTIFACTS, file, `${name}.json`), 'utf8'));
  return { abi: json.abi, bytecode: json.bytecode.object };
}

/** OptionEncoding.toSubId: expiry | strike / 1e10 << 32 | isCall << 95. */
function optionSubId(expiry: bigint, strike: bigint, isCall: boolean): bigint {
  return expiry | ((strike / 10n ** 10n) << 32n) | ((isCall ? 1n : 0n) << 95n);
}

describe('the keeper settles expired cNGN options on MarginEngine v2, on a fork of Base', { skip: !RPC }, () => {
  const chain = defineChain({ id: 31337, name: 'anvil-fork', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC ?? ''] } } });
  const client = createPublicClient({ chain, transport: http(RPC) });
  const accounts: Record<string, bigint> = {};
  const at: Record<'option' | 'vol' | 'settlement', Address> = {} as never;
  let startBlock = 0n;
  let snapshot: Hex;
  let put = 0n;
  let call = 0n;

  const rpc = (method: string, params: unknown[]) => client.request({ method: method as never, params: params as never });

  async function write(from: PrivateKeyAccount | Address, address: Address, functionName: string, args: unknown[]) {
    const estimate = await client.estimateContractGas({ address, abi, functionName: functionName as never, args: args as never, account: from as never });
    const hash = await createWalletClient({ account: from, chain, transport: http(RPC) }).writeContract({
      address, abi, functionName: functionName as never, args: args as never, chain, account: from as never, gas: withGasHeadroom(estimate),
    });
    assert.equal((await client.waitForTransactionReceipt({ hash })).status, 'success', `${functionName} reverted`);
  }

  async function deploy(from: PrivateKeyAccount, file: string, name: string, args: unknown[] = []): Promise<Address> {
    const { abi: a, bytecode } = artifact(file, name);
    const hash = await createWalletClient({ account: from, chain, transport: http(RPC) }).deployContract({ abi: a, bytecode, args, chain });
    return (await client.waitForTransactionReceipt({ hash })).contractAddress!;
  }

  async function newAccount(owner: PrivateKeyAccount, approvedTo?: Address): Promise<bigint> {
    if (approvedTo) await write(owner, SUB_ACCOUNTS, 'createAccountWithApproval', [owner.address, approvedTo, ENGINE]);
    else await write(owner, SUB_ACCOUNTS, 'createAccount', [owner.address, ENGINE]);
    return (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'lastAccountId' })) as bigint;
  }

  async function depositCash(owner: PrivateKeyAccount, accountId: bigint, usdc: bigint) {
    const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [owner.address, USDC_BALANCE_SLOT]));
    await rpc('anvil_setStorageAt', [USDC, slot, pad(toHex(usdc), { size: 32 })]);
    await write(owner, USDC, 'approve', [CASH, usdc]);
    await write(owner, CASH, 'deposit', [accountId, usdc]);
  }

  /** A flat 40% surface for EXPIRY, signed by the vol key, accepted by the feed directly. */
  async function publishVol(fwd: bigint) {
    const head = (await client.getBlock({ blockTag: 'latest' })).timestamp;
    const tau = ((EXPIRY - head) * E18) / 31_536_000n;
    const a = (((4n * E18) / 10n) * ((4n * E18) / 10n) / E18) * tau / E18;
    const data = encodeAbiParameters(
      [{ type: 'uint64' }, { type: 'int256' }, { type: 'uint256' }, { type: 'int256' }, { type: 'int256' }, { type: 'uint256' }, { type: 'uint256' }, { type: 'uint64' }, { type: 'uint64' }],
      [EXPIRY, a, 0n, 0n, 0n, E18 / 10n, fwd, tau, E18],
    );
    const timestamp = head - 1n;
    const deadline = head + 60n;
    const signer = privateKeyToAccount(KEYS.vol);
    const signature = await signer.signTypedData({
      domain: { name: 'LyraVolFeed', version: '1', chainId: 31337, verifyingContract: at.vol },
      types: { FeedData: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }] },
      primaryType: 'FeedData',
      message: { data, deadline, timestamp },
    });
    const encoded = encodeAbiParameters(
      [{ type: 'tuple', components: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }, { name: 'signers', type: 'address[]' }, { name: 'signatures', type: 'bytes[]' }] }],
      [{ data, deadline, timestamp, signers: [signer.address], signatures: [signature] }],
    );
    await write(privateKeyToAccount(KEYS.operator), at.vol, 'acceptData', [encoded]);
  }

  const balanceOf = async (id: bigint, asset: Address, subId: bigint) =>
    (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [id, asset, subId] })) as bigint;
  const settledCash = async (id: bigint) => {
    await write(privateKeyToAccount(KEYS.operator), ENGINE, 'settleInterest', [id]);
    return balanceOf(id, CASH, 0n);
  };

  function keeperConfig(extra: Record<string, string> = {}) {
    return loadConfig({
      RPC_URL: RPC!,
      CHAIN_ID: '31337',
      KEEPER_KEY: KEYS.keeper,
      KEEPER_ACCOUNT: accounts.keeper!.toString(),
      DRY_RUN: 'false',
      SUB_ACCOUNTS,
      MANAGER: ENGINE,
      AUCTION,
      CASH,
      FUTURE,
      OPTION: at.option,
      CNGN_SPOT_FEED,
      POOL_ACCOUNT: POOL_ACCOUNT.toString(),
      SECURITY_MODULE_ACCOUNT: SECURITY_MODULE_ACCOUNT.toString(),
      START_BLOCK: startBlock.toString(),
      SCAN_CONFIRMATIONS: '0',
      ...extra,
    });
  }

  const alerts: string[] = [];
  const alert = async (k: string, message: string) => {
    alerts.push(k);
    console.log(`[alert] ${k}: ${message}`);
  };

  before(async () => {
    snapshot = (await rpc('evm_snapshot', [])) as Hex;
    await rpc('anvil_impersonateAccount', [VAULT]);
    for (const address of [VAULT, ...Object.values(KEYS).map((k) => privateKeyToAccount(k).address)]) {
      await rpc('anvil_setBalance', [address, toHex(E18)]);
    }
    // Discovery from the first block after the fork point: everything this test creates is after it, and a log query
    // reaching the fork block itself is forwarded to the (rate-limited) upstream node.
    startBlock = (await client.getBlockNumber()) + 1n;
    const operator = privateKeyToAccount(KEYS.operator);

    // The deploy (operator as deployer) and the setup batch (the vault), as deploy-cngn-options-v2.s.sol writes them.
    at.settlement = await deploy(operator, 'FutureFixingSettlementFeed.sol', 'FutureFixingSettlementFeed', [FUTURE]);
    at.option = await deploy(operator, 'OptionAsset.sol', 'OptionAsset', [SUB_ACCOUNTS, at.settlement]);
    at.vol = await deploy(operator, 'LyraVolFeed.sol', 'LyraVolFeed');
    await write(operator, at.option, 'setWhitelistManager', [ENGINE, true]);
    await write(operator, at.vol, 'addSigner', [privateKeyToAccount(KEYS.vol).address, true]);
    await write(operator, at.vol, 'setHeartbeat', [1_800n]);
    await write(VAULT, ENGINE, 'whitelistAsset', [at.option, 1n, 1]);
    await write(VAULT, ENGINE, 'setOptionMarginParams', [1n, [3n * E18 / 10n, E18 / 4n, 15n * E18 / 100n, 15n * E18 / 100n, E18 / 2n, 12n * E18 / 10n, 11n * E18 / 10n, 105n * E18 / 100n]]);
    await write(VAULT, ENGINE, 'setOraclesForMarket', [1n, CNGN_SPOT_FEED, FORWARD_FEED, at.vol]);
    await write(operator, at.option, 'setTotalPositionCap', [ENGINE, 100_000_000n * E18]); // the enable batch

    const [fwd] = (await client.readContract({ address: FORWARD_FEED, abi, functionName: 'getForwardPrice', args: [EXPIRY] })) as readonly bigint[];
    await publishVol(fwd);
    const strike = (fwd / 10n ** 10n) * 10n ** 10n;
    put = optionSubId(EXPIRY, strike, false);
    call = optionSubId(EXPIRY, strike, true);

    const alice = privateKeyToAccount(KEYS.alice);
    const bob = privateKeyToAccount(KEYS.bob);
    accounts.alice = await newAccount(alice, operator.address);
    accounts.bob = await newAccount(bob, operator.address);
    accounts.keeper = await newAccount(privateKeyToAccount(KEYS.keeper));
    await depositCash(alice, accounts.alice, 100n * 10n ** 6n);
    await depositCash(bob, accounts.bob, 5_000n * 10n ** 6n);
    await depositCash(privateKeyToAccount(KEYS.keeper), accounts.keeper, 3_000n * 10n ** 6n);
    // Bob writes alice a put and a call at the forward (premium aside: this is about settlement).
    await write(operator, SUB_ACCOUNTS, 'submitTransfers', [
      [
        { fromAcc: accounts.bob, toAcc: accounts.alice, asset: at.option, subId: put, amount: SIZE, assetData: pad('0x0', { size: 32 }) },
        { fromAcc: accounts.bob, toAcc: accounts.alice, asset: at.option, subId: call, amount: SIZE, assetData: pad('0x0', { size: 32 }) },
      ],
      '0x',
    ]);
    assert.equal(await balanceOf(accounts.bob!, at.option, put), -SIZE);
  });

  after(async () => {
    if (snapshot) await rpc('evm_revert', [snapshot]);
  });

  it('a pass before expiry settles nothing, and /health would name the option', async () => {
    const config = keeperConfig();
    assert.deepEqual(config.OPTIONS.map((o) => o.toLowerCase()), [at.option.toLowerCase()]);
    const summary: PassSummary = { liquidatable: [], insolvent: [], openAuctions: [] };
    await runOnce(config, createKeeperChain(config), alert, summary);
    assert.deepEqual(summary.optionsSettled, []);
    assert.deepEqual(summary.optionsAwaitingPrice, []);
  });

  it('past expiry, unfixed: awaiting, not settled; past the warning age it alerts', async () => {
    await rpc('evm_setNextBlockTimestamp', [Number(EXPIRY + 60n)]);
    await rpc('evm_mine', []);
    const summary: PassSummary = { liquidatable: [], insolvent: [], openAuctions: [] };
    const config = keeperConfig();
    await sweepOptions(config, createKeeperChain(config), alert, summary);
    assert.deepEqual(summary.optionsSettled, []);
    assert.deepEqual([...summary.optionsAwaitingPrice!].sort(), [accounts.alice!, accounts.bob!].sort());
    assert.equal(await balanceOf(accounts.alice!, at.option, put), SIZE, 'still held');

    // 60s past expiry on the chain's clock: a 1-second warning age is already past
    alerts.length = 0;
    await sweepOptions(keeperConfig({ OPTION_SETTLE_WARN_SEC: '1' }), createKeeperChain(config), alert, summary);
    assert.ok(alerts.includes('options-unsettled'), `alerts ${alerts}`);
  });

  it('once the future is fixed (here by the vault fallback), settles both accounts, and cash moves only between them', async () => {
    const delay = (await client.readContract({ address: FUTURE, abi, functionName: 'fallbackDelay' })) as bigint;
    await rpc('evm_setNextBlockTimestamp', [Number(EXPIRY + delay + 60n)]);
    await rpc('evm_mine', []);
    const reference = (await client.readContract({ address: FUTURE, abi, functionName: 'fallbackReference', args: [EXPIRY] })) as bigint;
    await write(VAULT, FUTURE, 'setSettlementPrice', [EXPIRY, reference]);

    const aliceBefore = await settledCash(accounts.alice!);
    const bobBefore = await settledCash(accounts.bob!);
    alerts.length = 0;
    const summary: PassSummary = { liquidatable: [], insolvent: [], openAuctions: [] };
    const config = keeperConfig();
    await sweepOptions(config, createKeeperChain(config), alert, summary);
    assert.deepEqual([...summary.optionsSettled!].sort(), [accounts.alice!, accounts.bob!].sort());
    assert.deepEqual(summary.optionsAwaitingPrice, []);
    assert.ok(alerts.includes('options-settled'));

    for (const id of [accounts.alice!, accounts.bob!]) {
      assert.equal(await balanceOf(id, at.option, put), 0n, `${id} put settled`);
      assert.equal(await balanceOf(id, at.option, call), 0n, `${id} call settled`);
    }
    const aliceGain = (await settledCash(accounts.alice!)) - aliceBefore;
    const bobLoss = bobBefore - (await settledCash(accounts.bob!));
    // The payout is the in-the-money option's: (fixing - strike) x size for the call, (strike - fixing) for the put.
    const strike = ((put >> 32n) & 0x7fff_ffff_ffff_ffffn) * 10n ** 10n;
    const payout = ((reference > strike ? reference - strike : strike - reference) * SIZE) / E18;
    assert.ok(payout > 0n, 'the fixing is off the strike');
    // Cash interest accrues between the blocks the two reads land in: dust, under 1e-9 USDC.
    const dust = 10n ** 9n;
    const off = (x: bigint) => (x > payout ? x - payout : payout - x);
    assert.ok(off(aliceGain) <= dust, `the holder is paid the payout: ${aliceGain} vs ${payout}`);
    assert.ok(off(bobLoss) <= dust, `the writer pays it: ${bobLoss} vs ${payout}`);
    console.log(`[e2e] settled at ${reference}, strike ${strike}: payout ${payout}, alice +${aliceGain}, bob -${bobLoss}`);

    // nothing left to do on the next pass
    const again: PassSummary = { liquidatable: [], insolvent: [], openAuctions: [] };
    await sweepOptions(config, createKeeperChain(config), alert, again);
    assert.deepEqual(again.optionsSettled, []);
  });
});
