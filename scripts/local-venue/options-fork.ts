/**
 * The chain and venue side of options-fork.sh: accounts on MarginEngine v2, a taker crossing the options maker's quote,
 * and the checks that the engine margins the result as the maker predicted. Local fork (chain 31337) only.
 *
 *   options-fork.ts <state-dir> open-account <label> <usdcWhole>
 *   options-fork.ts <state-dir> best <symbol>                         the maker's best bid and ask
 *   options-fork.ts <state-dir> take <label> <symbol> <buy|sell> <units>   crosses the best quote, waits for the fill,
 *                                                                     and checks positions, cash and margin
 *   options-fork.ts <state-dir> quotes <symbol>                       how many orders rest on each side
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
const RPC = process.env.LOCAL_VENUE_RPC ?? 'http://127.0.0.1:8610';
const MARKETS = process.env.LOCAL_VENUE_MARKETS ?? 'http://127.0.0.1:8095';

const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const USDC_BALANCE_SLOT = 9n;
const MATCHING = '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191';
const SUB_ACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843';
const SUBACCOUNT_CREATOR = '0x568890A8D63Ba8a03b6eCbEedA1bD9f6ea014D5D';
// MarginEngine v2 and its cash: where the options are margined (DEPLOYED_ADDRESSES.md).
const ENGINE = getAddress('0x0705219a1594d5Fc5dC2573da4082cAf3e1B0950');
const CASH = getAddress('0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272');
const E18 = 10n ** 18n;

const abi = parseAbi([
  'function approve(address, uint256) returns (bool)',
  'function createAndDepositSubAccount(address baseAsset, uint256 initDeposit, address manager) returns (uint256)',
  'event DepositedSubAccount(uint256 indexed accountId, address indexed owner)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function getMargin(uint256 accountId, bool isInitial) view returns (int256)',
  'function getIsolatedMargin(uint256 marketId, uint256 strike, uint256 expiry, bool isCall, int256 balance, bool isInitial) view returns (int256 margin, int256 markToMarket)',
]);

const [stateDir, command, ...args] = process.argv.slice(2);
if (!stateDir || !command) throw new Error('usage: options-fork.ts <state-dir> <open-account|best|take|quotes> ...');
const accountsFile = join(stateDir, 'accounts.json');

const chain = defineChain({
  id: LOCAL_CHAIN_ID,
  name: 'options-fork',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const client = createPublicClient({ chain, transport: http(RPC) });
if ((await client.getChainId()) !== LOCAL_CHAIN_ID) throw new Error(`local fork only: ${RPC} is not chain ${LOCAL_CHAIN_ID}`);

const keyFor = (label: string) => privateKeyToAccount(keccak256(toHex(`numo.local-venue.${label}`)));
const readAccounts = (): Record<string, string> => {
  try {
    return JSON.parse(readFileSync(accountsFile, 'utf8'));
  } catch {
    return {};
  }
};
const accountOf = (label: string) => {
  const id = readAccounts()[label];
  if (!id) throw new Error(`no account for ${label}`);
  return BigInt(id);
};

type Listing = {
  market: string;
  asset_address: Address;
  sub_id: string;
  amount_scale: string;
  taker_fee_bps: number;
  option: { strike: string; option_type: 'call' | 'put'; expiry_timestamp: number };
};
async function listing(symbol: string): Promise<Listing> {
  const markets = (await (await fetch(`${MARKETS}/v1/markets`)).json()) as Listing[];
  const found = markets.find((m) => m.market === symbol);
  if (!found?.option) throw new Error(`${symbol} is not a listed option`);
  return found;
}

async function openAccount(label: string, usdcWhole: bigint) {
  const account = keyFor(label);
  const usdc = usdcWhole * 10n ** 6n;
  await client.request({ method: 'anvil_setBalance' as never, params: [account.address, toHex(E18)] as never });
  const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [account.address, USDC_BALANCE_SLOT]));
  await client.request({ method: 'anvil_setStorageAt' as never, params: [USDC, slot, pad(toHex(usdc), { size: 32 })] as never });
  const wallet = createWalletClient({ account, chain, transport: http(RPC) });
  for (const [address, functionName, fnArgs] of [
    [USDC, 'approve', [SUBACCOUNT_CREATOR, usdc]],
    [SUBACCOUNT_CREATOR, 'createAndDepositSubAccount', [CASH, usdc, ENGINE]],
  ] as const) {
    const gas = await client.estimateContractGas({ address, abi, functionName, args: fnArgs, account } as never);
    const hash = await wallet.writeContract({ address, abi, functionName, args: fnArgs, gas: gas * 3n / 2n + 100_000n } as never);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${functionName} reverted`);
    if (functionName === 'createAndDepositSubAccount') {
      const event = receipt.logs
        .filter((log) => log.address.toLowerCase() === MATCHING.toLowerCase())
        .map((log) => {
          try {
            return decodeEventLog({ abi, data: log.data, topics: log.topics });
          } catch {
            return null;
          }
        })
        .find((d) => d?.eventName === 'DepositedSubAccount');
      if (event?.eventName !== 'DepositedSubAccount') throw new Error(`${label}: no DepositedSubAccount`);
      const id = event.args.accountId.toString();
      writeFileSync(accountsFile, JSON.stringify({ ...readAccounts(), [label]: id }, null, 2));
      console.log(JSON.stringify({ label, address: account.address, subaccountId: id, usdc: usdcWhole.toString() }));
    }
  }
}

type Row = { limit_price: string; desired_amount: string };
async function book(symbol: string) {
  const response = await fetch(`${MARKETS}/v1/book?symbol=${encodeURIComponent(symbol)}`);
  if (!response.ok) throw new Error(`book ${symbol}: ${response.status}`);
  return (await response.json()) as { bids: Row[]; asks: Row[] };
}

const toE18 = (decimal: string) => {
  const [whole, frac = ''] = decimal.split('.');
  return BigInt(whole) * E18 + BigInt((frac + '0'.repeat(18)).slice(0, 18));
};

let lastNonce = 0n;
const nonce = () => {
  const fromClock = BigInt(Date.now()) * 4096n;
  lastNonce = fromClock > lastNonce ? fromClock : lastNonce + 1n;
  return lastNonce;
};

/** Places a signed order the way the trading app would: engine units, desired_amount in venue units. */
async function placeOrder(label: string, l: Listing, side: 'buy' | 'sell', price: bigint, units: bigint) {
  const account = keyFor(label);
  const subaccountId = accountOf(label);
  const scale = BigInt(l.amount_scale);
  // The fee bound per cNGN: the premium's taker bps plus 5 bps of headroom, rounded up.
  const worstFee = (price * BigInt(l.taker_fee_bps + 5) + 9_999n) / 10_000n;
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 600);
  const orderNonce = nonce();
  const owner = getAddress(account.address);
  const module = getAddress('0xDea968188598BA0E3F58A56C0fdfF338C74F699f');
  const data = encodeAbiParameters(
    [{ type: 'tuple', components: [
      { name: 'asset', type: 'address' }, { name: 'subId', type: 'uint256' }, { name: 'limitPrice', type: 'int256' },
      { name: 'desiredAmount', type: 'int256' }, { name: 'worstFee', type: 'uint256' }, { name: 'recipientId', type: 'uint256' },
      { name: 'isBid', type: 'bool' }] }],
    [{ asset: getAddress(l.asset_address), subId: BigInt(l.sub_id), limitPrice: price, desiredAmount: units * scale, worstFee,
      recipientId: subaccountId, isBid: side === 'buy' }],
  );
  const signature = await account.signTypedData({
    domain: { name: 'Matching', version: '1.0', chainId: LOCAL_CHAIN_ID, verifyingContract: MATCHING },
    primaryType: 'Action',
    types: { Action: [
      { name: 'subaccountId', type: 'uint256' }, { name: 'nonce', type: 'uint256' }, { name: 'module', type: 'address' },
      { name: 'data', type: 'bytes' }, { name: 'expiry', type: 'uint256' }, { name: 'owner', type: 'address' }, { name: 'signer', type: 'address' }] },
    message: { subaccountId, nonce: orderNonce, module, data, expiry, owner, signer: owner },
  });
  const orderId = `taker-${crypto.randomUUID()}`;
  const response = await fetch(`${MARKETS}/v1/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      action_json: { data, expiry: expiry.toString(), module, nonce: orderNonce.toString(), owner, signer: owner, subaccount_id: subaccountId.toString() },
      asset_address: l.asset_address, desired_amount: units.toString(), expiry: Number(expiry), filled_amount: '0',
      limit_price: formatUnits(price, 18), nonce: orderNonce.toString(), order_id: orderId, owner_address: owner,
      recipient_id: subaccountId.toString(), side, signer_address: owner, sub_id: l.sub_id, subaccount_id: subaccountId.toString(),
      worst_fee: worstFee.toString(), signature,
    }),
  });
  const body = await response.text();
  console.log(`${label} ${side} ${units} units (${units * scale / E18} cNGN) of ${l.market} @ ${formatUnits(price, 18)} -> ${response.status} ${body.slice(0, 160)}`);
  if (!response.ok) throw new Error(`order refused: ${response.status}`);
  return orderId;
}

const balanceOf = (account: bigint, asset: Address, subId: bigint) =>
  client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [account, asset, subId] });
const imOf = (account: bigint) => client.readContract({ address: ENGINE, abi, functionName: 'getMargin', args: [account, true] });

/**
 * Crosses the maker's best quote for `units`, waits for the fill to settle on chain, and checks:
 *  - both option positions moved by exactly units x amount_scale, opposite ways;
 *  - the taker paid premium x size plus the 15 bps fee, and the maker received the premium;
 *  - the maker's IM surplus moved by what the bot sizes with: the premium received less the engine's isolated
 *    requirement for the written size (getIsolatedMargin), to within 2% of the requirement.
 */
async function take(label: string, symbol: string, side: 'buy' | 'sell', units: bigint) {
  const l = await listing(symbol);
  const b = await book(symbol);
  const best = side === 'buy' ? b.asks[0] : b.bids[0];
  if (!best) throw new Error(`no maker ${side === 'buy' ? 'ask' : 'bid'} on ${symbol}`);
  const price = toE18(best.limit_price);
  const maker = accountOf('mm');
  const taker = accountOf(label);
  const asset = getAddress(l.asset_address);
  const subId = BigInt(l.sub_id);
  const size = units * BigInt(l.amount_scale);
  const before = {
    makerPos: await balanceOf(maker, asset, subId), takerPos: await balanceOf(taker, asset, subId),
    makerCash: await balanceOf(maker, CASH, 0n), takerCash: await balanceOf(taker, CASH, 0n), makerIM: await imOf(maker),
  };
  await placeOrder(label, l, side, price, units);
  const deadline = Date.now() + 120_000;
  let makerPos = before.makerPos;
  while (Date.now() < deadline) {
    makerPos = await balanceOf(maker, asset, subId);
    if (makerPos !== before.makerPos) break;
    await new Promise((r) => setTimeout(r, 1000));
  }
  const takerPos = await balanceOf(taker, asset, subId);
  const sign = side === 'buy' ? 1n : -1n;
  if (takerPos - before.takerPos !== sign * size || makerPos - before.makerPos !== -sign * size) {
    throw new Error(`positions: taker ${before.takerPos} -> ${takerPos}, maker ${before.makerPos} -> ${makerPos}; want ${sign * size} / ${-sign * size}`);
  }
  const premium = (price * size) / E18;
  const fee = (premium * BigInt(l.taker_fee_bps)) / 10_000n;
  const makerCash = await balanceOf(maker, CASH, 0n);
  const takerCash = await balanceOf(taker, CASH, 0n);
  const near = (got: bigint, want: bigint, tol: bigint) => (got > want ? got - want : want - got) <= tol;
  // Cash accrues interest between reads: a few wei per dollar per block, far inside 1e12.
  if (!near(makerCash - before.makerCash, sign * premium, 10n ** 12n)) {
    throw new Error(`maker cash moved ${makerCash - before.makerCash}, want ${sign * premium}`);
  }
  if (!near(before.takerCash - takerCash, sign * premium + fee, 10n ** 12n)) {
    throw new Error(`taker cash moved ${takerCash - before.takerCash}, want ${-(sign * premium + fee)}`);
  }
  const makerIM = await imOf(maker);
  const [isolated] = await client.readContract({
    address: ENGINE, abi, functionName: 'getIsolatedMargin',
    args: [1n, toE18(l.option.strike), BigInt(l.option.expiry_timestamp), l.option.option_type === 'call', -sign * size, true],
  });
  const predicted = before.makerIM + sign * premium + (sign > 0n ? isolated : -isolated);
  const tolerance = (isolated < 0n ? -isolated : isolated) / 50n;
  console.log(JSON.stringify({
    filled: `${units} units of ${symbol} @ ${formatUnits(price, 18)}`, premium_usdc: formatUnits(premium, 18), fee_usdc: formatUnits(fee, 18),
    maker_im_before: formatUnits(before.makerIM, 18), maker_im_after: formatUnits(makerIM, 18), predicted: formatUnits(predicted, 18),
    isolated_requirement: formatUnits(isolated, 18),
  }));
  if (sign > 0n && !near(makerIM, predicted, tolerance)) {
    throw new Error(`maker IM surplus ${formatUnits(makerIM, 18)}, predicted ${formatUnits(predicted, 18)} (+/- ${formatUnits(tolerance, 18)})`);
  }
  console.log('OK: positions, premium, fee and the writer\'s margin are as predicted');
}

switch (command) {
  case 'open-account':
    await openAccount(args[0]!, BigInt(args[1]!));
    break;
  case 'best': {
    const b = await book(args[0]!);
    console.log(JSON.stringify({ bid: b.bids[0] ?? null, ask: b.asks[0] ?? null }));
    break;
  }
  case 'quotes': {
    const b = await book(args[0]!);
    console.log(JSON.stringify({ bids: b.bids.length, asks: b.asks.length }));
    break;
  }
  case 'take':
    await take(args[0]!, args[1]!, args[2] as 'buy' | 'sell', BigInt(args[3]!));
    break;
  default:
    throw new Error(`unknown command ${command}`);
}
