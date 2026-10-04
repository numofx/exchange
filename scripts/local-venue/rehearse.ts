/**
 * The chain side of rehearse-mainnet.sh: prepares a fork of Base (served as chain 31337) holding the
 * REAL deployed perp stack, so the production keeper build can liquidate on it with its production
 * account. Every command refuses a chain that is not 31337, and every state change here is made by
 * anvil impersonation or a fork-only key: none of it is valid on Base.
 *
 *   tsx rehearse.ts <rpc> <stack.json> <module.json> <state-dir> check-fork
 *   ... open-market                 vault (impersonated): the enable actions, a fork-only feed signer,
 *                                   a SecurityModule seed if the fork's is short
 *   ... positions                   alice (ends insolvent) and carol (ends under margin, solvent)
 *                                   long the perp against bob
 *   ... prices <ngnPerUsdcOrZero>   index + zero diffs from the fork signer (0 = the current index)
 *   ... crash <bps>                 the index <bps> lower in USDC per cNGN (cNGN weakens), fresh
 *   ... warp <seconds>
 *   ... status                      JSON: positions, SecurityModule cash
 *   ... verify-keeper-txs <keeper-address> <from-block>
 *                                   every transaction the keeper sent is signed for chain 31337
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';

import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  getAddress,
  hashDomain,
  http,
  keccak256,
  pad,
  parseAbi,
  toHex,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount, type PrivateKeyAccount } from 'viem/accounts';

const LOCAL_CHAIN_ID = 31337;
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address;
const USDC_BALANCE_SLOT = 9n;
const SUB_ACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843' as Address;
const VAULT = '0x1dcA42ab54Bd3862853A821F84B29BF65245F435' as Address;
const E18 = 10n ** 18n;

const [rpc, stackFile, moduleFile, stateDir, command, ...args] = process.argv.slice(2);
if (!rpc || !stackFile || !moduleFile || !stateDir || !command) {
  throw new Error('usage: rehearse.ts <rpc> <stack.json> <module.json> <state-dir> <command> ...');
}
type Stack = Record<string, string | number | string[]>;
const stack = JSON.parse(readFileSync(stackFile, 'utf8')) as Stack;
const moduleArtifact = JSON.parse(readFileSync(moduleFile, 'utf8')) as Record<string, string>;
const addr = (key: string) => getAddress(String(stack[key]));
const PERP = addr('perp');
const SRM = addr('srm');
const CASH = addr('cash');
const FEEDS = { index: addr('indexFeed'), mark: addr('markFeed'), impactAsk: addr('impactAskFeed'), impactBid: addr('impactBidFeed') };
const MODULE = getAddress(moduleArtifact.tradePerp!);
// The perp's cNGN collateral escrow (CNGN_PERP_COLLATERAL.json beside the stack artifact), when
// deployed: the cNGN scenario rehearses against the real one.
const collateralFile = join(dirname(stackFile), 'CNGN_PERP_COLLATERAL.json');
const collateral = existsSync(collateralFile) ? (JSON.parse(readFileSync(collateralFile, 'utf8')) as Record<string, string>) : null;
const ESCROW = collateral ? getAddress(collateral.escrow!) : null;
// Base cNGN, an upgradeable proxy whose balances mapping sits at slot 201 (venue.ts, found with stdstore).
const CNGN = getAddress('0x46C85152bFe9f96829aA94755D9f915F9B10EF5F');
const CNGN_BALANCE_SLOT = 201n;
const MATCHING = getAddress(moduleArtifact.matching ?? '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191');

const chain = defineChain({
  id: LOCAL_CHAIN_ID,
  name: 'rehearsal-fork',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
});
const client = createPublicClient({ chain, transport: http(rpc) });

// The one guard everything else rests on: this must be the local fork, never Base.
const reported = await client.getChainId();
if (reported !== LOCAL_CHAIN_ID) throw new Error(`refusing: ${rpc} reports chain ${reported}, not ${LOCAL_CHAIN_ID}`);

const abi = parseAbi([
  'function setTotalPositionCap(address manager, uint256 cap)',
  'function totalPositionCap(address manager) view returns (uint256)',
  'function setAllowedModule(address module, bool allowed)',
  'function addSigner(address signer, bool isSigner)',
  'function domainSeparator() view returns (bytes32)',
  'function acceptData(bytes data)',
  'function getSpot() view returns (uint256, uint256)',
  'function approve(address, uint256) returns (bool)',
  'function deposit(uint256 recipientAccount, uint256 stableAmount)',
  'function donate(uint256 stableAmount)',
  'function createAccountWithApproval(address owner, address spender, address manager) returns (uint256)',
  'function lastAccountId() view returns (uint256)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function getAuction(uint256 accountId) view returns ((uint256 accountId, uint256 scenarioId, bool insolvent, bool ongoing, uint256 cachedMM, uint256 startTime, uint256 reservedCash))',
  'function getMarginAndMarkToMarket(uint256 accountId, uint256 scenarioId) view returns (int256 mm, int256 bm, int256 mtm)',
  'function submitTransfers((uint256 fromAcc, uint256 toAcc, address asset, uint256 subId, int256 amount, bytes32 assetData)[] transfers, bytes managerData) returns (uint256)',
  'function whitelistedManager(address manager) view returns (bool)',
  'function setWhitelistManager(address manager, bool whitelisted)',
  'function balanceOf(address) view returns (uint256)',
]);

const keyFor = (label: string) => privateKeyToAccount(keccak256(toHex(`numo.rehearsal.${label}`)));
const FORK_SIGNER = keyFor('feed-signer');
const accountsFile = join(stateDir, 'rehearsal-accounts.json');
const readAccounts = (): Record<string, string> => {
  try {
    return JSON.parse(readFileSync(accountsFile, 'utf8')) as Record<string, string>;
  } catch {
    return {};
  }
};

/**
 * Gas for a send: 1.5x the estimate and at least +100k, as every production sender into the perp
 * stack does. The perp cash's interest accrual costs more in the block a transaction lands in than
 * in the block it was estimated against; an exact estimate runs out of gas (it did, here, on a
 * createAndDepositSubAccount: 413,685 used of 414,210).
 */
function withGasHeadroom(estimate: bigint): bigint {
  const scaled = (estimate * 150n) / 100n;
  return scaled > estimate + 100_000n ? scaled : estimate + 100_000n;
}

async function anvil(method: string, params: unknown[]) {
  return client.request({ method: method as never, params: params as never });
}

async function write(from: PrivateKeyAccount | Address, address: Address, functionName: string, fnArgs: unknown[]) {
  const wallet = createWalletClient({ account: from, chain, transport: http(rpc) });
  const estimate = await client.estimateContractGas({ address, abi, functionName: functionName as never, args: fnArgs as never, account: from as never });
  const hash = await wallet.writeContract({
    address,
    abi,
    functionName: functionName as never,
    args: fnArgs as never,
    chain,
    account: from as never,
    gas: withGasHeadroom(estimate),
  });
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`${functionName} on ${address} reverted (${hash})`);
}

async function asVault(address: Address, functionName: string, fnArgs: unknown[]) {
  await anvil('anvil_impersonateAccount', [VAULT]);
  await anvil('anvil_setBalance', [VAULT, toHex(E18)]);
  await write(VAULT, address, functionName, fnArgs);
}

async function funded(label: string, usdcWhole = 0n) {
  const account = keyFor(label);
  await anvil('anvil_setBalance', [account.address, toHex(E18)]);
  if (usdcWhole > 0n) {
    const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account.address, USDC_BALANCE_SLOT]));
    await anvil('anvil_setStorageAt', [USDC, slot, pad(toHex(usdcWhole * 10n ** 6n), { size: 32 })]);
  }
  return account;
}

/** Every contract whose EIP-712 domain anything signs against on the fork rebuilds it for 31337. */
async function checkFork() {
  const code = await client.getCode({ address: PERP });
  if (!code || code === '0x') throw new Error(`no perp at ${PERP} on the fork: is the stack deployed and the fork taken after it?`);
  const domains: [string, Address, string][] = [
    ['index feed', FEEDS.index, 'LyraSpotFeed'],
    ['mark feed', FEEDS.mark, 'LyraSpotDiffFeed'],
    ['impact ask feed', FEEDS.impactAsk, 'LyraSpotDiffFeed'],
    ['impact bid feed', FEEDS.impactBid, 'LyraSpotDiffFeed'],
    ['Matching', MATCHING, 'Matching'],
  ];
  for (const [label, address, name] of domains) {
    const version = name === 'Matching' ? '1.0' : '1';
    const onChain = await client.readContract({ address, abi, functionName: 'domainSeparator' });
    const forFork = hashDomain({ domain: { name, version, chainId: BigInt(LOCAL_CHAIN_ID), verifyingContract: address }, types: { EIP712Domain: DOMAIN_TYPES } });
    const forBase = hashDomain({ domain: { name, version, chainId: 8453n, verifyingContract: address }, types: { EIP712Domain: DOMAIN_TYPES } });
    if (onChain !== forFork) throw new Error(`${label}: domain separator ${onChain} is not the 31337 one (${forFork})`);
    if (onChain === forBase) throw new Error(`${label}: domain separator is still Base's`);
    console.log(`ok: ${label} rebuilds its EIP-712 domain for 31337 (not Base's 8453)`);
  }
}
const DOMAIN_TYPES = [
  { name: 'name', type: 'string' },
  { name: 'version', type: 'string' },
  { name: 'chainId', type: 'uint256' },
  { name: 'verifyingContract', type: 'address' },
] as const;

async function openMarket() {
  const cap = await client.readContract({ address: PERP, abi, functionName: 'totalPositionCap', args: [SRM] });
  if (cap === 0n) {
    // The enable batch's two actions, as the vault will sign them on Base.
    await asVault(PERP, 'setTotalPositionCap', [SRM, BigInt(String(stack.launchOICap ?? 50_000_000n * E18))]);
    await asVault(MATCHING, 'setAllowedModule', [MODULE, true]);
    console.log('fork: enable actions applied as the vault');
  } else {
    console.log(`fork: market already open (cap ${cap})`);
  }
  for (const feed of Object.values(FEEDS)) await asVault(feed, 'addSigner', [FORK_SIGNER.address, true]);
  console.log(`fork: added fork-only feed signer ${FORK_SIGNER.address}`);

  const smAccount = BigInt(String(stack.securityModuleAccount));
  const smCash = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [smAccount, CASH, 0n] });
  if (smCash < 5_000n * E18) {
    const donor = await funded('sm-donor', 10_000n);
    await write(donor, USDC, 'approve', [addr('securityModule'), 10_000n * 10n ** 6n]);
    await write(donor, addr('securityModule'), 'donate', [10_000n * 10n ** 6n]);
    console.log('fork: SecurityModule seeded with $10,000 (fork only)');
  }
}

async function signed(feed: Address, name: string, data: Hex, timestamp: bigint) {
  const deadline = timestamp + 3_600n;
  const signature = await FORK_SIGNER.signTypedData({
    domain: { name, version: '1', chainId: LOCAL_CHAIN_ID, verifyingContract: feed },
    types: { FeedData: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }] },
    primaryType: 'FeedData',
    message: { data, deadline, timestamp },
  });
  return encodeAbiParameters(
    [{ type: 'tuple', components: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }, { name: 'signers', type: 'address[]' }, { name: 'signatures', type: 'bytes[]' }] }],
    [{ data, deadline, timestamp, signers: [FORK_SIGNER.address], signatures: [signature] }],
  );
}

/** Index at `ngnPerUsdc` (0 = the current on-chain index) and zero mark/impact diffs, fresh. */
async function prices(ngnPerUsdc: bigint, crashBps = 0n) {
  // 0 re-signs the level last published here (after a long warp the on-chain index is stale and
  // getSpot reverts), else the live on-chain index.
  const lastFile = join(stateDir!, 'rehearsal-index');
  let index: bigint;
  if (ngnPerUsdc > 0n) index = E18 / ngnPerUsdc;
  else {
    let last: bigint | null = null;
    try {
      last = BigInt(readFileSync(lastFile, 'utf8').trim());
    } catch {
      last = null;
    }
    index = last ?? (await client.readContract({ address: FEEDS.index, abi, functionName: 'getSpot' }))[0];
  }
  index = (index * (10_000n - crashBps)) / 10_000n;
  writeFileSync(lastFile, index.toString());
  const head = (await client.getBlock()).timestamp;
  const publisher = await funded('publisher');
  const confidence = E18;
  await write(publisher, FEEDS.index, 'acceptData', [await signed(FEEDS.index, 'LyraSpotFeed', encodeAbiParameters([{ type: 'uint96' }, { type: 'uint64' }], [index, confidence]), head)]);
  for (const feed of [FEEDS.mark, FEEDS.impactAsk, FEEDS.impactBid]) {
    await write(publisher, feed, 'acceptData', [await signed(feed, 'LyraSpotDiffFeed', encodeAbiParameters([{ type: 'int96' }, { type: 'uint64' }], [0n, confidence]), head)]);
  }
  console.log(`fork: published index ${index} (${E18 / index} cNGN/USDC), zero diffs`);
}

async function positions() {
  const operator = await funded('operator');
  const newAccount = async (label: string, usdcWhole: bigint) => {
    const owner = await funded(label, usdcWhole);
    await write(owner, SUB_ACCOUNTS, 'createAccountWithApproval', [owner.address, operator.address, SRM]);
    const id = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'lastAccountId' });
    await write(owner, USDC, 'approve', [CASH, usdcWhole * 10n ** 6n]);
    await write(owner, CASH, 'deposit', [id, usdcWhole * 10n ** 6n]);
    return id;
  };
  // At ~1374 cNGN/USDC, 10M cNGN is ~$7,280 of notional: alice at ~3x ends insolvent after a 40%
  // fall; carol, with more margin, ends under maintenance but solvent.
  const accounts = { alice: await newAccount('alice', 2_500n), carol: await newAccount('carol', 3_500n), bob: await newAccount('bob', 40_000n) };
  writeFileSync(accountsFile, JSON.stringify(Object.fromEntries(Object.entries(accounts).map(([k, v]) => [k, v.toString()])), null, 2));
  const size = 10_000_000n * E18;
  const transfer = (to: bigint) => ({ fromAcc: accounts.bob, toAcc: to, asset: PERP, subId: 0n, amount: size, assetData: pad('0x', { size: 32 }) });
  await write(operator, SUB_ACCOUNTS, 'submitTransfers', [[transfer(accounts.alice), transfer(accounts.carol)], '0x']);
  console.log(`fork: alice #${accounts.alice} and carol #${accounts.carol} long 10M cNGN each against bob #${accounts.bob}`);
}

/** Batch 5 on the FORK only: the real escrow opens to the SRM, as the vault will sign it on Base. */
async function cngnOpen() {
  if (ESCROW === null) throw new Error(`no ${collateralFile}: the cNGN escrow is not deployed`);
  const open = await client.readContract({ address: ESCROW, abi, functionName: 'whitelistedManager', args: [SRM] });
  if (open) {
    console.log('fork: cNGN escrow already open to the SRM');
    return;
  }
  await asVault(ESCROW, 'setWhitelistManager', [SRM, true]);
  console.log(`fork: escrow ${ESCROW} opened to the SRM as the vault (batch 5, fork only)`);
}

/** Gives `label` `cngnWhole` cNGN at the proxy's balance slot and returns its (gas-funded) key. */
async function fundedCngn(label: string, cngnWhole: bigint) {
  const account = await funded(label);
  const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account.address, CNGN_BALANCE_SLOT]));
  await anvil('anvil_setStorageAt', [CNGN, slot, pad(toHex(cngnWhole * 10n ** 6n), { size: 32 })]);
  const held = await client.readContract({ address: CNGN, abi, functionName: 'balanceOf', args: [account.address] });
  if (held !== cngnWhole * 10n ** 6n) throw new Error(`cNGN balance slot moved: set ${cngnWhole}, read ${held}`);
  return account;
}

/**
 * The cNGN scenario, on the real escrow:
 *   treasury: 2M cNGN posted, long USD 1:1 against it (the venue's allowed use) -- must ride the
 *             40% fall out above maintenance margin with its cNGN intact;
 *   dave:     a directly-created account that posts 1M cNGN and goes long NAIRA (the venue refuses
 *             this; the chain does not) at the IM the haircut allows -- insolvent or nearly so after
 *             the fall, so the production keeper has to bid on a cNGN portfolio at its haircut and
 *             end up holding the cNGN.
 */
async function cngnPositions() {
  if (ESCROW === null) throw new Error(`no ${collateralFile}: the cNGN escrow is not deployed`);
  const accounts = readAccounts();
  if (!accounts.bob) throw new Error('run positions first: bob is the counterparty');
  const operator = keyFor('operator');
  const newCngnAccount = async (label: string, cngnWhole: bigint) => {
    const owner = await fundedCngn(label, cngnWhole);
    await write(owner, SUB_ACCOUNTS, 'createAccountWithApproval', [owner.address, operator.address, SRM]);
    const id = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'lastAccountId' });
    await write(owner, CNGN, 'approve', [ESCROW, cngnWhole * 10n ** 6n]);
    await write(owner, ESCROW, 'deposit', [id, cngnWhole * 10n ** 6n]);
    return id;
  };
  const treasury = await newCngnAccount('treasury', 2_000_000n);
  const dave = await newCngnAccount('dave', 1_000_000n);
  writeFileSync(accountsFile, JSON.stringify({ ...accounts, treasury: treasury.toString(), dave: dave.toString() }, null, 2));
  const bob = BigInt(accounts.bob);
  const transfers = [
    // treasury short naira (long USD) 1.98M cNGN: 1:1 with its collateral, a hair under.
    { fromAcc: treasury, toAcc: bob, asset: PERP, subId: 0n, amount: 1_980_000n * E18, assetData: pad('0x', { size: 32 }) },
    // dave long naira 1.49M cNGN on 1M cNGN of collateral: IM credit 0.5M against 0.497M needed.
    { fromAcc: bob, toAcc: dave, asset: PERP, subId: 0n, amount: 1_490_000n * E18, assetData: pad('0x', { size: 32 }) },
  ];
  await write(operator, SUB_ACCOUNTS, 'submitTransfers', [transfers, '0x']);
  console.log(`fork: treasury #${treasury} long USD 1.98M cNGN on 2M cNGN; dave #${dave} long naira 1.49M cNGN on 1M cNGN (the backstop case)`);
}

/**
 * The unified scenario, on the real escrow: one account under the perp SRM holding USDC cash AND
 * cNGN (its spot holding, which is the same escrow balance as margin) with a long-naira perp
 * position sized so the 40% fall leaves it insolvent. The production keeper must take the whole
 * portfolio, cNGN included, and the SecurityModule pays the auction's terminal deficit. Sized
 * inside the fork's 50M OI cap: the base scenario already carries 40M of it.
 */
async function unifiedPositions() {
  if (ESCROW === null) throw new Error(`no ${collateralFile}: the cNGN escrow is not deployed`);
  const accounts = readAccounts();
  if (!accounts.bob) throw new Error('run positions first: bob is the counterparty');
  const operator = keyFor('operator');
  const owner = await funded('mixed', 800n);
  const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [owner.address, CNGN_BALANCE_SLOT]));
  await anvil('anvil_setStorageAt', [CNGN, slot, pad(toHex(500_000n * 10n ** 6n), { size: 32 })]);
  await write(owner, SUB_ACCOUNTS, 'createAccountWithApproval', [owner.address, operator.address, SRM]);
  const id = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'lastAccountId' });
  await write(owner, USDC, 'approve', [CASH, 800n * 10n ** 6n]);
  await write(owner, CASH, 'deposit', [id, 800n * 10n ** 6n]);
  await write(owner, CNGN, 'approve', [ESCROW, 500_000n * 10n ** 6n]);
  await write(owner, ESCROW, 'deposit', [id, 500_000n * 10n ** 6n]);
  writeFileSync(accountsFile, JSON.stringify({ ...accounts, mixed: id.toString() }, null, 2));
  // Long naira 4M cNGN (~$2,900 at 1374) on $800 cash + 500k cNGN credited at half ($982 of IM credit
  // against $971 needed at 3x): opens, and is insolvent after a 40% fall on both the position and the
  // collateral (800 - 1,165 + 218 = -$147).
  const transfer = { fromAcc: BigInt(accounts.bob), toAcc: id, asset: PERP, subId: 0n, amount: 4_000_000n * E18, assetData: pad('0x', { size: 32 }) };
  await write(operator, SUB_ACCOUNTS, 'submitTransfers', [[transfer], '0x']);
  console.log(`fork: mixed #${id} holds $800 cash + 500k cNGN and is long naira 4M cNGN (the unified account)`);
}

async function status() {
  const accounts = readAccounts();
  const smAccount = BigInt(String(stack.securityModuleAccount));
  const perpOf = async (id: string) => (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [BigInt(id), PERP, 0n] })).toString();
  const auction = addr('auction');
  const carolAuction = await client.readContract({ address: auction, abi, functionName: 'getAuction', args: [BigInt(accounts.carol!)] });
  const [carolMM] = await client.readContract({ address: auction, abi, functionName: 'getMarginAndMarkToMarket', args: [BigInt(accounts.carol!), 0n] });
  const out = {
    alice: await perpOf(accounts.alice!),
    carol: await perpOf(accounts.carol!),
    carolInAuction: carolAuction.ongoing,
    carolAboveMaintenance: carolMM >= 0n,
    securityModuleCash: (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [smAccount, CASH, 0n] })).toString(),
    // alice's maintenance margin, signed: her insolvent auction is also paid by the SecurityModule.
    aliceMaintenanceMargin: (await client.readContract({ address: auction, abi, functionName: 'getMarginAndMarkToMarket', args: [BigInt(accounts.alice!), 0n] }))[0].toString(),
    ...(accounts.mixed && ESCROW
      ? {
          mixed: await perpOf(accounts.mixed),
          mixedCngn: (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [BigInt(accounts.mixed), ESCROW, 0n] })).toString(),
          mixedInAuction: (await client.readContract({ address: auction, abi, functionName: 'getAuction', args: [BigInt(accounts.mixed)] })).ongoing,
          // The SRM's maintenance margin, signed: negative is the deficit an insolvent auction ends at.
          mixedMaintenanceMargin: (await client.readContract({ address: auction, abi, functionName: 'getMarginAndMarkToMarket', args: [BigInt(accounts.mixed), 0n] }))[0].toString(),
        }
      : {}),
    ...(accounts.treasury && ESCROW
      ? {
          treasury: await perpOf(accounts.treasury),
          treasuryCngn: (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [BigInt(accounts.treasury), ESCROW, 0n] })).toString(),
          treasuryAboveMaintenance: (await client.readContract({ address: auction, abi, functionName: 'getMarginAndMarkToMarket', args: [BigInt(accounts.treasury), 0n] }))[0] >= 0n,
          dave: await perpOf(accounts.dave!),
          daveInAuction: (await client.readContract({ address: auction, abi, functionName: 'getAuction', args: [BigInt(accounts.dave!)] })).ongoing,
        }
      : {}),
  };
  console.log(JSON.stringify(out));
}

async function verifyKeeperTxs(keeper: Address, fromBlock: bigint) {
  const head = await client.getBlockNumber();
  let count = 0;
  for (let n = fromBlock; n <= head; n++) {
    const block = await client.getBlock({ blockNumber: n, includeTransactions: true });
    for (const tx of block.transactions) {
      if (tx.from.toLowerCase() !== keeper.toLowerCase()) continue;
      count += 1;
      if (tx.chainId !== LOCAL_CHAIN_ID) throw new Error(`keeper tx ${tx.hash} is signed for chain ${tx.chainId}, not ${LOCAL_CHAIN_ID}`);
    }
  }
  if (count === 0) throw new Error('the keeper sent no transactions on the fork');
  console.log(`ok: all ${count} keeper transactions are signed for chain ${LOCAL_CHAIN_ID}: none is valid on Base`);
}

switch (command) {
  case 'check-fork':
    await checkFork();
    break;
  case 'open-market':
    await openMarket();
    break;
  case 'positions':
    await positions();
    break;
  case 'cngn-open':
    await cngnOpen();
    break;
  case 'unified-positions':
    await unifiedPositions();
    break;
  case 'cngn-positions':
    await cngnPositions();
    break;
  case 'prices':
    await prices(BigInt(args[0] ?? '0'));
    break;
  case 'crash':
    await prices(0n, BigInt(args[0] ?? '4000'));
    break;
  case 'warp':
    await anvil('evm_increaseTime', [Number(args[0] ?? '60')]);
    await anvil('evm_mine', []);
    break;
  case 'status':
    await status();
    break;
  case 'verify-keeper-txs':
    await verifyKeeperTxs(getAddress(args[0]!), BigInt(args[1] ?? '0'));
    break;
  default:
    throw new Error(`unknown command ${command}`);
}
