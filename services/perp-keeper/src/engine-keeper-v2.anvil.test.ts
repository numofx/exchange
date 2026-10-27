/**
 * The keeper as numo-engine-keeper-v2: MANAGER is the live MarginEngine v2, on an anvil fork of Base at head (v2
 * deployed and set up 2026-10-27, closed until `enable`). The same run as engine-keeper.anvil.test.ts on v1, configured
 * the v2 way (engine-keeper-v2.env): no PERP, cNGN priced at the engine's spot feed, FUTURE the v2 cNGN-30NOV26
 * (USDC per cNGN, a 1,000,000 cNGN contract, VM in USDC), the pool #37. The vault opens the future's cap (the
 * future half of `enable`), bob sells alice one contract, the vault raises the futures margin so alice is under
 * maintenance but solvent, and `runOnce` starts the auction and buys into it from the keeper's account under v2.
 *
 *   anvil --fork-url $BASE_RPC_URL --chain-id 31337 --port 8605 &
 *   ENGINE_KEEPER_E2E_RPC_URL=http://127.0.0.1:8605 pnpm test
 *
 * Skipped without the env.
 */
import assert from 'node:assert/strict';
import { before, describe, it } from 'node:test';

import { createPublicClient, createWalletClient, defineChain, encodeAbiParameters, http, keccak256, pad, parseAbi, toHex, type Address } from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';

import { createKeeperChain, withGasHeadroom } from './chain.js';
import { loadConfig } from './config.js';
import { runOnce } from './keeper.js';

const RPC = process.env.ENGINE_KEEPER_E2E_RPC_URL;

// risk-core deployments/8453/MARGIN_ENGINE_V2.json
const ENGINE = '0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950' as Address;
const FUTURE = '0xcACEe66ad41fD1472a47D7D5Fe372FFbFac9AA75' as Address;
const SUB_ID = 1796047200n;
const POOL_ACCOUNT = 37n;
const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272' as Address;
const CNGN_ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98' as Address;
const CNGN_SPOT_FEED = '0xFaC420d160C7c219A72DC676971670980bAC20a5' as Address;
const AUCTION = '0xd07176B006cE8246e930d37b8bc44B1154f8c4cE' as Address;
const SECURITY_MODULE_ACCOUNT = 21n;
const SUB_ACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843' as Address;
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address;
const VAULT = '0x1dcA42ab54Bd3862853A821F84B29BF65245F435' as Address;
const USDC_BALANCE_SLOT = 9n;
const E18 = 10n ** 18n;

const key = (label: string) => keccak256(toHex(`numo.engine-keeper-v2.e2e.${label}`));
const KEYS = { alice: key('alice'), bob: key('bob'), keeper: key('keeper'), operator: key('operator') } as const;

const abi = parseAbi([
  'function setTotalPositionCap(address manager, uint256 cap)',
  'function setFutureMarginRequirements(uint256 marketId, uint256 mmReq, uint256 imReq)',
  'function futureMarginRequirements(uint256 marketId) view returns (uint256 mmReq, uint256 imReq)',
  'function futureContracts(uint256 subId) view returns (bool listed, bool settled, uint64 expiry, uint64 lastTradeTime, uint64 lastMarkTime, uint256 markPrice, int256 cumulativeVMPerContract)',
  'function createAccount(address owner, address manager) returns (uint256)',
  'function createAccountWithApproval(address owner, address spender, address manager) returns (uint256)',
  'function lastAccountId() view returns (uint256)',
  'function approve(address spender, uint256 amount) returns (bool)',
  'function deposit(uint256 recipientAccount, uint256 stableAmount)',
  'function submitTransfers((uint256 fromAcc, uint256 toAcc, address asset, uint256 subId, int256 amount, bytes32 assetData)[] transfers, bytes managerData) returns (uint256)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function getMargin(uint256 accountId, bool isInitial) view returns (int256)',
  'function getAuction(uint256 accountId) view returns ((uint256 accountId, uint256 scenarioId, bool insolvent, bool ongoing, uint256 cachedMM, uint256 startTime, uint256 reservedCash))',
]);

describe('the keeper on MarginEngine v2 (numo-engine-keeper-v2), on a fork of Base', { skip: !RPC }, () => {
  const chain = defineChain({ id: 31337, name: 'anvil-fork', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC ?? ''] } } });
  const client = createPublicClient({ chain, transport: http(RPC) });
  const accounts: Record<string, bigint> = {};
  let startBlock = 0n;

  async function rpc(method: string, params: unknown[]) {
    return client.request({ method: method as never, params: params as never });
  }

  async function write(from: PrivateKeyAccount | Address, address: Address, functionName: string, args: unknown[]) {
    await client.simulateContract({ address, abi, functionName: functionName as never, args: args as never, account: from as never });
    const estimate = await client.estimateContractGas({ address, abi, functionName: functionName as never, args: args as never, account: from as never });
    const hash = await createWalletClient({ account: from, chain, transport: http(RPC) }).writeContract({
      address, abi, functionName: functionName as never, args: args as never, chain, account: from as never, gas: withGasHeadroom(estimate),
    });
    const receipt = await client.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, 'success', `${functionName} reverted`);
  }

  async function giveUsdc(to: Address, amount: bigint) {
    const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [to, USDC_BALANCE_SLOT]));
    await rpc('anvil_setStorageAt', [USDC, slot, pad(toHex(amount), { size: 32 })]);
  }

  async function newAccount(owner: PrivateKeyAccount, approvedTo?: Address): Promise<bigint> {
    if (approvedTo) await write(owner, SUB_ACCOUNTS, 'createAccountWithApproval', [owner.address, approvedTo, ENGINE]);
    else await write(owner, SUB_ACCOUNTS, 'createAccount', [owner.address, ENGINE]);
    return (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'lastAccountId' })) as bigint;
  }

  async function depositCash(owner: PrivateKeyAccount, accountId: bigint, usdc: bigint) {
    await giveUsdc(owner.address, usdc);
    await write(owner, USDC, 'approve', [CASH, usdc]);
    await write(owner, CASH, 'deposit', [accountId, usdc]);
  }

  const futureOf = async (id: bigint) =>
    (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [id, FUTURE, SUB_ID] })) as bigint;
  const auctionOf = async (id: bigint) =>
    (await client.readContract({ address: AUCTION, abi, functionName: 'getAuction', args: [id] })) as { ongoing: boolean; insolvent: boolean };

  function keeperConfig() {
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
      CNGN_ESCROW,
      CNGN_SPOT_FEED,
      POOL_ACCOUNT: POOL_ACCOUNT.toString(),
      SECURITY_MODULE_ACCOUNT: SECURITY_MODULE_ACCOUNT.toString(),
      START_BLOCK: startBlock.toString(),
      SCAN_CONFIRMATIONS: '0',
    });
  }

  const alerts: string[] = [];
  const alert = async (k: string, message: string) => {
    alerts.push(k);
    console.log(`[alert] ${k}: ${message}`);
  };

  before(async () => {
    await rpc('anvil_impersonateAccount', [VAULT]);
    for (const address of [VAULT, ...Object.values(KEYS).map((k) => privateKeyToAccount(k).address)]) {
      await rpc('anvil_setBalance', [address, toHex(E18)]);
    }
    startBlock = await client.getBlockNumber();
    // The future half of the enable batch: its cap under the engine.
    await write(VAULT, FUTURE, 'setTotalPositionCap', [ENGINE, 30n * E18]);

    const operator = privateKeyToAccount(KEYS.operator);
    const alice = privateKeyToAccount(KEYS.alice);
    const bob = privateKeyToAccount(KEYS.bob);
    const keeper = privateKeyToAccount(KEYS.keeper);
    accounts.alice = await newAccount(alice, operator.address);
    accounts.bob = await newAccount(bob, operator.address);
    accounts.keeper = await newAccount(keeper);
    await depositCash(alice, accounts.alice, 300n * 10n ** 6n); // 1 contract (~$720 at 0.00072) at 25% IM is ~180 USDC
    await depositCash(bob, accounts.bob, 5_000n * 10n ** 6n);
    await depositCash(keeper, accounts.keeper, 5_000n * 10n ** 6n);

    // Bob sells alice one contract at the mark.
    const contract = (await client.readContract({ address: FUTURE, abi, functionName: 'futureContracts', args: [SUB_ID] })) as readonly unknown[];
    const mark = contract[5] as bigint;
    await write(operator, SUB_ACCOUNTS, 'submitTransfers', [
      [{ fromAcc: accounts.bob, toAcc: accounts.alice, asset: FUTURE, subId: SUB_ID, amount: E18, assetData: pad(toHex(mark), { size: 32 }) }],
      '0x',
    ]);
    // The vault raises the futures margin: alice's maintenance is now half of ~$720, over her 300.
    await write(VAULT, ENGINE, 'setFutureMarginRequirements', [1n, E18 / 2n, (E18 * 6n) / 10n]);
    assert.ok(((await client.readContract({ address: ENGINE, abi, functionName: 'getMargin', args: [accounts.alice, false] })) as bigint) < 0n, 'alice under maintenance');
  });

  it('starts a solvent auction on the engine account under maintenance, and on nobody else', async () => {
    const actions = await runOnce(keeperConfig(), createKeeperChain(keeperConfig()), alert);
    const started = actions.filter((a) => a.kind === 'start').map((a) => a.accountId);
    assert.deepEqual(started, [accounts.alice!], `started ${started}`);
    assert.ok(!started.includes(POOL_ACCOUNT), 'never the VM pool');
    const auction = await auctionOf(accounts.alice!);
    assert.ok(auction.ongoing && !auction.insolvent, 'a solvent auction on alice');
  });

  it('buys into it from a bid account under the engine, and the funding account stays cash only', async () => {
    await runOnce(keeperConfig(), createKeeperChain(keeperConfig()), alert);
    assert.ok((await futureOf(accounts.alice!)) < E18, 'alice partly liquidated');
    assert.equal(await futureOf(accounts.keeper!), 0n, 'the funding account holds no future: the position went to a bid account');
  });
});
