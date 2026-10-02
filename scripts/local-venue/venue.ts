/**
 * The local venue's chain and order steps, for up.sh: perp accounts, the SecurityModule seed, a
 * two-sided quote and a crossing order, each signed the way trading-app signs them.
 *
 * Every command reads the chain id from the RPC first and refuses anything but anvil's 31337. All
 * keys are derived from fixed labels, and USDC is minted by writing its storage: none of it means
 * anything on a real network, and none of it can reach one.
 *
 *   tsx venue.ts <state-dir> account <label> <usdc>   open a perp account (createAndDepositSubAccount)
 *   tsx venue.ts <state-dir> keeper-account <usdc>     the keeper's funding account: created by and owned by
 *                                                       the keeper EOA (not through Matching), then deposited
 *   tsx venue.ts <state-dir> spot-account <label> <usdc|cngn> <whole>   spot account under the spot SRM
 *   tsx venue.ts <state-dir> spot-deposit <label> <usdc|cngn> <whole>   add to an existing spot account
 *   tsx venue.ts <state-dir> spot-quote <label> <buy|sell> <price> <usd> rest a spot order
 *   tsx venue.ts <state-dir> spot-cross [price] [usd] / spot-withdraw <label> <usdc>   spot regression
 *   tsx venue.ts <state-dir> withdraw <label> <usdc>   a perp account withdraws margin (WithdrawalModule, perp cash)
 *   tsx venue.ts <state-dir> fund-sm <usdc>            donate to the stack's SecurityModule
 *   tsx venue.ts <state-dir> quote                      maker rests a bid and an ask 0.5% around the index
 *   tsx venue.ts <state-dir> cross                      taker lifts the maker's offer; waits for the position
 *   tsx venue.ts <state-dir> fill-cap                   opens the rest of the OI cap: an NGN long at ~3x
 *                                                       ("ngn-long") against a well-funded NGN short
 *   tsx venue.ts <state-dir> report                     positions, cash, SecurityModule, exchange rate, OI
 *   tsx venue.ts <state-dir> wait-closed <label> <sec>  waits for an account's perp position to reach 0
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  defineChain,
  encodeAbiParameters,
  formatUnits,
  getAddress,
  http,
  keccak256,
  pad,
  parseAbi,
  toHex,
  type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const LOCAL_CHAIN_ID = 31337;
const RPC = process.env.LOCAL_VENUE_RPC ?? 'http://127.0.0.1:8600';
const MARKETS = process.env.LOCAL_VENUE_MARKETS ?? 'http://127.0.0.1:8090';

// Base mainnet addresses the fork inherits.
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const USDC_BALANCE_SLOT = 9n;
// Base cNGN (an upgradeable proxy): its balances mapping sits at slot 201 of the implementation's
// layout (found with stdstore on a fork, 2026-10-02).
const CNGN = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F';
const CNGN_BALANCE_SLOT = 201n;
const MATCHING = '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191';
const SUB_ACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843';
const SUBACCOUNT_CREATOR = '0x568890A8D63Ba8a03b6eCbEedA1bD9f6ea014D5D';

/** The app's taker fee bound, as a rate of USD notional (trading-app SPOT_TAKER_FEE_RATE). */
const WORST_FEE_RATE_E18 = 3n * 10n ** 15n;

const abi = parseAbi([
  'function approve(address, uint256) returns (bool)',
  'function transfer(address, uint256) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function decimals() view returns (uint8)',
  'function createAndDepositSubAccount(address baseAsset, uint256 initDeposit, address manager) returns (uint256)',
  'function donate(uint256 amount)',
  'function createAccount(address owner, address manager) returns (uint256)',
  'function deposit(uint256 recipientAccount, uint256 amount)',
  'event AccountCreated(address indexed owner, uint256 indexed accountId, address indexed manager)',
  'function getSpot() view returns (uint256, uint256)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function totalPosition(address manager) view returns (uint256)',
  'function totalPositionCap(address manager) view returns (uint256)',
  'function getCashToStableExchangeRate() view returns (uint256)',
  'function getAuction(uint256 accountId) view returns ((uint256 accountId, uint256 scenarioId, bool insolvent, bool ongoing, uint256 cachedMM, uint256 startTime, uint256 reservedCash))',
  'function getMarginAndMarkToMarket(uint256 accountId, uint256 scenarioId) view returns (int256 mm, int256 bm, int256 mtm)',
  'event DepositedSubAccount(uint256 indexed accountId, address indexed owner)',
]);

type Venue = {
  perp: Address;
  cash: Address;
  srm: Address;
  auction: Address;
  /** The perp's cNGN collateral escrow; absent until up.sh has deployed and enabled it. */
  cngnEscrow?: Address;
  securityModule: Address;
  securityModuleAccount: number;
  indexFeed: Address;
  tradePerp: Address;
};
type Accounts = Record<string, string>;

const [stateDir, command, ...args] = process.argv.slice(2);
if (!stateDir || !command) throw new Error('usage: venue.ts <state-dir> <account|fund-sm|quote|cross> ...');
// The perp stack's addresses. Absent in --spot-only runs, which deploy no perp: only the perp
// commands read it, so a spot run never touches it.
const venue = new Proxy({} as Venue, {
  get(_target, key: string) {
    const loaded = JSON.parse(readFileSync(join(stateDir!, 'venue.json'), 'utf8')) as Venue;
    return loaded[key as keyof Venue];
  },
});

/** What an order is signed for: the traded asset and the TradeModule that settles it. */
type OrderMarket = { asset: Address; module: Address; label: string };
const perpMarket = (): OrderMarket => ({ asset: getAddress(venue.perp), module: getAddress(venue.tradePerp), label: 'perp' });
// Base mainnet spot, which the fork inherits: the cNGN escrow is the spot asset, the wrapped-quote
// TradeModule settles it against wrapped USDC, and accounts live under the spot SRM.
const SPOT = {
  asset: getAddress('0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493'),
  module: getAddress('0x12423B366F6F07130961900bE00d05Ea63Acd071'),
  wrappedUsdc: getAddress('0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84'),
  cngnToken: getAddress('0x46C85152bFe9f96829aA94755D9f915F9B10EF5F'),
  srm: getAddress('0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b'),
  withdrawalModule: getAddress('0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB'),
};
const spotMarket = (): OrderMarket => ({ asset: SPOT.asset, module: SPOT.module, label: 'spot' });
const accountsFile = join(stateDir, 'accounts.json');

const chain = defineChain({
  id: LOCAL_CHAIN_ID,
  name: 'local-venue',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const client = createPublicClient({ chain, transport: http(RPC) });

const reported = await client.getChainId();
if (reported !== LOCAL_CHAIN_ID) {
  throw new Error(`local venue only: ${RPC} is chain ${reported}, not ${LOCAL_CHAIN_ID}`);
}

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

function keyFor(label: string) {
  return privateKeyToAccount(keccak256(toHex(`numo.local-venue.${label}`)));
}

function readAccounts(): Accounts {
  try {
    return JSON.parse(readFileSync(accountsFile, 'utf8')) as Accounts;
  } catch {
    return {};
  }
}

/** Gives `label`'s EOA gas and `usdc` (6dp) of USDC, then returns a wallet for it. */
async function funded(label: string, usdc: bigint) {
  const account = keyFor(label);
  await client.request({ method: 'anvil_setBalance' as never, params: [account.address, toHex(10n ** 18n)] as never });
  const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account.address, USDC_BALANCE_SLOT]));
  await client.request({ method: 'anvil_setStorageAt' as never, params: [USDC, slot, pad(toHex(usdc), { size: 32 })] as never });
  return { account, wallet: createWalletClient({ account, chain, transport: http(RPC) }) };
}

async function send(
  wallet: Awaited<ReturnType<typeof funded>>['wallet'],
  address: Address,
  functionName: 'approve' | 'createAndDepositSubAccount' | 'donate' | 'createAccount' | 'deposit' | 'transfer',
  args: readonly unknown[],
) {
  const estimate = await client.estimateContractGas({ address, abi, functionName, args, account: wallet.account } as never);
  const hash = await wallet.writeContract({ address, abi, functionName, args, gas: withGasHeadroom(estimate) } as never);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted (${hash})`);
  return receipt;
}

/** Gives `label`'s EOA gas and `cngn` (6dp) of cNGN, then returns a wallet for it. */
async function fundedCngn(label: string, cngn: bigint) {
  const { account, wallet } = await funded(label, 0n);
  const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account.address, CNGN_BALANCE_SLOT]));
  await client.request({ method: 'anvil_setStorageAt' as never, params: [CNGN, slot, pad(toHex(cngn), { size: 32 })] as never });
  const held = await client.readContract({ address: CNGN, abi, functionName: 'balanceOf', args: [account.address] });
  if (held !== cngn) throw new Error(`cNGN balance slot moved: set ${cngn}, read ${held}`);
  return { account, wallet };
}

/**
 * Opens a perp account posting ONLY cNGN, as the app's "Deposit margin" with cNGN selected does:
 * one creator call into the perp's cNGN escrow, under the perp SRM. The account holds no cash.
 */
async function openCngnAccount(label: string, cngnWhole: bigint) {
  const escrow = venue.cngnEscrow;
  if (escrow === undefined) throw new Error('no cNGN escrow in venue.json: up.sh did not enable cNGN margin');
  const cngn = cngnWhole * 10n ** 6n;
  const { account, wallet } = await fundedCngn(label, cngn);
  await send(wallet, CNGN, 'approve', [SUBACCOUNT_CREATOR, cngn]);
  const receipt = await send(wallet, SUBACCOUNT_CREATOR, 'createAndDepositSubAccount', [escrow, cngn, venue.srm]);
  const event = receipt.logs
    .filter((log) => log.address.toLowerCase() === MATCHING.toLowerCase())
    .map((log) => {
      try {
        return decodeEventLog({ abi, data: log.data, topics: log.topics });
      } catch {
        return null;
      }
    })
    .find((decoded) => decoded?.eventName === 'DepositedSubAccount');
  if (event?.eventName !== 'DepositedSubAccount') throw new Error(`${label}: no DepositedSubAccount`);
  const id = event.args.accountId.toString();
  writeFileSync(accountsFile, JSON.stringify({ ...readAccounts(), [label]: id }, null, 2));
  console.log(JSON.stringify({ label, address: account.address, subaccountId: id, cngn: cngnWhole.toString() }));
}

/** Opens a perp account the way PerpMarginDialog does: one creator call, cash under the perp SRM. */
async function openAccount(label: string, usdcWhole: bigint) {
  const usdc = usdcWhole * 10n ** 6n;
  const { account, wallet } = await funded(label, usdc);
  await send(wallet, USDC, 'approve', [SUBACCOUNT_CREATOR, usdc]);
  const receipt = await send(wallet, SUBACCOUNT_CREATOR, 'createAndDepositSubAccount', [venue.cash, usdc, venue.srm]);
  const event = receipt.logs
    .filter((log) => log.address.toLowerCase() === MATCHING.toLowerCase())
    .map((log) => {
      try {
        return decodeEventLog({ abi, data: log.data, topics: log.topics });
      } catch {
        return null;
      }
    })
    .find((decoded) => decoded?.eventName === 'DepositedSubAccount');
  if (event?.eventName !== 'DepositedSubAccount') throw new Error(`${label}: no DepositedSubAccount`);
  const id = event.args.accountId.toString();
  writeFileSync(accountsFile, JSON.stringify({ ...readAccounts(), [label]: id }, null, 2));
  console.log(JSON.stringify({ label, address: account.address, subaccountId: id, usdc: usdcWhole.toString() }));
}

/**
 * The keeper's funding account. Not opened through SubAccountCreator like a trader's: that deposits
 * the account into Matching, and the keeper then cannot move its cash into bid accounts.
 */
async function openKeeperAccount(usdcWhole: bigint) {
  const usdc = usdcWhole * 10n ** 6n;
  const { account, wallet } = await funded('keeper', usdc);
  const receipt = await send(wallet, SUB_ACCOUNTS, 'createAccount', [account.address, venue.srm]);
  const created = receipt.logs
    .map((log) => {
      try {
        return decodeEventLog({ abi, data: log.data, topics: log.topics });
      } catch {
        return null;
      }
    })
    .find((decoded) => decoded?.eventName === 'AccountCreated');
  if (created?.eventName !== 'AccountCreated') throw new Error('keeper: no AccountCreated');
  const id = created.args.accountId;
  await send(wallet, USDC, 'approve', [venue.cash, usdc]);
  await send(wallet, venue.cash, 'deposit', [id, usdc]);
  writeFileSync(accountsFile, JSON.stringify({ ...readAccounts(), keeper: id.toString() }, null, 2));
  console.log(JSON.stringify({ label: 'keeper', address: account.address, subaccountId: id.toString(), usdc: usdcWhole.toString() }));
}

async function fundSecurityModule(usdcWhole: bigint) {
  const usdc = usdcWhole * 10n ** 6n;
  const { wallet } = await funded('sm-donor', usdc);
  await send(wallet, USDC, 'approve', [venue.securityModule, usdc]);
  await send(wallet, venue.securityModule, 'donate', [usdc]);
  console.log(`security module seeded with $${usdcWhole}`);
}

/** The index as the UI shows it: cNGN per USDC, rounded to a whole naira. */
async function uiIndex(): Promise<bigint> {
  const [usdPerNgn] = await client.readContract({ address: venue.indexFeed, abi, functionName: 'getSpot' });
  return (10n ** 18n + usdPerNgn / 2n) / usdPerNgn;
}

let lastNonce = 0n;
function nonce() {
  // trading-app's createOrderNonce shape: clock ms * 4096, kept under 2^53.
  const fromClock = BigInt(Date.now()) * 4096n;
  lastNonce = fromClock > lastNonce ? fromClock : lastNonce + 1n;
  return lastNonce;
}

/**
 * A perp order in trading-app's envelope (buildSpotOrderEnvelope with the perp market override):
 * UI price cNGN per USDC and size in USD; the engine price is 1 / price and the engine side the
 * opposite one. Whole-naira prices keep the arithmetic exact.
 */
async function placeOrder(label: string, side: 'buy' | 'sell', uiPrice: bigint, uiSizeUsd: bigint, market: OrderMarket = perpMarket()) {
  const account = keyFor(label);
  const subaccountId = readAccounts()[label];
  if (subaccountId === undefined) throw new Error(`no account for ${label}; run "account ${label}" first`);

  const enginePrice = (10n ** 18n + uiPrice / 2n) / uiPrice;
  const engineAmountWhole = uiSizeUsd * uiPrice;
  const worstFee = (WORST_FEE_RATE_E18 + uiPrice / 2n) / uiPrice;
  const engineSide = side === 'buy' ? 'sell' : 'buy';
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 86_400);
  const orderNonce = nonce();
  const owner = getAddress(account.address);
  const module = market.module;

  const data = encodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'asset', type: 'address' },
          { name: 'subId', type: 'uint256' },
          { name: 'limitPrice', type: 'int256' },
          { name: 'desiredAmount', type: 'int256' },
          { name: 'worstFee', type: 'uint256' },
          { name: 'recipientId', type: 'uint256' },
          { name: 'isBid', type: 'bool' },
        ],
      },
    ],
    [
      {
        asset: market.asset,
        subId: 0n,
        limitPrice: enginePrice,
        desiredAmount: engineAmountWhole * 10n ** 18n,
        worstFee,
        recipientId: BigInt(subaccountId),
        isBid: engineSide === 'buy',
      },
    ],
  );

  const signature = await account.signTypedData({
    domain: { name: 'Matching', version: '1.0', chainId: LOCAL_CHAIN_ID, verifyingContract: MATCHING },
    primaryType: 'Action',
    types: {
      Action: [
        { name: 'subaccountId', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'module', type: 'address' },
        { name: 'data', type: 'bytes' },
        { name: 'expiry', type: 'uint256' },
        { name: 'owner', type: 'address' },
        { name: 'signer', type: 'address' },
      ],
    },
    message: { subaccountId: BigInt(subaccountId), nonce: orderNonce, module, data, expiry, owner, signer: owner },
  });

  const actionJson = {
    data,
    expiry: expiry.toString(),
    module,
    nonce: orderNonce.toString(),
    owner,
    signer: owner,
    subaccount_id: subaccountId,
  };
  const response = await fetch(`${MARKETS}/v1/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      action_json: actionJson,
      asset_address: market.asset,
      desired_amount: engineAmountWhole.toString(),
      expiry: Number(expiry),
      filled_amount: '0',
      limit_price: formatUnits(enginePrice, 18),
      nonce: orderNonce.toString(),
      order_id: `${market.label}-${crypto.randomUUID()}`,
      owner_address: owner,
      recipient_id: subaccountId,
      side: engineSide,
      signer_address: owner,
      sub_id: '0',
      subaccount_id: subaccountId,
      worst_fee: worstFee.toString(),
      signature,
    }),
  });
  const body = await response.text();
  console.log(`${label} ${market.label} ${side} $${uiSizeUsd} @ ${uiPrice} cNGN/USDC -> ${response.status} ${body.slice(0, 200)}`);
  if (!response.ok) throw new Error(`order refused: ${response.status}`);
  return (JSON.parse(body) as { order: { order_id: string } }).order.order_id;
}

async function waitForPosition(label: string) {
  const subaccountId = readAccounts()[label];
  for (let attempt = 0; attempt < 60; attempt++) {
    const response = await fetch(`${MARKETS}/v1/positions?subaccount_id=${subaccountId}`);
    const body = (await response.json()) as { positions?: unknown[] };
    if ((body.positions?.length ?? 0) > 0) {
      console.log(`${label} position:`, JSON.stringify(body.positions));
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 2_000));
  }
  throw new Error(`${label}: no position after 2 minutes; check the matcher and execution logs`);
}

async function balance(accountId: string | number, asset: Address) {
  return client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [BigInt(accountId), asset, 0n] });
}

const usd = (value: bigint) => Number(value) / 1e18;
const abs = (value: bigint) => (value < 0n ? -value : value);

/**
 * Opens whatever is left of the OI cap as one NGN long at ~3x (the most the SRM allows) against a
 * well-funded NGN short, both at the index: the worst book a step can meet at the launch cap.
 */
async function fillCap(collateral: 'usdc' | 'cngn' = 'usdc') {
  const [cap, total] = await Promise.all([
    client.readContract({ address: venue.perp, abi, functionName: 'totalPositionCap', args: [venue.srm] }),
    client.readContract({ address: venue.perp, abi, functionName: 'totalPosition', args: [venue.srm] }),
  ]);
  const index = await uiIndex();
  const perSideNgn = (cap - total) / 2n / 10n ** 18n;
  const uiSize = perSideNgn / index;
  if (uiSize < 1n) throw new Error(`nothing left under the cap (cap ${cap}, total ${total})`);
  if (collateral === 'cngn') {
    // cNGN counts for half its value: initial margin (a third of notional) needs two thirds of the
    // notional in cNGN, plus 1% for the open to clear. The fee and funding land as negative cash.
    await openCngnAccount('ngn-long', (uiSize * index * 2n * 101n) / 300n);
  } else {
    // Initial margin is a third of notional; the deposit covers it, the taker fee, and $50.
    await openAccount('ngn-long', (uiSize * 34n) / 100n + 50n);
  }
  await openAccount('ngn-short', uiSize + 1_000n);
  // The NGN long is a UI short: it rests at the index, and the NGN short's UI buy takes it there.
  await placeOrder('ngn-long', 'sell', index, uiSize);
  await placeOrder('ngn-short', 'buy', index, uiSize);
  await waitForPosition('ngn-long');
  // What was opened, for wait-liquidated to measure what the auction left.
  const opened = await balance(readAccounts()['ngn-long']!, venue.perp);
  writeFileSync(accountsFile, JSON.stringify({ ...readAccounts(), 'ngn-long.opened': opened.toString() }, null, 2));
  const after = await client.readContract({ address: venue.perp, abi, functionName: 'totalPosition', args: [venue.srm] });
  console.log(`OI ${after / 10n ** 18n} of cap ${cap / 10n ** 18n} NGN (each side $${uiSize} at ${index} cNGN/USDC)`);
}

async function report() {
  const accounts = readAccounts();
  const [index] = await client.readContract({ address: venue.indexFeed, abi, functionName: 'getSpot' }).catch(() => [0n]);
  const rows = await Promise.all(
    Object.entries(accounts).map(async ([label, id]) => ({
      label,
      account: id,
      perpNgn: Number((await balance(id, venue.perp)) / 10n ** 18n),
      cashUsd: usd(await balance(id, venue.cash)).toFixed(2),
      cngn: venue.cngnEscrow === undefined ? '-' : Number((await balance(id, venue.cngnEscrow)) / 10n ** 18n),
    })),
  );
  console.table(rows);
  const summary = {
    indexNgnPerUsd: index === 0n ? 'stale' : (1e18 / Number(index)).toFixed(2),
    oiNgn: Number((await client.readContract({ address: venue.perp, abi, functionName: 'totalPosition', args: [venue.srm] })) / 10n ** 18n),
    securityModuleCashUsd: usd(await balance(venue.securityModuleAccount, venue.cash)).toFixed(2),
    cashToUsdcRate: formatUnits(await client.readContract({ address: venue.cash, abi, functionName: 'getCashToStableExchangeRate' }), 18),
  };
  console.log(JSON.stringify(summary));
}

async function waitClosed(label: string, timeoutSec: number) {
  const id = readAccounts()[label];
  if (id === undefined) throw new Error(`no account ${label}`);
  const deadline = Date.now() + timeoutSec * 1000;
  while (Date.now() < deadline) {
    const position = await balance(id, venue.perp);
    if (position === 0n) {
      console.log(`${label} (#${id}) closed`);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }
  throw new Error(`${label} (#${id}) still open after ${timeoutSec}s: ${await balance(id, venue.perp)}`);
}

/**
 * Done when the account is liquidated as the venue means it: its position is gone (an insolvent
 * auction takes all of it), or its auction has ended with the account back above maintenance
 * margin, or all but a sliver (under 1% of what was opened) is gone and the account is above
 * maintenance margin while its auction runs out its solvent window (a solvent auction sells only
 * what restores margin, ends at buffer margin, and leaves the rest to the owner).
 */
async function waitLiquidated(label: string, timeoutSec: number) {
  const id = readAccounts()[label];
  if (id === undefined) throw new Error(`no account ${label}`);
  const deadline = Date.now() + timeoutSec * 1000;
  while (Date.now() < deadline) {
    const position = await balance(id, venue.perp);
    const auction = await client.readContract({ address: venue.auction, abi, functionName: 'getAuction', args: [BigInt(id)] });
    const [mm] = await client.readContract({ address: venue.auction, abi, functionName: 'getMarginAndMarkToMarket', args: [BigInt(id), 0n] });
    if (position === 0n) {
      console.log(`${label} (#${id}) closed in full`);
      return;
    }
    if (!auction.ongoing && mm >= 0n) {
      console.log(`${label} (#${id}) liquidated: ${position / 10n ** 18n} NGN left, above maintenance margin by $${usd(mm).toFixed(2)}, auction over`);
      return;
    }
    const opened = BigInt(readAccounts()[`${label}.opened`] ?? '0');
    if (opened > 0n && mm >= 0n && abs(position) * 100n < abs(opened)) {
      console.log(
        `${label} (#${id}) liquidated: ${position / 10n ** 18n} of ${opened / 10n ** 18n} NGN left, above maintenance margin by $${usd(mm).toFixed(2)}; the sliver's auction ends with its solvent window`,
      );
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5_000));
  }
  throw new Error(`${label} (#${id}) still under liquidation after ${timeoutSec}s: ${await balance(id, venue.perp)}`);
}

// --- spot regression: the live spot stack the fork inherits, with no perp anywhere -------------

/** A spot trading account under the spot SRM holding `whole` USDC or cNGN, as the app opens one. */
async function openSpotAccount(label: string, kind: 'usdc' | 'cngn', whole: bigint) {
  let asset: Address;
  let token: Address;
  let amount: bigint;
  const { account, wallet } = await funded(label, kind === 'usdc' ? whole * 10n ** 6n : 0n);
  if (kind === 'usdc') {
    asset = SPOT.wrappedUsdc;
    token = USDC;
    amount = whole * 10n ** 6n;
  } else {
    asset = SPOT.asset;
    token = SPOT.cngnToken;
    const decimals = await client.readContract({ address: token, abi, functionName: 'decimals' });
    amount = whole * 10n ** BigInt(decimals);
    // cNGN comes from the escrow's own holdings, impersonated: fork-only, and only to fund a trader.
    await client.request({ method: 'anvil_impersonateAccount' as never, params: [SPOT.asset] as never });
    await client.request({ method: 'anvil_setBalance' as never, params: [SPOT.asset, toHex(10n ** 18n)] as never });
    const escrow = createWalletClient({ account: SPOT.asset, chain, transport: http(RPC) });
    await send(escrow as never, token, 'transfer', [account.address, amount]);
    await client.request({ method: 'anvil_stopImpersonatingAccount' as never, params: [SPOT.asset] as never });
  }
  await send(wallet, token, 'approve', [SUBACCOUNT_CREATOR, amount]);
  const receipt = await send(wallet, SUBACCOUNT_CREATOR, 'createAndDepositSubAccount', [asset, amount, SPOT.srm]);
  const event = receipt.logs
    .filter((log) => log.address.toLowerCase() === MATCHING.toLowerCase())
    .map((log) => {
      try {
        return decodeEventLog({ abi, data: log.data, topics: log.topics });
      } catch {
        return null;
      }
    })
    .find((decoded) => decoded?.eventName === 'DepositedSubAccount');
  if (event?.eventName !== 'DepositedSubAccount') throw new Error(`${label}: no DepositedSubAccount`);
  const id = event.args.accountId.toString();
  writeFileSync(accountsFile, JSON.stringify({ ...readAccounts(), [label]: id }, null, 2));
  console.log(JSON.stringify({ label, address: account.address, subaccountId: id, [kind]: whole.toString() }));
}

/** Deposits `whole` USDC or cNGN into an existing spot account, as the app's existing-account path does. */
async function spotDeposit(label: string, kind: 'usdc' | 'cngn', whole: bigint) {
  const id = readAccounts()[label];
  if (id === undefined) throw new Error(`no account for ${label}`);
  const { account, wallet } = await funded(label, kind === 'usdc' ? whole * 10n ** 6n : 0n);
  let asset: Address;
  let token: Address;
  let amount: bigint;
  if (kind === 'usdc') {
    asset = SPOT.wrappedUsdc;
    token = USDC;
    amount = whole * 10n ** 6n;
  } else {
    asset = SPOT.asset;
    token = SPOT.cngnToken;
    amount = whole * 10n ** BigInt(await client.readContract({ address: token, abi, functionName: 'decimals' }));
    await client.request({ method: 'anvil_impersonateAccount' as never, params: [SPOT.asset] as never });
    await client.request({ method: 'anvil_setBalance' as never, params: [SPOT.asset, toHex(10n ** 18n)] as never });
    const escrow = createWalletClient({ account: SPOT.asset, chain, transport: http(RPC) });
    await send(escrow as never, token, 'transfer', [account.address, amount]);
    await client.request({ method: 'anvil_stopImpersonatingAccount' as never, params: [SPOT.asset] as never });
  }
  await send(wallet, token, 'approve', [asset, amount]);
  await send(wallet, asset, 'deposit', [BigInt(id), amount]);
  console.log(`${label} (#${id}) +${whole} ${kind}`);
}

async function spotBalances(label: string) {
  const id = readAccounts()[label]!;
  return { usdc: await balance(id, SPOT.wrappedUsdc), cngn: await balance(id, SPOT.asset) };
}

/**
 * A resting UI sell of USDC, lifted by a UI buy, then checked against the spot fill contract
 * (trading-app README): UI BUY -> dUSDC = +size, dcNGN = -(size x price); UI SELL the reverse. The
 * taker pays the 25bps fee in USDC. Then the settlement transaction must carry the executor's gas
 * headroom.
 */
async function spotCross(uiPrice: bigint, uiSize: bigint) {
  const makerBefore = await spotBalances('usdc-maker');
  const takerBefore = await spotBalances('cngn-taker');
  const head = await client.getBlockNumber();
  await placeOrder('usdc-maker', 'sell', uiPrice, uiSize, spotMarket());
  await placeOrder('cngn-taker', 'buy', uiPrice, uiSize, spotMarket());

  let makerAfter = makerBefore;
  for (let attempt = 0; attempt < 60 && makerAfter.cngn === makerBefore.cngn; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 2_000));
    makerAfter = await spotBalances('usdc-maker');
  }
  const takerAfter = await spotBalances('cngn-taker');
  const E18 = 10n ** 18n;
  const usdc = uiSize * E18;
  const cngn = uiSize * uiPrice * E18;
  const delta = {
    maker: { usdc: makerAfter.usdc - makerBefore.usdc, cngn: makerAfter.cngn - makerBefore.cngn },
    taker: { usdc: takerAfter.usdc - takerBefore.usdc, cngn: takerAfter.cngn - takerBefore.cngn },
  };
  console.log('spot fill deltas (18dp):', JSON.stringify(delta, (_k, v) => (typeof v === 'bigint' ? v.toString() : v)));
  const fee = (usdc * 30n) / 10_000n; // the signed bound; the charge is 25bps
  const check = (ok: boolean, what: string) => {
    if (!ok) throw new Error(`spot regression FAILED: ${what}`);
    console.log(`ok: ${what}`);
  };
  // The engine price is 1/price rounded to 18dp, so the USDC leg can differ from size by that
  // rounding times the cNGN amount: ~4e-15 USDC here. 1e-12 USDC (1e6 at 18dp) is ample and still exact.
  const rounding = 1_000_000n;
  const near = (a: bigint, b: bigint) => (a > b ? a - b : b - a) <= rounding;
  check(near(delta.maker.usdc, -usdc), 'UI SELL: maker dUSDC = -size (to the engine price rounding)');
  check(delta.maker.cngn === cngn, 'UI SELL: maker dcNGN = +size x price');
  check(delta.taker.cngn === -cngn, 'UI BUY: taker dcNGN = -(size x price)');
  check(delta.taker.usdc <= usdc + rounding && delta.taker.usdc >= usdc - fee, 'UI BUY: taker dUSDC = +size less the taker fee');

  // The settlement: a verifyAndMatch to Matching since the orders went in, with headroom over its use.
  let settled = false;
  for (let n = head + 1n; n <= (await client.getBlockNumber()); n++) {
    const block = await client.getBlock({ blockNumber: n, includeTransactions: true });
    for (const tx of block.transactions) {
      if (tx.to?.toLowerCase() !== MATCHING.toLowerCase() || !tx.input.startsWith('0x')) continue;
      const receipt = await client.getTransactionReceipt({ hash: tx.hash });
      console.log(`settlement ${tx.hash}: status ${receipt.status}, gas limit ${tx.gas}, used ${receipt.gasUsed}`);
      check(receipt.status === 'success', 'the settlement succeeded');
      check(tx.gas - receipt.gasUsed >= 90_000n, 'the executor sent it with gas headroom (limit >= used + ~100k)');
      settled = true;
    }
  }
  check(settled, 'found the settlement transaction');
}

/** A user-signed withdrawal of wrapped USDC back to the owner's wallet, through markets-service. */
/**
 * A perp account withdraws its margin the way the app does: a WithdrawalModule action for the perp's
 * CashAsset (not the spot escrow), signed by the owner, submitted by the venue's executor. Proves the
 * venue accepts the perp cash as a withdrawal asset (WITHDRAWAL_ASSET_ADDRESSES) and that the module
 * can call CashAsset.withdraw, which pays real USDC to the owner.
 */
async function perpWithdraw(label: string, whole: bigint) {
  const account = keyFor(label);
  const subaccountId = readAccounts()[label]!;
  const owner = getAddress(account.address);
  const amount = whole * 10n ** 6n;
  const data = encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [getAddress(venue.cash), amount]);
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 600);
  const withdrawalNonce = nonce();
  const signature = await account.signTypedData({
    domain: { name: 'Matching', version: '1.0', chainId: LOCAL_CHAIN_ID, verifyingContract: MATCHING },
    primaryType: 'Action',
    types: {
      Action: [
        { name: 'subaccountId', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'module', type: 'address' },
        { name: 'data', type: 'bytes' },
        { name: 'expiry', type: 'uint256' },
        { name: 'owner', type: 'address' },
        { name: 'signer', type: 'address' },
      ],
    },
    message: { subaccountId: BigInt(subaccountId), nonce: withdrawalNonce, module: SPOT.withdrawalModule, data, expiry, owner, signer: owner },
  });
  const before = await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner] });
  const cashBefore = await balance(subaccountId, getAddress(venue.cash));
  const response = await fetch(`${MARKETS}/v1/withdrawals`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      action: { subaccount_id: subaccountId, nonce: withdrawalNonce.toString(), module: SPOT.withdrawalModule, data, expiry: expiry.toString(), owner, signer: owner },
      signature,
    }),
  });
  const body = await response.text();
  console.log(`perp withdraw ${whole} USDC from #${subaccountId} -> ${response.status} ${body.slice(0, 200)}`);
  if (!response.ok) throw new Error('perp withdrawal refused');
  const after = await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner] });
  const cashAfter = await balance(subaccountId, getAddress(venue.cash));
  if (after - before !== amount) throw new Error(`owner received ${after - before}, expected ${amount}`);
  if (cashBefore - cashAfter !== whole * 10n ** 18n) throw new Error(`account cash fell by ${cashBefore - cashAfter}, expected ${whole * 10n ** 18n}`);
  console.log(`ok: perp withdrawal paid ${whole} USDC to the owner; account #${subaccountId} cash ${cashBefore / 10n ** 18n} -> ${cashAfter / 10n ** 18n}`);
}

async function spotWithdraw(label: string, whole: bigint) {
  const account = keyFor(label);
  const subaccountId = readAccounts()[label]!;
  const owner = getAddress(account.address);
  const amount = whole * 10n ** 6n;
  const data = encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [SPOT.wrappedUsdc, amount]);
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 600);
  const withdrawalNonce = nonce();
  const signature = await account.signTypedData({
    domain: { name: 'Matching', version: '1.0', chainId: LOCAL_CHAIN_ID, verifyingContract: MATCHING },
    primaryType: 'Action',
    types: {
      Action: [
        { name: 'subaccountId', type: 'uint256' },
        { name: 'nonce', type: 'uint256' },
        { name: 'module', type: 'address' },
        { name: 'data', type: 'bytes' },
        { name: 'expiry', type: 'uint256' },
        { name: 'owner', type: 'address' },
        { name: 'signer', type: 'address' },
      ],
    },
    message: { subaccountId: BigInt(subaccountId), nonce: withdrawalNonce, module: SPOT.withdrawalModule, data, expiry, owner, signer: owner },
  });
  const before = await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner] });
  const response = await fetch(`${MARKETS}/v1/withdrawals`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      action: {
        subaccount_id: subaccountId,
        nonce: withdrawalNonce.toString(),
        module: SPOT.withdrawalModule,
        data,
        expiry: expiry.toString(),
        owner,
        signer: owner,
      },
      signature,
    }),
  });
  const body = await response.text();
  console.log(`withdraw ${whole} USDC -> ${response.status} ${body.slice(0, 200)}`);
  if (!response.ok) throw new Error(`spot regression FAILED: withdrawal refused (${response.status})`);
  const after = await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner] });
  if (after - before !== amount) throw new Error(`spot regression FAILED: wallet received ${after - before}, want ${amount}`);
  console.log(`ok: withdrawal paid ${whole} USDC to the owner's wallet`);
}

switch (command) {
  case 'account':
    await openAccount(args[0] ?? 'trader', BigInt(args[1] ?? '5000'));
    break;
  case 'keeper-account':
    await openKeeperAccount(BigInt(args[0] ?? '20000'));
    break;
  case 'fund-sm':
    await fundSecurityModule(BigInt(args[0] ?? '10000'));
    break;
  case 'quote': {
    const index = await uiIndex();
    const spread = (index * 50n) / 10_000n;
    await placeOrder('maker', 'buy', index - spread, 2_000n);
    await placeOrder('maker', 'sell', index + spread, 2_000n);
    break;
  }
  case 'cross': {
    const index = await uiIndex();
    await placeOrder('taker', 'buy', index + (index * 100n) / 10_000n, 1_000n);
    await waitForPosition('taker');
    break;
  }
  case 'spot-account':
    await openSpotAccount(args[0] ?? 'trader', (args[1] ?? 'usdc') as 'usdc' | 'cngn', BigInt(args[2] ?? '1000'));
    break;
  case 'spot-deposit':
    await spotDeposit(args[0] ?? 'trader', (args[1] ?? 'cngn') as 'usdc' | 'cngn', BigInt(args[2] ?? '1000'));
    break;
  case 'spot-quote':
    await placeOrder(args[0] ?? 'trader', (args[1] ?? 'buy') as 'buy' | 'sell', BigInt(args[2] ?? '1374'), BigInt(args[3] ?? '10'), spotMarket());
    break;
  case 'spot-cross':
    await spotCross(BigInt(args[0] ?? '1374'), BigInt(args[1] ?? '100'));
    break;
  case 'spot-withdraw':
    await spotWithdraw(args[0] ?? 'usdc-maker', BigInt(args[1] ?? '10'));
    break;
  case 'withdraw':
    await perpWithdraw(args[0] ?? 'taker', BigInt(args[1] ?? '10'));
    break;
  case 'account-cngn':
    await openCngnAccount(args[0] ?? 'treasury', BigInt(args[1] ?? '10000000'));
    break;
  case 'fill-cap':
    await fillCap((args[0] ?? 'usdc') as 'usdc' | 'cngn');
    break;
  case 'report':
    await report();
    break;
  case 'wait-liquidated':
    await waitLiquidated(args[0] ?? 'ngn-long', Number(args[1] ?? '600'));
    break;
  case 'wait-closed':
    await waitClosed(args[0] ?? 'ngn-long', Number(args[1] ?? '600'));
    break;
  default:
    throw new Error(`unknown command ${command}`);
}
