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
 *
 * Everything here is what the app does for a user, with the MM's key instead of a wallet prompt.
 */
import { createPublicClient, createWalletClient, encodeAbiParameters, getAddress, http, parseAbi, type Address, type Hex, decodeEventLog } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';

const MARKETS = process.env.MARKETS_URL ?? 'https://api.numofx.com';
const RPC = process.env.RPC_URL ?? 'https://mainnet.base.org';
const KEY = process.env.MM_OWNER_PRIVATE_KEY as Hex | undefined;
const SPOT_ACCOUNT = BigInt(process.env.MM_SPOT_SUBACCOUNT_ID ?? '15');
const WS_AUTH_DOMAIN = process.env.WS_AUTH_DOMAIN ?? 'markets.numo.xyz';

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
]);

const client = createPublicClient({ chain: base, transport: http(RPC) });
const [phase, ...flags] = process.argv.slice(2);
const execute = flags.includes('--execute');
if (!phase) throw new Error('usage: migrate-spot-mm.ts <status|cancel|withdraw|deposit> [--execute]');
if (!KEY) throw new Error('MM_OWNER_PRIVATE_KEY is not in the environment (run through the SSM wrapper on the box)');
const owner = privateKeyToAccount(KEY);
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

async function ledger(account: bigint, asset: Address) {
  return client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [account, asset, 0n] });
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

async function restingOrders() {
  const response = await fetch(`${MARKETS}/v1/orders?limit=200`, { headers: { 'X-Numo-Auth': await authHeader() } });
  if (!response.ok) throw new Error(`GET /v1/orders -> ${response.status} ${await response.text()}`);
  const body = (await response.json()) as { orders: { order_id: string; nonce: string; status: string; market?: string; owner_address: string }[] };
  // The venue's resting statuses: active on the book, or matching (a fill in flight).
  return body.orders.filter((o) => o.status === 'active' || o.status === 'matching');
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
    restingOrders: (await restingOrders()).length,
    perpStack: stack,
  };
  if (custodian.toLowerCase() !== owner.address.toLowerCase()) throw new Error(`spot account #${SPOT_ACCOUNT} is not the MM's in Matching (owner ${custodian})`);
  console.log(JSON.stringify(out, null, 2));
}

async function cancel() {
  const orders = await restingOrders();
  console.log(`${orders.length} resting order(s) of ${owner.address}`);
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
async function withdrawOne(escrow: Address, token: Address, decimals: number) {
  const held = await ledger(SPOT_ACCOUNT, escrow);
  if (held <= 0n) {
    console.log(`${escrow}: nothing to withdraw`);
    return;
  }
  const amount = held / 10n ** BigInt(18 - decimals); // ledger 18dp -> token decimals
  const data = encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [escrow, amount]);
  const expiry = BigInt(Math.floor(Date.now() / 1000) + 600);
  const nonce = BigInt(Date.now());
  if (!execute) {
    console.log(`dry run: would withdraw ${amount} (token units) of ${escrow} from #${SPOT_ACCOUNT} to ${owner.address}`);
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
    message: { subaccountId: SPOT_ACCOUNT, nonce, module: WITHDRAWAL_MODULE, data, expiry, owner: owner.address, signer: owner.address },
  });
  const before = await client.readContract({ address: token, abi, functionName: 'balanceOf', args: [owner.address] });
  const response = await fetch(`${MARKETS}/v1/withdrawals`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      action: { subaccount_id: SPOT_ACCOUNT.toString(), nonce: nonce.toString(), module: WITHDRAWAL_MODULE, data, expiry: expiry.toString(), owner: owner.address, signer: owner.address },
      signature,
    }),
  });
  const body = await response.text();
  console.log(`withdraw ${escrow} -> ${response.status} ${body.slice(0, 200)}`);
  if (!response.ok) throw new Error('withdrawal refused');
  const after = await client.readContract({ address: token, abi, functionName: 'balanceOf', args: [owner.address] });
  if (after - before !== amount) throw new Error(`wallet received ${after - before}, expected ${amount}`);
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

const phases: Record<string, () => Promise<void>> = { status, cancel, withdraw, deposit };
const run = phases[phase];
if (!run) throw new Error(`unknown phase ${phase}`);
void run();
