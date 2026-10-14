/**
 * The VM pool's deficit cover (ExpiryKeeper.coverPoolDeficit) against the live MarginEngine and future on a Base fork.
 *
 * Three accounts short one contract each (two hold only USDC, one holds cNGN) against one long of three; the owner
 * marks 1% higher; the long settles itself, so the pool pays it in borrowed USDC (it holds no cNGN). The keeper then
 * runs tick by tick with SETTLE_PER_TICK=2: the USDC payers first, the cap holding, then the cNGN payer. Settlement's
 * rounding leaves the net a few wei of USD below zero, inside POOL_NET_TOLERANCE ($1): covered, so no alert.
 *
 * Usage (from services/perp-feeds): anvil --fork-url <Base RPC> --port 8549 --chain-id 31337, then
 *   pnpm tsx scripts/fork-pool-deficit.ts
 *
 * LOAD=<n> instead runs the mark-under-load check: n USDC-only shorts against one long, the winner settles, and one
 * full tick at the production cap (SETTLE_PER_TICK=10) is timed. Run anvil with --block-time 2 (Base's) for it:
 * forward-main publishes the mark before the deficit cover in each loop, so that tick's length is the most a due
 * mark can wait beyond FORWARD_TICK_MS.
 */
import assert from 'node:assert/strict';

import {
  createPublicClient,
  createTestClient,
  defineChain,
  encodeAbiParameters,
  formatUnits,
  http,
  keccak256,
  parseAbi,
  toHex,
  walletActions,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import { createChain } from '../src/chain.js';
import { ExpiryKeeper } from '../src/expiry-keeper.js';
import { loadForwardConfig } from '../src/forward-config.js';

const RPC = process.env.FORK_RPC ?? 'http://127.0.0.1:8549';
const chain = defineChain({ id: 31337, name: 'base-fork', nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }, rpcUrls: { default: { http: [RPC] } } });
const pub = createPublicClient({ chain, transport: http(RPC) });
const test = createTestClient({ chain, mode: 'anvil', transport: http(RPC) }).extend(walletActions);

const SUBACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843' as Address;
const ENGINE = '0xA19E296021c9DF25b90D96C2A0793CC3D0800758' as Address;
const FUTURE = '0xDCFa4Ee0772647aBd24E8592596b5fe4F001Bc19' as Address;
const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272' as Address;
const ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98' as Address;
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address;
const CNGN = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F' as Address;
const VAULT = '0x1dcA42ab54Bd3862853A821F84B29BF65245F435' as Address;
const SUB_ID = 1796047200n;
const POOL = 31n;
const ONE = 10n ** 18n;
const BALANCE_SLOT: Record<string, bigint> = { [USDC]: 9n, [CNGN]: 201n };

const abi = {
  erc20: parseAbi(['function approve(address,uint256) returns (bool)']),
  wrapper: parseAbi(['function deposit(uint256 recipientAccount, uint256 assetAmount)']),
  sa: parseAbi([
    'struct AssetTransfer { uint256 fromAcc; uint256 toAcc; address asset; uint256 subId; int256 amount; bytes32 assetData; }',
    'function createAccountWithApproval(address owner, address spender, address manager) returns (uint256)',
    'function lastAccountId() view returns (uint256)',
    'function getBalance(uint256,address,uint256) view returns (int256)',
    'function submitTransfer(AssetTransfer assetTransfer, bytes managerData)',
  ]),
  future: parseAbi([
    'struct FutureContract { bool listed; bool settled; uint64 expiry; uint64 lastTradeTime; uint64 lastMarkTime; uint256 markPrice; int256 cumulativeVMPerContract; }',
    'function futureContracts(uint256 subId) view returns (FutureContract)',
    'function setMark(uint96 subId, uint64 markTime, uint256 markPrice)',
    'function getPendingVM(uint256,uint256) view returns (int256)',
  ]),
  engine: parseAbi(['function settleAccount(uint256 accountId)']),
};

const OPERATOR = '0x00000000000000000000000000000000000a11ce' as Address;
const RELAYER_KEY = keccak256(toHex('numo.fork-pool-deficit.relayer')) as Hex;

async function as(address: Address) {
  await test.impersonateAccount({ address });
  await test.setBalance({ address, value: ONE });
  return address;
}
async function send(from: Address, address: Address, abiItems: readonly unknown[], functionName: string, args: readonly unknown[]) {
  const hash = await test.writeContract({ account: from, chain, address, abi: abiItems as never, functionName: functionName as never, args: args as never, gas: 6_000_000n });
  const r = await pub.waitForTransactionReceipt({ hash, pollingInterval: 100 });
  assert.equal(r.status, 'success', `${functionName} (${hash})`);
  return r;
}
const read = <T>(address: Address, abiItems: readonly unknown[], functionName: string, args: readonly unknown[] = []) =>
  pub.readContract({ address, abi: abiItems as never, functionName: functionName as never, args: args as never }) as Promise<T>;
const bal = (acc: bigint, asset: Address, subId = 0n) => read<bigint>(SUBACCOUNTS, abi.sa, 'getBalance', [acc, asset, subId]);

async function deal(token: Address, to: Address, amount: bigint) {
  const index = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [to, BALANCE_SLOT[token]]));
  await test.setStorageAt({ address: token, index, value: toHex(amount, { size: 32 }) });
}
async function deposit(user: Address, acc: bigint, token: Address, wrapper: Address, amount: bigint) {
  await deal(token, user, amount);
  await send(user, token, abi.erc20, 'approve', [wrapper, amount]);
  await send(user, wrapper, abi.wrapper, 'deposit', [acc, amount]);
}
async function open(user: Address) {
  await as(user);
  await send(OPERATOR, SUBACCOUNTS, abi.sa, 'createAccountWithApproval', [user, OPERATOR, ENGINE]);
  return read<bigint>(SUBACCOUNTS, abi.sa, 'lastAccountId');
}

await as(OPERATOR);
await as(VAULT);
const relayer = privateKeyToAccount(RELAYER_KEY);
await test.setBalance({ address: relayer.address, value: ONE });

const poolStart = { cash: await bal(POOL, CASH), cngn: await bal(POOL, ESCROW) };
console.log(`pool #${POOL} at the fork: ${formatUnits(poolStart.cash, 18)} USDC, ${formatUnits(poolStart.cngn, 18)} cNGN`);

const mark0 = (await read<{ markPrice: bigint }>(FUTURE, abi.future, 'futureContracts', [SUB_ID])).markPrice;
const LOAD = Number(process.env.LOAD ?? 0);
if (LOAD > 0) {
  await markUnderLoad(LOAD);
  process.exit(0);
}
const long = await open('0x00000000000000000000000000000000000b0b01');
const shortUsdcA = await open('0x00000000000000000000000000000000000b0b02');
const shortUsdcB = await open('0x00000000000000000000000000000000000b0b03');
const shortCngn = await open('0x00000000000000000000000000000000000b0b04');
await deposit('0x00000000000000000000000000000000000b0b01', long, USDC, CASH, 2_000n * 10n ** 6n);
await deposit('0x00000000000000000000000000000000000b0b02', shortUsdcA, USDC, CASH, 1_000n * 10n ** 6n);
await deposit('0x00000000000000000000000000000000000b0b03', shortUsdcB, USDC, CASH, 1_000n * 10n ** 6n);
await deposit('0x00000000000000000000000000000000000b0b04', shortCngn, USDC, CASH, 1_000n * 10n ** 6n);
await deposit('0x00000000000000000000000000000000000b0b04', shortCngn, CNGN, ESCROW, 1_000_000n * 10n ** 6n);
for (const seller of [shortUsdcA, shortUsdcB, shortCngn]) {
  await send(OPERATOR, SUBACCOUNTS, abi.sa, 'submitTransfer', [
    { fromAcc: seller, toAcc: long, asset: FUTURE, subId: SUB_ID, amount: ONE, assetData: toHex(mark0, { size: 32 }) },
    '0x',
  ]);
}
await test.increaseTime({ seconds: 60 });
await test.mine({ blocks: 1 });
await send(VAULT, FUTURE, abi.future, 'setMark', [SUB_ID, (await pub.getBlock()).timestamp, (mark0 * 101n) / 100n]);
console.log(`accounts: long #${long} (3), shorts #${shortUsdcA} and #${shortUsdcB} (USDC only), #${shortCngn} (holds cNGN); marked +1%`);

// The winner settles itself (as a trade or withdrawal would): the pool pays it at once.
await send(OPERATOR, ENGINE, abi.engine, 'settleAccount', [long]);
const net = async () => {
  const [cash, cngn] = [await bal(POOL, CASH), await bal(POOL, ESCROW)];
  return { cash, cngn };
};
const afterWinner = await net();
console.log(`winner settled: pool ${formatUnits(afterWinner.cash, 18)} USDC, ${formatUnits(afterWinner.cngn, 18)} cNGN`);

// The keeper, built from this branch, against the fork: anvil's chain id lets it take a raw signer key.
const config = loadForwardConfig({
  RPC_URL: RPC,
  CHAIN_ID: '31337',
  RELAYER_KEY,
  FORWARD_SIGNER_KEY: keccak256(toHex('numo.fork-pool-deficit.forward')),
  DATA_SUBMITTER: '0xe0C06DD245f1e8C8bC516c66C66e64648987F912',
  INDEX_FEED: '0xFaC420d160C7c219A72DC676971670980bAC20a5',
  FORWARD_FEED: '0xbB34Ee2435f050b6B7e46D6C3F8247EA77d6ffA6',
  FUTURE_ASSET: FUTURE,
  FUTURE_SUB_ID: String(SUB_ID),
  FUTURE_MANAGER: ENGINE,
  CARRY: '118000000000000000',
  SETTLE_PER_TICK: '2',
});
const alerts: string[] = [];
const keeper = new ExpiryKeeper(config, createChain(config, privateKeyToAccount(config.FORWARD_SIGNER_KEY as Hex)), async (key, message) => {
  alerts.push(key);
  console.log(`  alert ${key}: ${message}`);
});

const txsBefore = await pub.getTransactionCount({ address: relayer.address });
for (let tick = 1; tick <= 4; tick++) {
  const outcome = await keeper.coverPoolDeficit();
  const pool = await net();
  console.log(`tick ${tick}: settled ${outcome.settled}, stranded ${outcome.stranded}, net $${formatUnits(outcome.netUsd ?? 0n, 18)}; pool ${formatUnits(pool.cash, 18)} USDC, ${formatUnits(pool.cngn, 18)} cNGN`);
  await test.mine({ blocks: 1 });
}
const sent = (await pub.getTransactionCount({ address: relayer.address })) - txsBefore;
for (const acc of [shortUsdcA, shortUsdcB, shortCngn]) {
  assert.equal(await read<bigint>(FUTURE, abi.future, 'getPendingVM', [acc, SUB_ID]), 0n, `loser #${acc} settled`);
}
console.log(`relayer sent ${sent} settlements; alerts: ${JSON.stringify(alerts)}`);

// Gas of each settlement the keeper sent: the relayer's transactions on the fork.
const head = await pub.getBlockNumber();
for (let b = head - 12n; b <= head; b++) {
  const block = await pub.getBlock({ blockNumber: b, includeTransactions: true });
  for (const tx of block.transactions) {
    if (tx.from.toLowerCase() !== relayer.address.toLowerCase()) continue;
    const r = await pub.getTransactionReceipt({ hash: tx.hash });
    console.log(`  keeper settlement ${tx.hash.slice(0, 10)}: gas ${r.gasUsed}`);
  }
}

/** n USDC-only shorts of one contract against one long of n; the long settles; one production tick is timed. */
async function markUnderLoad(n: number) {
  const user = (i: number) => `0x00000000000000000000000000000000000c${(0x1000 + i).toString(16)}` as Address;
  const long = await open(user(0));
  await deposit(user(0), long, USDC, CASH, BigInt(n) * 500n * 10n ** 6n);
  const shorts: bigint[] = [];
  for (let i = 1; i <= n; i++) {
    const acc = await open(user(i));
    await deposit(user(i), acc, USDC, CASH, 1_000n * 10n ** 6n);
    await send(OPERATOR, SUBACCOUNTS, abi.sa, 'submitTransfer', [
      { fromAcc: acc, toAcc: long, asset: FUTURE, subId: SUB_ID, amount: ONE, assetData: toHex(mark0, { size: 32 }) },
      '0x',
    ]);
    shorts.push(acc);
  }
  await test.increaseTime({ seconds: 60 });
  await test.mine({ blocks: 1 });
  await send(VAULT, FUTURE, abi.future, 'setMark', [SUB_ID, (await pub.getBlock()).timestamp, (mark0 * 101n) / 100n]);
  await send(OPERATOR, ENGINE, abi.engine, 'settleAccount', [long]);
  console.log(`load: ${n} USDC-only losers, pool ${formatUnits(await bal(POOL, CASH), 18)} USDC after the winner settled`);
  const config = loadForwardConfig({
    RPC_URL: RPC,
    CHAIN_ID: '31337',
    RELAYER_KEY,
    FORWARD_SIGNER_KEY: keccak256(toHex('numo.fork-pool-deficit.forward')),
    DATA_SUBMITTER: '0xe0C06DD245f1e8C8bC516c66C66e64648987F912',
    INDEX_FEED: '0xFaC420d160C7c219A72DC676971670980bAC20a5',
    FORWARD_FEED: '0xbB34Ee2435f050b6B7e46D6C3F8247EA77d6ffA6',
    FUTURE_ASSET: FUTURE,
    FUTURE_SUB_ID: String(SUB_ID),
    FUTURE_MANAGER: ENGINE,
    CARRY: '118000000000000000',
  });
  const keeper = new ExpiryKeeper(config, createChain(config, privateKeyToAccount(config.FORWARD_SIGNER_KEY as Hex)), async (key) => {
    console.log(`  alert ${key}`);
  });
  const started = Date.now();
  const outcome = await keeper.coverPoolDeficit();
  const seconds = (Date.now() - started) / 1000;
  console.log(`load: one tick settled ${outcome.settled} (cap ${config.SETTLE_PER_TICK}) in ${seconds.toFixed(1)}s, net $${formatUnits(outcome.netUsd ?? 0n, 18)}`);
  console.log(`load: a mark due just after the publisher ran waits FORWARD_TICK_MS (${config.FORWARD_TICK_MS / 1000}s) + ${seconds.toFixed(1)}s; minMarkInterval 3600s, FORWARD_MARK_LATE_MS ${config.FORWARD_MARK_LATE_MS / 1000}s`);
}
