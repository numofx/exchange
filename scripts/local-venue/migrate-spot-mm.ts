/**
 * Moves the spot market-maker's inventory from its spot account to a new unified account under the
 * perp SRM, for the unified-account cutover. Runs on the ops box, where the MM key is read from SSM
 * into the environment by a run-with-ssm wrapper and never written to disk:
 *
 *   MM_OWNER_PRIVATE_KEY=… MARKETS_URL=https://api.numofx.com RPC_URL=… \
 *     pnpm --dir scripts/local-venue exec tsx scripts/local-venue/migrate-spot-mm.ts <phase> [--execute]
 *
 * Phases, each idempotent and a dry run unless --execute is given:
 *   status     the MM's spot account, its balances and resting orders, and the perp stack's addresses
 *   cancel     cancel every resting order of the MM (the bot must be stopped first)
 *   withdraw   sign a WithdrawalModule action for the whole wrapped-USDC and spot-cNGN balances and
 *              submit each to the venue, which pays the tokens to the MM wallet
 *   deposit    open the unified account: SubAccountCreator.createAndDepositSubAccount with the USDC
 *              into the perp cash under the perp SRM, then escrow.deposit of the cNGN; prints the id
 *              to set as MM_SUBACCOUNT_ID / MM_RECIPIENT_ID
 *   deposit-cngn <id>  escrow.deposit of the wallet's whole cNGN into an existing unified account
 *              (the second half of `deposit` when its first half landed and the second did not)
 *   perp-cancel  cancel the perp maker's resting cNGN-PERP orders (stop market-maker-perp first: it does
 *              not cancel on shutdown). Spot orders, the other bot's, are not touched.
 *   perp-close <price> --against=<id>  buy back the perp maker's short on #MM_PERP_SUBACCOUNT_ID (24) at
 *              <price> USDC per cNGN, crossing the operator's resting sell on account <id>; refuses unless
 *              that account's asks cover the whole size and no one else's ask is at or under the price.
 *   perp-withdraw [usdc units] [--min-im-surplus=<usd>]  the perp maker's cash to the MM wallet
 *              (WithdrawalModule). With no amount: all of it, once it holds no perp position. With an amount:
 *              that much while a position is still open, refused unless the SRM's IM surplus left behind
 *              is at least --min-im-surplus (default $4). Either way, refused while any of the MM's perp
 *              orders rest: stop market-maker-perp and perp-cancel first, or it quotes from what is left.
 *   engine-account <usdc units>  open the futures market maker's account under the MarginEngine:
 *              SubAccountCreator.createAndDepositSubAccount with that much USDC into the future's cash
 *              (the perp's), manager the engine, both read from the future's listing; prints the id to
 *              set as mm_future_subaccount_id. Not idempotent: each --execute opens a new account.
 *
 * Everything here is what the app does for a user, with the MM's key instead of a wallet prompt.
 */
import { createPublicClient, createWalletClient, encodeAbiParameters, getAddress, http, nonceManager, parseAbi, type Address, type Hex, decodeEventLog } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';

const MARKETS = process.env.MARKETS_URL ?? 'https://api.numofx.com';
const RPC = process.env.RPC_URL ?? 'https://mainnet.base.org';
const KEY = process.env.MM_OWNER_PRIVATE_KEY as Hex | undefined;
const SPOT_ACCOUNT = BigInt(process.env.MM_SPOT_SUBACCOUNT_ID ?? '15');
const PERP_ACCOUNT = BigInt(process.env.MM_PERP_SUBACCOUNT_ID ?? '24');
const WS_AUTH_DOMAIN = process.env.WS_AUTH_DOMAIN ?? 'markets.numo.xyz';
const SPOT_SYMBOL = process.env.SPOT_SYMBOL ?? 'cNGN-USDC';

// Base mainnet, the retired spot stack and the shared custody contracts.
const MATCHING: Address = '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191';
const SUB_ACCOUNTS: Address = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843';
const SUBACCOUNT_CREATOR: Address = '0x568890A8D63Ba8a03b6eCbEedA1bD9f6ea014D5D';
const WITHDRAWAL_MODULE: Address = '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB';
const USDC: Address = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const CNGN: Address = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F';
const LEGACY = {
  srm: '0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b' as Address,
  wrappedUsdc: '0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84' as Address,
  cngnEscrow: '0x9d806fd040a719d27a8e5e77dc5ae0ed1e089493' as Address,
};

const abi = parseAbi([
  'function approve(address, uint256) returns (bool)',
  'function balanceOf(address) view returns (uint256)',
  'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
  'function manager(uint256 accountId) view returns (address)',
  'function createAndDepositSubAccount(address baseAsset, uint256 initDeposit, address manager) returns (uint256)',
  'function deposit(uint256 recipientAccount, uint256 amount)',
  'function subAccountToOwner(uint256) view returns (address)',
  'event DepositedSubAccount(uint256 indexed accountId, address indexed owner)',
  'function whitelistedManager(address) view returns (bool)',
  'function getMargin(uint256 accountId, bool isInitial) view returns (int256)',
]);

const client = createPublicClient({ chain: base, transport: http(RPC) });
const [phase, ...flags] = process.argv.slice(2);
const execute = flags.includes('--execute');
if (!phase) throw new Error('usage: migrate-spot-mm.ts <status|cancel|withdraw|deposit|deposit-cngn|perp-cancel|perp-close|perp-withdraw|engine-account> [--execute]');
if (!KEY) throw new Error('MM_OWNER_PRIVATE_KEY is not in the environment (run through the SSM wrapper on the box)');
// The relayer's lesson (perp-feeds): a load-balanced RPC can hand out a mined nonce again; viem's
// nonce manager never reissues one at or below the last it sent.
const owner = privateKeyToAccount(KEY, { nonceManager });
const wallet = createWalletClient({ account: owner, chain: base, transport: http(RPC) });

type PerpStack = { srm: Address; cash: Address; escrow: Address; module: Address };

/** The perp stack as the venue serves it: never typed in by hand. */
async function perpStack(): Promise<PerpStack> {
  const markets = (await (await fetch(`${MARKETS}/v1/markets`)).json()) as Record<string, unknown>[];
  const perp = markets.find((m) => m.contract_type === 'perpetual');
  if (!perp) throw new Error('the venue serves no perpetual');
  const p = perp.perp as Record<string, unknown>;
  const collateral = (p.collateral_assets as Record<string, string>[])?.find((a) => a.symbol === 'cNGN');
  if (!collateral) throw new Error('the perp lists no cNGN collateral asset');
  return {
    srm: getAddress(p.margin_manager_address as string),
    cash: getAddress(p.quote_asset_address as string),
    escrow: getAddress(collateral.asset_address),
    module: getAddress(p.trade_module_address as string),
  };
}

// A read straight after a transaction is pinned to the block it landed in: at `latest`, a node behind the
// one that returned the receipt answers with the state before it (2026-10-13: #32 read as under 0x0 one
// block after it was opened under the engine).
async function ledger(account: bigint, asset: Address, blockNumber?: bigint) {
  return client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [account, asset, 0n], blockNumber });
}

/** The venue's signed authentication frame (wsauth, order-history statement): what GET /v1/orders needs. */
async function authHeader() {
  const now = Math.floor(Date.now() / 1000);
  const frame = { address: owner.address.toLowerCase(), nonce: `${now}-${Math.random().toString(36).slice(2)}`, issued_at: now, expiry: now + 300 };
  // The order-history statement (wsauth OrderHistoryStatement), byte-for-byte as the app signs it.
  const message = `${WS_AUTH_DOMAIN} wants you to view your Numo order history.\nAddress: ${frame.address}\nNonce: ${frame.nonce}\nIssued At: ${frame.issued_at}\nExpiration Time: ${frame.expiry}`;
  const signature = await owner.signMessage({ message });
  return Buffer.from(JSON.stringify({ ...frame, signature })).toString('base64url');
}

type HistoryOrder = { order_id: string; nonce: string; status: string; market?: string; owner_address: string };

/** Every resting order of the MM: the order history, newest first, 100 a page, walked to its end. */
async function restingOrders(market = SPOT_SYMBOL) {
  const auth = await authHeader();
  const resting: HistoryOrder[] = [];
  let before = '';
  for (let page = 0; page < 200; page++) {
    const url = `${MARKETS}/v1/orders?limit=100${before ? `&before=${encodeURIComponent(before)}` : ''}`;
    const response = await fetch(url, { headers: { 'X-Numo-Auth': auth } });
    if (!response.ok) throw new Error(`GET /v1/orders -> ${response.status} ${await response.text()}`);
    const body = (await response.json()) as { orders: HistoryOrder[]; next_before?: string };
    // The venue's resting statuses: active on the book, or matching (a fill in flight). Spot only:
    // the perp maker quotes from the same wallet, and its orders are not this migration's to touch.
    resting.push(...body.orders.filter((o) => (o.status === 'active' || o.status === 'matching') && o.market === market));
    if (!body.next_before) break;
    before = body.next_before;
  }
  return resting;
}

async function status() {
  const mgr = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'manager', args: [SPOT_ACCOUNT] });
  const custodian = await client.readContract({ address: MATCHING, abi, functionName: 'subAccountToOwner', args: [SPOT_ACCOUNT] });
  const stack = await perpStack();
  const out = {
    mmWallet: owner.address,
    spotAccount: SPOT_ACCOUNT.toString(),
    spotAccountManager: mgr,
    spotAccountOwnerInMatching: custodian,
    spotWrappedUsdc: (await ledger(SPOT_ACCOUNT, LEGACY.wrappedUsdc)).toString(),
    spotCngn: (await ledger(SPOT_ACCOUNT, LEGACY.cngnEscrow)).toString(),
    walletUsdc: (await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner.address] })).toString(),
    walletCngn: (await client.readContract({ address: CNGN, abi, functionName: 'balanceOf', args: [owner.address] })).toString(),
    restingSpotOrders: (await restingOrders()).length,
    perpStack: stack,
  };
  if (custodian.toLowerCase() !== owner.address.toLowerCase()) throw new Error(`spot account #${SPOT_ACCOUNT} is not the MM's in Matching (owner ${custodian})`);
  console.log(JSON.stringify(out, null, 2));
}

async function cancel() {
  const orders = await restingOrders();
  console.log(`${orders.length} resting ${SPOT_SYMBOL} order(s) of ${owner.address}`);
  for (const order of orders) {
    if (!execute) {
      console.log(`dry run: would cancel ${order.order_id} (nonce ${order.nonce})`);
      continue;
    }
    const response = await fetch(`${MARKETS}/v1/orders/cancel`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ owner_address: owner.address.toLowerCase(), nonce: order.nonce, reason: 'unified_cutover', service: 'migrate-spot-mm' }),
    });
    console.log(`cancel ${order.order_id} -> ${response.status}`);
  }
}

/** A signed WithdrawalModule action for `amount` (token decimals) of `escrow`, submitted to the venue. */
async function withdrawOne(escrow: Address, token: Address, decimals: number, account = SPOT_ACCOUNT, units?: bigint) {
  const held = await ledger(account, escrow);
  if (held <= 0n) {
    console.log(`${escrow}: nothing to withdraw`);
    return;
  }
  const all = held / 10n ** BigInt(18 - decimals); // ledger 18dp -> token decimals
  if (units !== undefined && units > all) throw new Error(`#${account} holds ${all} token units, under the ${units} asked for`);
  const amount = units ?? all;
  const data = encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [escrow, amount]);
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 600);
  const nonce = BigInt(Date.now());
  if (!execute) {
    console.log(`dry run: would withdraw ${amount} (token units) of ${escrow} from #${account} to ${owner.address}`);
    return;
  }
  const signature = await owner.signTypedData({
    domain: { name: 'Matching', version: '1.0', chainId: base.id, verifyingContract: MATCHING },
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
    message: { subaccountId: account, nonce, module: WITHDRAWAL_MODULE, data, expiry, owner: owner.address, signer: owner.address },
  });
  const head = await client.getBlockNumber();
  const before = await client.readContract({ address: token, abi, functionName: 'balanceOf', args: [owner.address], blockNumber: head });
  const response = await fetch(`${MARKETS}/v1/withdrawals`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      action: { subaccount_id: account.toString(), nonce: nonce.toString(), module: WITHDRAWAL_MODULE, data, expiry: expiry.toString(), owner: owner.address, signer: owner.address },
      signature,
    }),
  });
  const body = await response.text();
  console.log(`withdraw ${escrow} -> ${response.status} ${body.slice(0, 200)}`);
  if (!response.ok) throw new Error('withdrawal refused');
  const landed = BigInt((JSON.parse(body) as { block_number?: string }).block_number ?? '0');
  if (landed === 0n) throw new Error('the venue did not report the block the withdrawal landed in');
  await client.waitForTransactionReceipt({ hash: (JSON.parse(body) as { tx_hash: Hex }).tx_hash });
  const after = await client.readContract({ address: token, abi, functionName: 'balanceOf', args: [owner.address], blockNumber: landed });
  if (after - before !== amount) throw new Error(`wallet received ${after - before} between blocks ${head} and ${landed}, expected ${amount}`);
  console.log(`ok: ${amount} token units landed in ${owner.address}`);
}

async function withdraw() {
  await withdrawOne(LEGACY.wrappedUsdc, USDC, 6);
  await withdrawOne(LEGACY.cngnEscrow, CNGN, 6);
}

async function deposit() {
  const stack = await perpStack();
  const usdc = await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner.address] });
  const cngn = await client.readContract({ address: CNGN, abi, functionName: 'balanceOf', args: [owner.address] });
  console.log(`wallet holds ${usdc} USDC units and ${cngn} cNGN units; perp stack ${JSON.stringify(stack)}`);
  if (usdc === 0n) throw new Error('no USDC in the wallet to open the unified account with (withdraw first)');
  if (!execute) {
    console.log(`dry run: would createAndDepositSubAccount(${stack.cash}, ${usdc}, ${stack.srm}) then ${stack.escrow}.deposit(id, ${cngn})`);
    return;
  }
  const send = async (address: Address, functionName: 'approve' | 'createAndDepositSubAccount' | 'deposit', args: readonly unknown[]) => {
    const hash = await wallet.writeContract({ address, abi, functionName, args } as never);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${functionName} reverted (${hash})`);
    return receipt;
  };
  await send(USDC, 'approve', [SUBACCOUNT_CREATOR, usdc]);
  const receipt = await send(SUBACCOUNT_CREATOR, 'createAndDepositSubAccount', [stack.cash, usdc, stack.srm]);
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
  if (event?.eventName !== 'DepositedSubAccount') throw new Error('no DepositedSubAccount event');
  const id = event.args.accountId;
  console.log(`ok: unified account #${id} opened under ${stack.srm} with ${usdc} USDC units of cash`);
  if (cngn > 0n) {
    await send(CNGN, 'approve', [stack.escrow, cngn]);
    await send(stack.escrow, 'deposit', [id, cngn]);
    console.log(`ok: ${cngn} cNGN units deposited into ${stack.escrow} for #${id}`);
  }
  console.log(`set MM_SUBACCOUNT_ID=${id} and MM_RECIPIENT_ID=${id} (Terraform mm vars) before restarting the market-maker`);
}

async function depositCngn() {
  const id = BigInt(flags.find((f) => /^[0-9]+$/.test(f)) ?? '0');
  if (id === 0n) throw new Error('deposit-cngn needs the unified account id');
  const stack = await perpStack();
  const mgr = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'manager', args: [id] });
  if (mgr.toLowerCase() !== stack.srm.toLowerCase()) throw new Error(`account #${id} is under ${mgr}, not the perp SRM`);
  const custodian = await client.readContract({ address: MATCHING, abi, functionName: 'subAccountToOwner', args: [id] });
  if (custodian.toLowerCase() !== owner.address.toLowerCase()) throw new Error(`account #${id} is not the MM's in Matching (owner ${custodian})`);
  const cngn = await client.readContract({ address: CNGN, abi, functionName: 'balanceOf', args: [owner.address] });
  if (cngn === 0n) throw new Error('no cNGN in the wallet');
  console.log(`wallet holds ${cngn} cNGN units; depositing into #${id} via ${stack.escrow}`);
  if (!execute) {
    console.log(`dry run: would approve ${stack.escrow} for ${cngn} and call deposit(${id}, ${cngn})`);
    return;
  }
  const send = async (address: Address, functionName: 'approve' | 'deposit', args: readonly unknown[]) => {
    const hash = await wallet.writeContract({ address, abi, functionName, args } as never);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${functionName} reverted (${hash})`);
    return receipt;
  };
  await send(CNGN, 'approve', [stack.escrow, cngn]);
  const deposited = await send(stack.escrow, 'deposit', [id, cngn]);
  const held = await ledger(id, stack.escrow, deposited.blockNumber);
  console.log(`ok: #${id} now holds ${held} (18dp) in ${stack.escrow}`);
}

/** The future as the venue lists it: its cash and its manager (the MarginEngine), never typed in by hand. */
async function futureStack(): Promise<{ cash: Address; engine: Address; symbol: string }> {
  const markets = (await (await fetch(`${MARKETS}/v1/markets`)).json()) as Record<string, unknown>[];
  const futures = markets.filter((m) => m.future && m.contract_type === 'future');
  if (futures.length !== 1) throw new Error(`the venue lists ${futures.length} MarginEngine futures, expected 1`);
  const f = futures[0];
  return { cash: getAddress(f.quote_asset_address as string), engine: getAddress(f.margin_manager_address as string), symbol: String(f.market) };
}

async function engineAccount() {
  const units = BigInt(flags.find((f) => /^[0-9]+$/.test(f)) ?? '0');
  if (units === 0n) throw new Error('engine-account needs the USDC amount in units (6dp), e.g. 4000000000 for 4,000');
  const { cash, engine, symbol } = await futureStack();
  const takes = await client.readContract({ address: cash, abi, functionName: 'whitelistedManager', args: [engine] });
  if (!takes) throw new Error(`${cash} does not take ${engine} as a manager: the setup batch has not landed`);
  const usdc = await client.readContract({ address: USDC, abi, functionName: 'balanceOf', args: [owner.address] });
  const eth = await client.getBalance({ address: owner.address });
  console.log(`${symbol}: cash ${cash}, engine ${engine}; ${owner.address} holds ${usdc} USDC units and ${eth} wei`);
  if (usdc < units) throw new Error(`the wallet holds ${usdc} USDC units, under the ${units} to deposit`);
  if (!execute) {
    console.log(`dry run: would approve ${SUBACCOUNT_CREATOR} for ${units} and createAndDepositSubAccount(${cash}, ${units}, ${engine})`);
    return;
  }
  const send = async (address: Address, functionName: 'approve' | 'createAndDepositSubAccount', args: readonly unknown[]) => {
    const hash = await wallet.writeContract({ address, abi, functionName, args } as never);
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status !== 'success') throw new Error(`${functionName} reverted (${hash})`);
    console.log(`  ${functionName} ${hash} block ${receipt.blockNumber}`);
    return receipt;
  };
  await send(USDC, 'approve', [SUBACCOUNT_CREATOR, units]);
  const receipt = await send(SUBACCOUNT_CREATOR, 'createAndDepositSubAccount', [cash, units, engine]);
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
  if (event?.eventName !== 'DepositedSubAccount') throw new Error('no DepositedSubAccount event');
  const id = event.args.accountId;
  const at = receipt.blockNumber;
  const mgr = await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'manager', args: [id], blockNumber: at });
  const custodian = await client.readContract({ address: MATCHING, abi, functionName: 'subAccountToOwner', args: [id], blockNumber: at });
  const held = await ledger(id, cash, at);
  const im = await client.readContract({ address: engine, abi, functionName: 'getMargin', args: [id, true], blockNumber: at });
  if (mgr.toLowerCase() !== engine.toLowerCase()) throw new Error(`#${id} is under ${mgr}, not the engine`);
  if (custodian.toLowerCase() !== owner.address.toLowerCase()) throw new Error(`#${id} is not the MM's in Matching (owner ${custodian})`);
  console.log(`ok: #${id} under ${engine}, the MM's in Matching, cash ${held} (18dp), IM surplus ${im} (18dp)`);
  console.log(`set mm_future_subaccount_id = "${id}" (infra/aws/market-maker-future.tf) before starting the future market maker`);
}

/** The perp as the venue lists it: never typed in by hand. */
async function perpListing() {
  const markets = (await (await fetch(`${MARKETS}/v1/markets`)).json()) as Record<string, unknown>[];
  const m = markets.find((x) => x.contract_type === 'perpetual');
  if (!m) throw new Error('the venue serves no perpetual');
  return {
    market: String(m.market),
    asset: getAddress(m.asset_address as string),
    subId: BigInt(m.sub_id as string),
    module: getAddress(m.trade_module_address as string),
    cash: getAddress(m.quote_asset_address as string),
    takerFeeBps: BigInt(m.taker_fee_bps as number),
    manager: getAddress((m.perp as Record<string, unknown>).margin_manager_address as string),
  };
}

const signAction = (subaccountId: bigint, nonce: bigint, module: Address, data: Hex, expiry: bigint) =>
  owner.signTypedData({
    domain: { name: 'Matching', version: '1.0', chainId: base.id, verifyingContract: MATCHING },
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
    message: { subaccountId, nonce, module, data, expiry, owner: owner.address, signer: owner.address },
  });

async function perpCancel() {
  const perp = await perpListing();
  const orders = await restingOrders(perp.market);
  console.log(`${orders.length} resting ${perp.market} order(s) of ${owner.address}`);
  for (const order of orders) {
    if (!execute) {
      console.log(`dry run: would cancel ${order.order_id} (nonce ${order.nonce})`);
      continue;
    }
    const response = await fetch(`${MARKETS}/v1/orders/cancel`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ owner_address: owner.address.toLowerCase(), nonce: order.nonce, reason: 'perp_maker_stopped', service: 'migrate-spot-mm' }),
    });
    console.log(`cancel ${order.order_id} -> ${response.status}`);
  }
}

/** USDC per cNGN as a decimal string to 18dp, exactly. */
function parsePrice(raw: string): bigint {
  const m = /^([0-9]+)(?:\.([0-9]{1,18}))?$/.exec(raw.trim());
  if (!m) throw new Error(`price ${raw} is not a decimal with at most 18 places`);
  return BigInt(m[1]) * 10n ** 18n + BigInt((m[2] ?? '').padEnd(18, '0'));
}
const decimal18 = (v: bigint) => `${v / 10n ** 18n}.${(v % 10n ** 18n).toString().padStart(18, '0')}`.replace(/\.?0+$/, '');

async function perpClose() {
  const raw = flags.find((f) => /^[0-9.]+$/.test(f));
  if (!raw) throw new Error('perp-close needs the price, USDC per cNGN, e.g. 0.000732');
  const price = parsePrice(raw);
  const perp = await perpListing();
  const position = await ledger(PERP_ACCOUNT, perp.asset);
  if (position >= 0n) throw new Error(`#${PERP_ACCOUNT} holds ${position} of the perp: no short to close`);
  if (position % 10n ** 18n !== 0n) throw new Error(`#${PERP_ACCOUNT}'s short ${position} is not a whole cNGN`);
  const amount = -position; // 18dp
  // The counterparty: the operator's own account, whose resting sell this buy is meant to cross. Every
  // ask at or under the price must be its, so the buy cannot fill against anyone else.
  const against = flags.find((f) => f.startsWith('--against='))?.slice('--against='.length);
  if (!against || !/^[0-9]+$/.test(against)) throw new Error('perp-close needs --against=<the account whose sell it crosses>');
  type Resting = { subaccount_id: string; limit_price: string; desired_amount: string; filled_amount: string };
  const book = (await (await fetch(`${MARKETS}/v1/book?symbol=${encodeURIComponent(perp.market)}`)).json()) as { asks?: Resting[] };
  const crossing = (book.asks ?? []).filter((a) => parsePrice(a.limit_price) <= price);
  const strangers = crossing.filter((a) => a.subaccount_id !== against);
  if (strangers.length) throw new Error(`${strangers.length} ask(s) at or under ${decimal18(price)} are not #${against}'s (${strangers.map((a) => `#${a.subaccount_id}`).join(', ')}): the buy could fill against them`);
  const depth = crossing.reduce((sum, a) => sum + BigInt(a.desired_amount) - BigInt(a.filled_amount), 0n) * 10n ** 18n;
  console.log(`#${PERP_ACCOUNT} is short ${decimal18(amount)} cNGN; #${against}'s asks at or under ${decimal18(price)}: ${decimal18(depth)} cNGN`);
  if (depth < amount) throw new Error(`#${against} has no resting ask for the whole ${decimal18(amount)} cNGN at that price: place the sell first`);
  // TM_FeeTooHigh bounds the fee per unit filled: price x (taker + 5 bps headroom), rounded up, as mm-bot signs it.
  const worstFee = (price * (perp.takerFeeBps + 5n) + 9_999n) / 10_000n || 1n;
  const data = encodeAbiParameters(
    [{ type: 'tuple', components: [
      { name: 'asset', type: 'address' }, { name: 'subId', type: 'uint256' }, { name: 'limitPrice', type: 'int256' },
      { name: 'desiredAmount', type: 'int256' }, { name: 'worstFee', type: 'uint256' }, { name: 'recipientId', type: 'uint256' },
      { name: 'isBid', type: 'bool' }] }],
    [{ asset: perp.asset, subId: perp.subId, limitPrice: price, desiredAmount: amount, worstFee, recipientId: PERP_ACCOUNT, isBid: true }],
  );
  const nonce = BigInt(Date.now()) * 1000n;
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 600);
  if (!execute) {
    console.log(`dry run: would buy ${decimal18(amount)} cNGN of ${perp.market} at ${decimal18(price)} from #${PERP_ACCOUNT} (worstFee ${worstFee}/unit)`);
    return;
  }
  const signature = await signAction(PERP_ACCOUNT, nonce, perp.module, data, expiry);
  const orderId = `manual:perp-close-${PERP_ACCOUNT}-${nonce}`;
  const response = await fetch(`${MARKETS}/v1/orders`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      order_id: orderId, owner_address: owner.address, signer_address: owner.address,
      subaccount_id: PERP_ACCOUNT.toString(), recipient_id: PERP_ACCOUNT.toString(), nonce: nonce.toString(),
      asset_address: perp.asset, sub_id: perp.subId.toString(), filled_amount: '0', worst_fee: worstFee.toString(),
      expiry: Number(expiry), side: 'buy', desired_amount: (amount / 10n ** 18n).toString(), limit_price: decimal18(price),
      action_json: { subaccount_id: PERP_ACCOUNT.toString(), nonce: nonce.toString(), module: perp.module, data, expiry: expiry.toString(), owner: owner.address, signer: owner.address },
      signature,
    }),
  });
  console.log(`order ${orderId} -> ${response.status} ${(await response.text()).slice(0, 300)}`);
  if (!response.ok) throw new Error('order refused');
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 6_000));
    const now = await ledger(PERP_ACCOUNT, perp.asset);
    if (now === 0n) {
      console.log(`ok: #${PERP_ACCOUNT} holds no perp position`);
      return;
    }
  }
  throw new Error(`#${PERP_ACCOUNT} still holds ${await ledger(PERP_ACCOUNT, perp.asset)} after 4 min: check the order`);
}

async function perpWithdraw() {
  const perp = await perpListing();
  const resting = await restingOrders(perp.market);
  if (resting.length) throw new Error(`${resting.length} ${perp.market} order(s) still resting: stop market-maker-perp and perp-cancel first`);
  const position = await ledger(PERP_ACCOUNT, perp.asset);
  const raw = flags.find((f) => /^[0-9]+$/.test(f));
  if (raw === undefined) {
    if (position !== 0n) throw new Error(`#${PERP_ACCOUNT} still holds ${position} of the perp: close it first, or withdraw an amount`);
    await withdrawOne(perp.cash, USDC, 6, PERP_ACCOUNT);
    return;
  }
  // A partial withdrawal with the position open: cash leaves 1:1 against the SRM's IM surplus, so what
  // is left is the surplus now less the amount (6dp -> 18dp).
  const units = BigInt(raw);
  const minSurplusUsd = flags.find((f) => f.startsWith('--min-im-surplus='))?.slice('--min-im-surplus='.length) ?? '4';
  if (!/^[0-9]+(\.[0-9]{1,6})?$/.test(minSurplusUsd)) throw new Error(`--min-im-surplus=${minSurplusUsd} is not a USD amount`);
  const [whole, frac = ''] = minSurplusUsd.split('.');
  const minSurplus = (BigInt(whole) * 10n ** 6n + BigInt(frac.padEnd(6, '0'))) * 10n ** 12n;
  const surplus = await client.readContract({ address: perp.manager, abi, functionName: 'getMargin', args: [PERP_ACCOUNT, true] });
  const left = surplus - units * 10n ** 12n;
  console.log(`#${PERP_ACCOUNT}: perp position ${position}, IM surplus ${surplus} (18dp); withdrawing ${units} USDC units leaves ${left}, floor ${minSurplus}`);
  if (left < minSurplus) throw new Error(`withdrawing ${units} would leave an IM surplus of ${left} (18dp), under the ${minSurplus} floor`);
  await withdrawOne(perp.cash, USDC, 6, PERP_ACCOUNT, units);
}

const phases: Record<string, () => Promise<void>> = { status, cancel, withdraw, deposit, 'deposit-cngn': depositCngn,
  'perp-cancel': perpCancel, 'perp-close': perpClose, 'perp-withdraw': perpWithdraw, 'engine-account': engineAccount,
};
const run = phases[phase];
if (!run) throw new Error(`unknown phase ${phase}`);
void run();
