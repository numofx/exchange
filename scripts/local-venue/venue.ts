/**
 * The local venue's chain and order steps, for up.sh: perp accounts, the SecurityModule seed, a
 * two-sided quote and a crossing order, each signed the way trading-app signs them.
 *
 * Every command reads the chain id from the RPC first and refuses anything but anvil's 31337. All
 * keys are derived from fixed labels, and USDC is minted by writing its storage: none of it means
 * anything on a real network, and none of it can reach one.
 *
 *   tsx venue.ts <state-dir> account <label> <usdc>   open a perp account (createAndDepositSubAccount)
 *   tsx venue.ts <state-dir> fund-sm <usdc>            donate to the stack's SecurityModule
 *   tsx venue.ts <state-dir> quote                      maker rests a bid and an ask 0.5% around the index
 *   tsx venue.ts <state-dir> cross                      taker lifts the maker's offer; waits for the position
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
const MATCHING = '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191';
const SUBACCOUNT_CREATOR = '0x568890A8D63Ba8a03b6eCbEedA1bD9f6ea014D5D';

/** The app's taker fee bound, as a rate of USD notional (trading-app SPOT_TAKER_FEE_RATE). */
const WORST_FEE_RATE_E18 = 3n * 10n ** 15n;

const abi = parseAbi([
  'function approve(address, uint256) returns (bool)',
  'function createAndDepositSubAccount(address baseAsset, uint256 initDeposit, address manager) returns (uint256)',
  'function donate(uint256 amount)',
  'function getSpot() view returns (uint256, uint256)',
  'event DepositedSubAccount(uint256 indexed accountId, address indexed owner)',
]);

type Venue = { perp: Address; cash: Address; srm: Address; securityModule: Address; indexFeed: Address; tradePerp: Address };
type Accounts = Record<string, string>;

const [stateDir, command, ...args] = process.argv.slice(2);
if (!stateDir || !command) throw new Error('usage: venue.ts <state-dir> <account|fund-sm|quote|cross> ...');
const venue = JSON.parse(readFileSync(join(stateDir, 'venue.json'), 'utf8')) as Venue;
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

async function send(wallet: Awaited<ReturnType<typeof funded>>['wallet'], address: Address, functionName: 'approve' | 'createAndDepositSubAccount' | 'donate', args: readonly unknown[]) {
  const hash = await wallet.writeContract({ address, abi, functionName, args } as never);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted (${hash})`);
  return receipt;
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

async function fundSecurityModule(usdcWhole: bigint) {
  const usdc = usdcWhole * 10n ** 6n;
  const { wallet } = await funded('sm-donor', usdc);
  await send(wallet, USDC, 'approve', [venue.securityModule, usdc]);
  await send(wallet, venue.securityModule, 'donate', [usdc]);
  console.log(`security module seeded with $${usdcWhole}`);
}

/** The index as the UI shows it: NGN per USD, rounded to a whole naira. */
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
 * UI price NGN per USD and size in USD; the engine price is 1 / price and the engine side the
 * opposite one. Whole-naira prices keep the arithmetic exact.
 */
async function placeOrder(label: string, side: 'buy' | 'sell', uiPrice: bigint, uiSizeUsd: bigint) {
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
  const module = getAddress(venue.tradePerp);

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
        asset: getAddress(venue.perp),
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
      asset_address: getAddress(venue.perp),
      desired_amount: engineAmountWhole.toString(),
      expiry: Number(expiry),
      filled_amount: '0',
      limit_price: formatUnits(enginePrice, 18),
      nonce: orderNonce.toString(),
      order_id: `perp-${crypto.randomUUID()}`,
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
  console.log(`${label} ${side} $${uiSizeUsd} @ ${uiPrice} NGN/USD -> ${response.status} ${body.slice(0, 200)}`);
  if (!response.ok) throw new Error(`order refused: ${response.status}`);
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

switch (command) {
  case 'account':
    await openAccount(args[0] ?? 'trader', BigInt(args[1] ?? '5000'));
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
  default:
    throw new Error(`unknown command ${command}`);
}
