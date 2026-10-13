/**
 * Dress rehearsal for the USDC/cNGN future on a Base mainnet fork, end to end and with nothing mocked
 * inside the contracts or the keeper:
 *
 *   - anvil forks Base at head (chain id 31337, so the deploy artifacts land in the gitignored
 *     deployments/31337 and the keeper accepts a raw signer key);
 *   - deploy-margin-engine.s.sol is run unchanged with `forge script --broadcast`: MarginEngine beside the live SRM,
 *     with spot cNGN, the perp and the future in one account;
 *   - the vault's two batches go through propose_margin_engine_batch.py's checks (--local: rebuilt from the
 *     deployment artifact, every gate read from the fork, the enable batch refused until the pager runs
 *     and the future is listed), then are executed by impersonating the vault;
 *   - three traders open positions on the live perp cash and cNGN escrow, and a treasury funds the pool;
 *   - the real keeper (dist/forward-main.js) runs as its own process against the fork, reading a stub
 *     markets-service book and posting alerts to a stub webhook;
 *   - the keeper's own sweep realises VM after each mark (the harness never settles an account);
 *   - the pager runs once against the fork with the future open, and must count it;
 *   - the clock is walked through marks (no book, a deep book, a dust book), the band's narrowing, the
 *     fixing window (with the keeper killed and restarted inside it), settlement and close-out.
 *
 * The index is the live perp index feed, with a rehearsal signer added by the vault, re-signed after
 * every clock move (its heartbeat is 20 minutes). Trades go straight through SubAccounts, as in
 * CngnFutureDeployFork, not through the TradeModule and matcher.
 *
 * Not covered: the KMS signer, the systemd unit and run-with-ssm-forward.sh on the ops box.
 *
 * Usage (from services/perp-feeds, after `pnpm build` and `forge build` in contracts/risk-core):
 *   FORK_URL=https://mainnet.base.org pnpm tsx scripts/rehearse-future-fork.ts
 */
import assert from 'node:assert/strict';
import { spawn, spawnSync, type ChildProcess } from 'node:child_process';
import { copyFileSync, createWriteStream, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  encodePacked,
  formatUnits,
  http,
  keccak256,
  parseAbi,
  parseAbiItem,
  toHex,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import { encodeManagerData, encodeSpotData, encodeSpotDiffData, signFeedUpdate } from '../src/feed-data.js';
import { carryForward, invert, ONE } from '../src/forward-targets.js';

const FORK_URL = process.env.FORK_URL ?? 'https://mainnet.base.org';
const PORT = Number(process.env.ANVIL_PORT ?? 8547);
const RPC = `http://127.0.0.1:${PORT}`;
const BOOK_PORT = PORT + 1;
const HOOK_PORT = PORT + 2;
const MARKETS_PORT = PORT + 3;
const KEEPER_PORT = PORT + 4;

const ROOT = join(import.meta.dirname, '../../..');
const RISK_CORE = join(ROOT, 'contracts/risk-core');
const SERVICE = join(ROOT, 'services/perp-feeds');
const MAINNET = join(RISK_CORE, 'deployments/8453');
const LOCAL = join(RISK_CORE, 'deployments/31337');
const OUT = process.env.REHEARSAL_OUT ?? join(tmpdir(), 'numo-future-rehearsal');

const VAULT = '0x1dcA42ab54Bd3862853A821F84B29BF65245F435' as Address;
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' as Address;
const CNGN = '0x46C85152bFe9f96829aA94755D9f915F9B10EF5F' as Address;
const CARRY = 2n * 10n ** 17n; // 20% a year
/**
 * Each token's balances mapping slot, found by matching storage to balanceOf on Base. anvil_dealERC20
 * finds neither ("no slot found"). USDC's slot 9 packs a blacklist flag in the top bit, left clear.
 */
const BALANCE_SLOT: Record<string, bigint> = { [USDC]: 9n, [CNGN]: 201n };
const COPIED = ['core.json', 'CNGN_PERP_STACK.json', 'CNGN_PERP_COLLATERAL.json'];
// what the deploy writes there: removed afterwards, so nothing reads a fork's addresses as real ones
const WRITTEN = ['MARGIN_ENGINE', 'MARGIN_ENGINE_VAULT_ACTIONS', 'MARGIN_ENGINE_ENABLE_VAULT_ACTIONS'].map((n) => `${n}.json`);

// Derived, not anvil's defaults: well-known keys carry EIP-7702 delegations on Base.
const key = (role: string) => keccak256(toHex(`numo.future-rehearsal.${role}`));
const KEYS = {
  deployer: key('deployer'),
  operator: key('operator'), // index relayer, account creator and trade submitter
  relayer: key('keeper-relayer'),
  forward: key('forward-signer'),
  index: key('index-signer'),
};
const addr = (k: Hex) => privateKeyToAccount(k).address;
const USERS = {
  treasury: '0x00000000000000000000000000000000007ea501' as Address,
  alice: '0x0000000000000000000000000000000000a11ce1' as Address,
  bob: '0x00000000000000000000000000000000000b0b01' as Address,
  carol: '0x00000000000000000000000000000000ca401001' as Address,
};

const abi = {
  erc20: parseAbi([
    'function approve(address, uint256) returns (bool)',
    'function balanceOf(address) view returns (uint256)',
  ]),
  feed: parseAbi([
    'function addSigner(address signer, bool isSigner)',
    'function getSpot() view returns (uint256, uint256)',
  ]),
  subAccounts: parseAbi([
    'struct AssetTransfer { uint256 fromAcc; uint256 toAcc; address asset; uint256 subId; int256 amount; bytes32 assetData; }',
    'function createAccountWithApproval(address owner, address spender, address manager) returns (uint256)',
    'function createAccount(address owner, address manager) returns (uint256)',
    'function lastAccountId() view returns (uint256)',
    'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
    'function submitTransfer(AssetTransfer assetTransfer, bytes managerData)',
  ]),
  deposit: parseAbi([
    'function deposit(uint256 recipientAccount, uint256 assetAmount)',
    'function withdraw(uint256 accountId, uint256 assetAmount, address recipient)',
  ]),
  manager: parseAbi([
    'function getMargin(uint256 accountId, bool isInitial) view returns (int256)',
    'function settleAccount(uint256 accountId)',
    'function withdrawFromPool(address asset, uint256 amount, address recipient)',
    'function setFutureMarginRequirements(uint256 marketId, uint256 mmFutureReq, uint256 imFutureReq)',
  ]),
  future: parseAbi([
    'struct FutureContract { bool listed; bool settled; uint64 expiry; uint64 lastTradeTime; uint64 lastMarkTime; uint256 markPrice; int256 cumulativeVMPerContract; }',
    'function futureContracts(uint256 subId) view returns (FutureContract)',
    'function totalPosition(address manager) view returns (uint256)',
    'function markIndexBand(uint64 expiry) view returns (uint256)',
    'function getPendingVM(uint256 accountId, uint256 subId) view returns (int256)',
    'function setContract(uint64 expiry, uint64 lastTradeTime, uint256 initialMarkPrice) returns (uint96)',
    'function setMark(uint96 subId, uint64 markTime, uint256 markPrice)',
  ]),
  submitter: parseAbi(['function submitData(bytes managerData)']),
};
const FIXING_SAMPLED = parseAbiItem('event FixingSampled(uint96 indexed subId, uint64 sampleTime, uint256 indexPrice)');

type Contract = { listed: boolean; settled: boolean; expiry: bigint; lastTradeTime: bigint; lastMarkTime: bigint; markPrice: bigint };
type Order = { side: 'buy' | 'sell'; limit_price: string; desired_amount: string; filled_amount: string };

const log = (msg: string) => console.log(`[rehearsal] ${msg}`);
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
const fmt = (v: bigint, dp = 18) => Number(formatUnits(v, dp)).toLocaleString('en-US', { maximumFractionDigits: 4 });
const relDiff = (a: bigint, b: bigint) => Number(((a > b ? a - b : b - a) * 10n ** 12n) / b) / 1e12;

async function main() {
  mkdirSync(OUT, { recursive: true });
  // state a previous run left would pass gates this run must earn: the pager's and the proposer's pager state
  for (const stale of ['pager-state.json', 'proposer-pager-state.json']) rmSync(join(OUT, stale), { force: true });
  const children: ChildProcess[] = [];
  const servers: Server[] = [];
  const cleanup = () => {
    for (const child of children) child.kill('SIGTERM');
    for (const server of servers) server.close();
    for (const file of [...COPIED, ...WRITTEN]) rmSync(join(LOCAL, file), { force: true });
  };
  process.on('exit', cleanup);
  process.on('SIGINT', () => process.exit(130));

  // ---- anvil ---------------------------------------------------------------------------------
  const anvil = spawn('anvil', ['--fork-url', FORK_URL, '--chain-id', '31337', '--port', String(PORT), '--silent'], {
    stdio: 'ignore',
  });
  children.push(anvil);
  const chain = defineChain({
    id: 31337,
    name: 'base-fork',
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [RPC] } },
  });
  const transport = http(RPC, { timeout: 120_000 });
  const pub = createPublicClient({ chain, transport });
  const test = createTestClient({ chain, mode: 'anvil', transport });
  for (let i = 0; ; i++) {
    try {
      await pub.getBlockNumber();
      break;
    } catch {
      if (i > 120) throw new Error('anvil did not start');
      await sleep(500);
    }
  }
  const forkBlock = await pub.getBlock({ blockTag: 'latest' });
  log(`anvil forked Base at block ${forkBlock.number} (${new Date(Number(forkBlock.timestamp) * 1000).toISOString()})`);

  for (const k of Object.values(KEYS)) await test.setBalance({ address: addr(k), value: 10n ** 20n });
  for (const a of [VAULT, ...Object.values(USERS)]) await test.setBalance({ address: a, value: 10n ** 20n });

  const as = (k: Hex) => createWalletClient({ account: privateKeyToAccount(k), chain, transport });
  const impersonated = async (a: Address) => {
    await test.impersonateAccount({ address: a });
    return createWalletClient({ account: a, chain, transport });
  };
  const operator = as(KEYS.operator);
  async function send(wallet: ReturnType<typeof as> | Awaited<ReturnType<typeof impersonated>>, address: Address, abiItems: readonly unknown[], functionName: string, args: readonly unknown[]) {
    const hash = await wallet.writeContract({ address, abi: abiItems, functionName, args, chain, account: wallet.account! } as never);
    const receipt = await pub.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, 'success', `${functionName} on ${address} reverted`);
    return receipt;
  }
  const read = <T>(address: Address, abiItems: readonly unknown[], functionName: string, args: readonly unknown[] = []) =>
    pub.readContract({ address, abi: abiItems, functionName, args } as never) as Promise<T>;
  const head = async () => (await pub.getBlock({ blockTag: 'latest' })).timestamp;

  // ---- the live stack ------------------------------------------------------------------------
  const core = JSON.parse(readFileSync(join(MAINNET, 'core.json'), 'utf8'));
  const stack = JSON.parse(readFileSync(join(MAINNET, 'CNGN_PERP_STACK.json'), 'utf8'));
  const collateral = JSON.parse(readFileSync(join(MAINNET, 'CNGN_PERP_COLLATERAL.json'), 'utf8'));
  const SUBACCOUNTS = core.subAccounts as Address;
  const SUBMITTER = core.dataSubmitter as Address;
  const INDEX = stack.indexFeed as Address;
  const CASH = stack.cash as Address;
  const ESCROW = collateral.escrow as Address;

  // The index: the vault adds a rehearsal signer, and every clock move is followed by a fresh signature.
  const [liveSpot] = await read<[bigint, bigint]>(INDEX, abi.feed, 'getSpot');
  let spot = liveSpot;
  const vault = await impersonated(VAULT);
  await send(vault, INDEX, abi.feed, 'addSigner', [addr(KEYS.index), true]);
  // the perp's mark and impact feeds, kept at the index (diff 0: mark = index, no funding) so the perp can trade
  const PERP_FEEDS = [stack.markFeed, stack.impactAskFeed, stack.impactBidFeed] as Address[];
  for (const feed of PERP_FEEDS) await send(vault, feed, abi.feed, 'addSigner', [addr(KEYS.index), true]);
  const indexSigner = privateKeyToAccount(KEYS.index);
  /** Signs the index for `at` and submits it. With `at` ahead of head, the submission is the block that moves the clock. */
  async function pushIndex(price = spot, at?: bigint) {
    spot = price;
    const now = at ?? (await head());
    const sign = (kind: 'LyraSpotFeed' | 'LyraSpotDiffFeed', feed: Address, data: Hex) =>
      signFeedUpdate({ signer: indexSigner, kind, feed, chainId: 31337, data, timestamp: now, deadline: now + 120n });
    const updates = [
      await sign('LyraSpotFeed', INDEX, encodeSpotData(price)),
      ...(await Promise.all(PERP_FEEDS.map((feed) => sign('LyraSpotDiffFeed', feed, encodeSpotDiffData(0n))))),
    ];
    if (at !== undefined) await test.setNextBlockTimestamp({ timestamp: at });
    await send(operator, SUBMITTER, abi.submitter, 'submitData', [encodeManagerData(updates)]);
  }
  /**
   * Moves the clock by `seconds` in the index update's own block, so no block ever holds a stale
   * index: mining first and signing after left one, and the keeper ticking into it alerted
   * forward-no-index for a gap the harness made.
   */
  async function advance(seconds: bigint, price = spot) {
    await pushIndex(price, (await head()) + seconds);
  }
  await pushIndex();
  log(`index ${fmt(invert(spot))} cNGN per USDC (live ${fmt(liveSpot)} USDC per cNGN)`);

  // ---- deploy, unchanged script ----------------------------------------------------------------
  for (const file of COPIED) copyFileSync(join(MAINNET, file), join(LOCAL, file));
  const deployHead = await head();
  const expiryDefault = 1796047200n;
  const initialMark = carryForward(invert(spot), CARRY, expiryDefault - deployHead);
  log(`deploying: INITIAL_MARK ${fmt(initialMark)} (carry forward), FORWARD_SIGNER ${addr(KEYS.forward)}`);
  const deployWith = () => spawnSync(
    'forge',
    ['script', 'scripts/deploy-margin-engine.s.sol', '--rpc-url', RPC, '--private-key', KEYS.deployer, '--broadcast'],
    {
      cwd: RISK_CORE,
      env: { ...process.env, INITIAL_MARK: initialMark.toString(), CARRY: CARRY.toString(), FORWARD_SIGNER: addr(KEYS.forward) },
      encoding: 'utf8',
      maxBuffer: 64 * 1024 * 1024,
    },
  );
  // A deployer key that has sent anything before is refused: the deploy must come from a single-use key. The
  // script allows nonce 1 (its own library deploy, deploy-margin-engine.s.sol:150), so two prior sends.
  const beforeUsedKey = await test.snapshot();
  const used = as(KEYS.deployer);
  for (let i = 0; i < 2; i++) {
    await pub.waitForTransactionReceipt({ hash: await used.sendTransaction({ to: addr(KEYS.deployer), value: 0n, chain, account: used.account! }) });
  }
  const usedKeyDeploy = deployWith();
  assert.notEqual(usedKeyDeploy.status, 0, 'a used deployer key is refused');
  assert.match(`${usedKeyDeploy.stdout}${usedKeyDeploy.stderr}`, /deployer key must be single use/, 'with the single-use message');
  log('a used deployer key is refused, as it should be');
  await test.revert({ id: beforeUsedKey });
  const forge = deployWith();
  const forgeLog = join(OUT, 'forge-deploy.log');
  writeFileSync(forgeLog, `${forge.stdout}\n${forge.stderr}`);
  assert.equal(forge.status, 0, `forge script failed, see ${forgeLog}`);
  const artifact = JSON.parse(readFileSync(join(LOCAL, 'MARGIN_ENGINE.json'), 'utf8'));
  const FUTURE = artifact.future as Address;
  const MANAGER = artifact.manager as Address;
  const FORWARD_FEED = artifact.forwardFeed as Address;
  const SUB_ID = BigInt(artifact.subId);
  const POOL = BigInt(artifact.poolAccount);
  const EXPIRY = BigInt(artifact.expiry);
  const LAST_TRADE = BigInt(artifact.lastTradeTime);
  log(`deployed future ${FUTURE} #${SUB_ID}, manager ${MANAGER}, forward feed ${FORWARD_FEED}, pool account ${POOL}`);

  // ---- the vault's batches, through the proposer's checks -------------------------------------------
  // propose_margin_engine_batch.py, in --local mode, rebuilds each batch from the deployment artifact and
  // reads every gate from the fork. It never proposes; the vault's side is played by impersonation.
  type Proposal = { gates: { name: string; ok: boolean; detail: string }[]; landed: boolean[] };
  // markets-service's /v1/markets, stubbed: until `listed`, the future is absent (no futures path yet); then it is
  // listed with the band the venue would enforce, computed from the chain as markets-service would: the index -/+
  // markIndexBand(expiry). The enable gate's `fills` check compares that with its own read of the chain.
  let listed = false;
  const marketsServer = createServer(async (req, res) => {
    if (!req.url?.startsWith('/v1/markets')) return void res.writeHead(404).end();
    const markets = [];
    if (listed) {
      const index = invert(spot);
      const band = await read<bigint>(FUTURE, abi.future, 'markIndexBand', [EXPIRY]);
      markets.push({
        asset_address: FUTURE.toLowerCase(),
        sub_id: SUB_ID.toString(),
        fill_band_enforced: true,
        fill_band_low: formatUnits(index - (index * band) / ONE, 18),
        fill_band_high: formatUnits(index + (index * band) / ONE, 18),
      });
    }
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ markets }));
  }).listen(MARKETS_PORT);
  servers.push(marketsServer);
  async function proposer(batch: 'setup' | 'enable' | 'pool-withdraw', extra: string[] = []): Promise<Proposal> {
    const out = await new Promise<string>((resolve) => {
      const child = spawn('python3', ['scripts/ops/propose_margin_engine_batch.py', batch, '--local', '--dir', LOCAL, '--json', ...extra], {
        cwd: RISK_CORE,
        env: {
          PATH: process.env.PATH,
          HOME: OUT,
          RPC_URL: RPC,
          PAGER_STATE_FILE: join(OUT, 'proposer-pager-state.json'),
          MARKETS_URL: `http://127.0.0.1:${MARKETS_PORT}`,
          ENGINE_KEEPER_HEALTH_URL: `http://127.0.0.1:${KEEPER_PORT}/health`,
        },
      });
      let text = '';
      child.stdout.on('data', (chunk) => (text += chunk));
      child.stderr.on('data', (chunk) => (text += chunk));
      child.on('exit', () => resolve(text));
    });
    writeFileSync(join(OUT, `proposer-${batch}.log`), out);
    const last = out.trim().split('\n').filter((line) => line.startsWith('{')).at(-1);
    assert.ok(last, `propose_margin_engine_batch.py ${batch} printed no report:\n${out.slice(-600)}`);
    return JSON.parse(last) as Proposal;
  }
  const failing = (p: Proposal) => p.gates.filter((g) => !g.ok).map((g) => g.name);
  type Action = { description: string; to: Address; data: Hex; digest: Hex };
  // `skip`: actions the proposer defers (propose_margin_engine_batch DEFERRED), which the vault never runs at this step
  async function runBatch(name: string, skip: number[] = []) {
    const actions = (JSON.parse(readFileSync(join(LOCAL, `${name}.json`), 'utf8')) as Action[]).filter((_, i) => !skip.includes(i));
    for (const action of actions) {
      assert.equal(action.digest, keccak256(encodePacked(['address', 'bytes32'], [action.to, keccak256(action.data)])), `digest of ${action.description}`);
      const hash = await vault.sendTransaction({ to: action.to, data: action.data, chain, account: VAULT });
      assert.equal((await pub.waitForTransactionReceipt({ hash })).status, 'success', `vault action failed: ${action.description}`);
    }
    log(`vault ran ${name}: ${actions.length} actions`);
  }

  const setupBefore = await proposer('setup');
  assert.deepEqual(failing(setupBefore), [], 'setup gates pass on a fresh deploy');
  assert.ok(setupBefore.landed.every((l) => !l), 'nothing of the setup batch has landed yet');
  assert.equal((artifact.deployer as string).toLowerCase(), addr(KEYS.deployer).toLowerCase(), 'the artifact records the deployer');
  const gate = (p: Proposal, name: string) => p.gates.find((g) => g.name === name);

  // The deployer owns everything until the vault accepts. Break it: in that window, the deployer loosens the
  // futures margin. The vault's batch still lands (it re-sets nothing of the kind), and the proposer's parity check,
  // run once the batch has landed, must name the change.
  const beforeWindow = await test.snapshot();
  const MARKET = BigInt(artifact.marketId);
  await send(as(KEYS.deployer), MANAGER, abi.manager, 'setFutureMarginRequirements', [MARKET, BigInt(artifact.futureMMReq) / 2n, BigInt(artifact.futureIMReq)]);
  await runBatch('MARGIN_ENGINE_VAULT_ACTIONS');
  const tampered = await proposer('setup');
  assert.ok(tampered.landed.every(Boolean), 'the setup batch lands despite the change');
  const tamperedParity = gate(tampered, 'parity');
  assert.ok(tamperedParity && !tamperedParity.ok, `parity goes red on a change in the deployer's window: ${JSON.stringify(tamperedParity)}`);
  assert.match(tamperedParity.detail, /futureMarginRequirements mm/, 'and names the setting');
  log(`parity broken by the deployer, as it should be: ${tamperedParity.detail}`);
  await test.revert({ id: beforeWindow });

  await runBatch('MARGIN_ENGINE_VAULT_ACTIONS');
  const setupAfter = await proposer('setup');
  assert.ok(setupAfter.landed.every(Boolean), 'the proposer sees every setup action landed');
  const parity = gate(setupAfter, 'parity');
  assert.ok(parity?.ok, `parity holds once the vault owns everything: ${JSON.stringify(parity)}`);
  log(`parity: ${parity.detail}`);

  // ---- accounts and positions ----------------------------------------------------------------
  const dealt = async (token: Address, to: Address, amount: bigint) => {
    const at = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [to, BALANCE_SLOT[token]]));
    await test.setStorageAt({ address: token, index: at, value: toHex(amount, { size: 32 }) });
    assert.equal(await read<bigint>(token, abi.erc20, 'balanceOf', [to]), amount, `dealt ${token}`);
  };
  async function account(user: Address): Promise<bigint> {
    await send(operator, SUBACCOUNTS, abi.subAccounts, 'createAccountWithApproval', [user, addr(KEYS.operator), MANAGER]);
    return read<bigint>(SUBACCOUNTS, abi.subAccounts, 'lastAccountId');
  }
  async function depositTo(user: Address, acc: bigint, token: Address, wrapper: Address, amount: bigint) {
    await dealt(token, user, amount);
    const wallet = await impersonated(user);
    await send(wallet, token, abi.erc20, 'approve', [wrapper, amount]);
    await send(wallet, wrapper, abi.deposit, 'deposit', [acc, amount]);
  }
  const bal = (acc: bigint, asset: Address, subId = 0n) => read<bigint>(SUBACCOUNTS, abi.subAccounts, 'getBalance', [acc, asset, subId]);
  const cngnOf = (acc: bigint) => bal(acc, ESCROW);
  const position = (acc: bigint) => bal(acc, FUTURE, SUB_ID);
  const contractOf = () => read<Contract>(FUTURE, abi.future, 'futureContracts', [SUB_ID]);

  // The enable batch, gated. Before the pager runs and the future is listed the proposer must refuse; after,
  // everything must pass. There is no reserve at launch (FUTURE_RESERVE_MOVE 0), so an empty pool passes.
  // numo-engine-keeper as the gate sees it: a funding account owned by the keeper EOA under the engine, holding a
  // full futures side's IM in cash (3,750 at the launch cap), and its /health, stubbed (the keeper itself runs against
  // the engine in perp-keeper's engine-keeper.anvil.test.ts). In DRY_RUN until the listing ships, so the gate must fire.
  const KEEPER_EOA = '0x00000000000000000000000000000000e4e1e401' as Address;
  await test.setBalance({ address: KEEPER_EOA, value: 10n ** 16n });
  await send(await impersonated(KEEPER_EOA), SUBACCOUNTS, abi.subAccounts, 'createAccount', [KEEPER_EOA, MANAGER]);
  const keeperAccount = await read<bigint>(SUBACCOUNTS, abi.subAccounts, 'lastAccountId');
  await depositTo(KEEPER_EOA, keeperAccount, USDC, CASH, 3_750n * 10n ** 6n);
  let keeperDryRun = true;
  const keeperServer = createServer((_req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({
      lastPassAt: Math.floor(Date.now() / 1000), lastPassOk: true, dryRun: keeperDryRun, pollIntervalMs: 15_000,
      manager: MANAGER, keeperAccount: keeperAccount.toString(), keeperAddress: KEEPER_EOA,
    }));
  }).listen(KEEPER_PORT);
  servers.push(keeperServer);
  const refused = failing(await proposer('enable'));
  // The launch cap is sized to the live SecurityModule, so sm passes without a top-up.
  // RFQ is not supported. The RfqModule was retired on Base at block 52523521, so at head the rfq gate already passes;
  // it is proved to fire below by re-allowing the module on the fork.
  assert.deepEqual(refused.sort(), ['fills', 'keeper', 'pager'], `before the pager, the keeper and the listing, exactly these gates fail: ${refused}`);
  log(`enable refused before the pager, the keeper and the listing: ${refused.join(', ')} gates fail; custody, feeds, marks, reserve (none), escrow, sm and rfq pass`);
  // The treasury seeds the pool anyway, so the rehearsal still covers winners paid in cNGN: 30% of one side
  // at the cap (the earlier reserve), in cNGN at the index, plus 1% for the index moving meanwhile
  const reserve = ((BigInt(artifact.futureOICap) / 2n) * BigInt(artifact.contractSize) * 3n) / (10n * spot);
  await depositTo(USERS.treasury, POOL, CNGN, ESCROW, (reserve * 101n) / 100n / 10n ** 12n);
  // the pager gate reads its state file; a provider and dead-man's switch cannot be rehearsed here
  writeFileSync(join(OUT, 'proposer-pager-state.json'), JSON.stringify({ lastRunAt: Math.floor(Date.now() / 1000), lastRunOk: true, provider: 'pushover', heartbeatConfigured: true }));
  // the futures listing ships, with its fill-band check: markets-service now lists the future and its band
  listed = true;
  // and the engine keeper leaves DRY_RUN
  keeperDryRun = false;
  // the rfq gate keeps the RfqModule off: re-allowed on the fork, enable is refused on rfq alone
  const setRfq = (allowed: boolean) => ({
    to: '0x9E90A9cD13d859Bd6a08168082FB1F6F7405F191' as Address,
    data: encodeFunctionData({
      abi: parseAbi(['function setAllowedModule(address module, bool allowed)']),
      functionName: 'setAllowedModule',
      args: ['0x8399328AC53a279A3564E49c2cbC82Ce95ee62D3', allowed],
    }),
  });
  const reAllow = await vault.sendTransaction({ ...setRfq(true), chain, account: VAULT });
  assert.equal((await pub.waitForTransactionReceipt({ hash: reAllow })).status, 'success', 'the vault re-allows the RfqModule on the fork');
  const rfqBack = failing(await proposer('enable'));
  assert.deepEqual(rfqBack, ['rfq'], `with the RfqModule allowed again, only the rfq gate fails: ${rfqBack}`);
  log('enable refused with the RfqModule re-allowed: the rfq gate fires');
  // the vault retires it again: the action propose_retire_rfq_module.py proposed, checked against its pinned digest
  const rfqRetire = setRfq(false);
  assert.equal(keccak256(encodePacked(['address', 'bytes32'], [rfqRetire.to, keccak256(rfqRetire.data)])),
    '0x41d668ad1ec34b68c812e2d46101483340793cc7bdcb4148b9b63bb5c5ed4d0f', 'the RFQ retirement is the action #182 proposed');
  const rfqHash = await vault.sendTransaction({ to: rfqRetire.to, data: rfqRetire.data, chain, account: VAULT });
  assert.equal((await pub.waitForTransactionReceipt({ hash: rfqHash })).status, 'success', 'the vault retires the RfqModule');
  const allowed = await proposer('enable');
  assert.deepEqual(failing(allowed), [], `after seeding, every enable gate passes: ${JSON.stringify(allowed.gates.filter((g) => !g.ok))}`);
  log(`enable gates pass: pool seeded with ${fmt(reserve * 101n / 100n)} cNGN, the SecurityModule as it is on Base`);
  // The perp's cap under the engine (action 0) is deferred to the perp's own cutover: the vault runs the future's cap
  // and its registration, and the perp stays closed under the engine.
  const enableActions = JSON.parse(readFileSync(join(LOCAL, 'MARGIN_ENGINE_ENABLE_VAULT_ACTIONS.json'), 'utf8')) as Action[];
  assert.ok(enableActions[0].to.toLowerCase() === (stack.perp as string).toLowerCase(), 'action 0 is the perp\'s cap');
  await runBatch('MARGIN_ENGINE_ENABLE_VAULT_ACTIONS', [0]);
  const opened = (await proposer('enable')).landed;
  assert.ok(!opened[0] && opened[1] && opened[2], `the future is open and the perp's cap is not: ${opened}`);
  const capAbi = parseAbi(['function totalPositionCap(address manager) view returns (uint256)']);
  assert.equal(await read<bigint>(stack.perp as Address, capAbi, 'totalPositionCap', [MANAGER]), 0n, 'the perp\'s cap under the engine still reads 0');
  log('enable batch ran without the deferred perp cap: the future is open, the perp\'s cap under the engine is 0');
  const alice = await account(USERS.alice);
  const bob = await account(USERS.bob);
  const carol = await account(USERS.carol);
  await depositTo(USERS.alice, alice, USDC, CASH, 3_000n * 10n ** 6n);
  await depositTo(USERS.alice, alice, CNGN, ESCROW, 1_000_000n * 10n ** 6n);
  await depositTo(USERS.bob, bob, USDC, CASH, 1_000n * 10n ** 6n);
  await depositTo(USERS.bob, bob, CNGN, ESCROW, 1_000_000n * 10n ** 6n);
  await depositTo(USERS.carol, carol, USDC, CASH, 300n * 10n ** 6n); // no cNGN: what she owes is paid in USDC
  const mark0 = (await contractOf()).markPrice;
  const trade = (seller: bigint, buyer: bigint, amount: bigint) =>
    send(operator, SUBACCOUNTS, abi.subAccounts, 'submitTransfer', [
      { fromAcc: seller, toAcc: buyer, asset: FUTURE, subId: SUB_ID, amount, assetData: toHex(mark0, { size: 32 }) },
      '0x',
    ]);
  // Carol is on the same side as Alice and holds no cNGN: whichever side loses, one loser pays in cNGN
  // and one in USDC, and the winner is paid in cNGN either way (the pool fronts what Carol pays in USDC).
  await trade(bob, alice, 2n * ONE);
  await trade(bob, carol, ONE);
  // the point of the engine: the perp in the same accounts as spot cNGN and the future. Not at launch: this is the
  // perp's own cutover, the deferred action 0, run here so the rehearsal still covers one account holding all three.
  const cutover = await vault.sendTransaction({ to: enableActions[0].to, data: enableActions[0].data, chain, account: VAULT });
  assert.equal((await pub.waitForTransactionReceipt({ hash: cutover })).status, 'success', 'the perp cutover: its cap under the engine');
  assert.ok((await proposer('enable')).landed.every(Boolean), 'after the perp cutover, every enable action has landed');
  const PERP = stack.perp as Address;
  await send(operator, SUBACCOUNTS, abi.subAccounts, 'submitTransfer', [
    { fromAcc: bob, toAcc: alice, asset: PERP, subId: 0n, amount: 1_000_000n * ONE, assetData: toHex(0n, { size: 32 }) },
    '0x',
  ]);
  assert.ok((await bal(alice, ESCROW)) > 0n && (await bal(alice, PERP)) > 0n && (await position(alice)) > 0n,
    'alice holds spot cNGN, the perp and the future in one account');
  log(`alice ${alice}: ${fmt(await cngnOf(alice))} spot cNGN, ${fmt(await bal(alice, PERP))} cNGN of perp, ${fmt(await position(alice))} futures, `
    + `one margin: MM ${fmt(await read<bigint>(MANAGER, abi.manager, 'getMargin', [alice, false]))} USDC`);
  const all = [alice, bob, carol];
  const cngnStart = new Map<bigint, bigint>();
  for (const acc of [...all, POOL]) cngnStart.set(acc, await cngnOf(acc));
  const usdcStartCarol = await bal(carol, CASH);
  log(`accounts alice ${alice} (long 2), bob ${bob} (short 3), carol ${carol} (long 1, USDC only), pool ${POOL} (the reserve); entry ${fmt(mark0)}`);

  // ---- stub book and webhook -----------------------------------------------------------------
  let book: { bids: Order[]; asks: Order[] } | null = null;
  const bookServer = createServer((req, res) => {
    if (!book || !req.url?.startsWith('/v1/book')) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify(book));
  }).listen(BOOK_PORT);
  const alerts: { text: string }[] = [];
  const pages: string[] = []; // what the pager sent to the phone (its Pushover endpoint, stubbed)
  const hookServer = createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => (body += chunk));
    req.on('end', () => {
      // recorded before anything is awaited, so a check right after the sender exits sees it
      if (req.url?.startsWith('/pushover')) {
        pages.push(new URLSearchParams(body).get('message') ?? '');
        res.writeHead(200, { 'content-type': 'application/json' }).end('{"status":1}');
        return;
      }
      if (req.url?.startsWith('/heartbeat')) return void res.writeHead(200).end();
      alerts.push({ text: JSON.parse(body).text });
      res.writeHead(200).end();
    });
  }).listen(HOOK_PORT);
  servers.push(bookServer, hookServer);
  const level = (price: bigint, contracts: string, side: 'buy' | 'sell'): Order => ({
    side,
    limit_price: formatUnits(price, 18),
    desired_amount: contracts,
    filled_amount: '0',
  });

  // ---- the keeper, as its own process --------------------------------------------------------
  const keeperLog = createWriteStream(join(OUT, 'keeper.log'));
  const keeperLines: string[] = [];
  let keeper: ChildProcess | null = null;
  function startKeeper() {
    keeper = spawn('node', [join(SERVICE, 'dist/forward-main.js')], {
      cwd: OUT, // no stray .env
      env: {
        PATH: process.env.PATH,
        RPC_URL: RPC,
        CHAIN_ID: '31337',
        RELAYER_KEY: KEYS.relayer,
        FORWARD_SIGNER_KEY: KEYS.forward,
        ALERT_WEBHOOK_URL: `http://127.0.0.1:${HOOK_PORT}/hook`,
        DATA_SUBMITTER: SUBMITTER,
        INDEX_FEED: INDEX,
        FORWARD_FEED: FORWARD_FEED,
        FUTURE_ASSET: FUTURE,
        FUTURE_SUB_ID: SUB_ID.toString(),
        CARRY: CARRY.toString(),
        MARKETS_SERVICE_URL: `http://127.0.0.1:${BOOK_PORT}`,
        FORWARD_TICK_MS: '1500',
        CLOSE_OUT_BATCH: '2',
      },
    });
    const capture = (chunk: Buffer) => {
      keeperLog.write(chunk);
      keeperLines.push(...chunk.toString().split('\n').filter(Boolean));
    };
    keeper.stdout!.on('data', capture);
    keeper.stderr!.on('data', capture);
    children.push(keeper);
  }
  async function stopKeeper() {
    const k = keeper!;
    k.kill('SIGTERM');
    await new Promise((resolve) => (k.exitCode !== null ? resolve(null) : k.once('exit', resolve)));
    keeper = null;
  }
  async function waitFor<T>(what: string, poll: () => Promise<T | undefined | false>, timeoutMs = 90_000): Promise<T> {
    const start = Date.now();
    for (;;) {
      const value = await poll();
      if (value) return value;
      if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${what}; keeper tail:\n${keeperLines.slice(-15).join('\n')}`);
      await sleep(400);
    }
  }
  /** Moves the clock, then waits for the keeper's next mark. The last mark time is read before the
   *  clock moves: read after, a keeper that marks first leaves nothing to wait for. */
  async function advanceToMark(seconds: bigint, label: string, expected: () => Promise<bigint>, tolerance: number, price = spot) {
    const before = (await contractOf()).lastMarkTime;
    await advance(seconds, price);
    return nextMark(label, await expected(), tolerance, before);
  }
  async function nextMark(label: string, expected: bigint, tolerance: number, before: bigint) {
    const c = await waitFor(`a mark (${label})`, async () => {
      const now = await contractOf();
      return now.lastMarkTime > before ? now : undefined;
    });
    const off = relDiff(c.markPrice, expected);
    log(`mark ${label}: ${fmt(c.markPrice)}, expected ${fmt(expected)} (off ${(off * 100).toFixed(4)}%), band ${fmt(await read<bigint>(FUTURE, abi.future, 'markIndexBand', [EXPIRY]) * 100n)}%`);
    assert.ok(off <= tolerance, `${label}: mark ${c.markPrice} is ${off} from ${expected}`);
    return c;
  }

  startKeeper();
  await waitFor('the keeper to start', async () => keeperLines.some((line) => line.includes('[forward] signer')));
  log(keeperLines.find((line) => line.includes('[forward] signer'))!);

  // ---- marks -----------------------------------------------------------------------------------
  const carryNow = async () => carryForward(invert(spot), CARRY, EXPIRY - (await head()));

  await advanceToMark(3_601n, '1h, no book -> carry', carryNow, 0.0005);

  const fwd = await carryNow();
  book = {
    bids: [level(fwd * 1008n / 1000n, '3', 'buy')],
    asks: [level(fwd * 1012n / 1000n, '3', 'sell')],
  };
  await advanceToMark(3_601n, '2h, 3,000 USDC each side at +0.8%/+1.2% -> book mid', async () => (await carryNow()) * 101n / 100n, 0.001);

  book = {
    bids: [level(fwd * 1030n / 1000n, '0.5', 'buy')],
    asks: [level(fwd * 1031n / 1000n, '0.5', 'sell')],
  };
  const afterMarks = await advanceToMark(3_601n, '3h, 500 USDC dust at +3% -> ignored, carry', carryNow, 0.0005);
  book = null;

  // Nobody settles by hand: the keeper's sweep after each mark must have realised every account's VM.
  await waitFor('the sweep to realise every account', async () => {
    for (const a of all) if ((await read<bigint>(FUTURE, abi.future, 'getPendingVM', [a, SUB_ID])) !== 0n) return undefined;
    return true;
  });
  log(`sweep: ${keeperLines.filter((line) => line.startsWith('[sweep] settled account')).length} settlements after 3 marks, no VM left pending`);
  const aliceVm = (await cngnOf(alice)) - cngnStart.get(alice)!;
  assert.equal(aliceVm, 2n * 1_000n * (afterMarks.markPrice - mark0), 'alice: 2 contracts of VM, in cNGN');
  assert.equal((await cngnOf(bob)) - cngnStart.get(bob)!, -3n * 1_000n * (afterMarks.markPrice - mark0), 'bob: 3, in cNGN');
  log(`VM after 3 marks settled: alice ${fmt(aliceVm)} cNGN, bob ${fmt((await cngnOf(bob)) - cngnStart.get(bob)!)} cNGN, carol ${fmt((await bal(carol, CASH)) - usdcStartCarol, 18)} USDC cash`);

  // The pager, against the fork with the future open: it must read the deployed future's book and pool.
  // A fresh state file: a kept one holds back a warning an earlier run already sent (its 6h repeat).
  rmSync(join(OUT, 'pager-state.json'), { force: true });
  // Async, not spawnSync: the pager posts its Slack warning to the stub webhook, which is served from
  // this process and cannot answer while a synchronous child blocks the event loop.
  const runPager = (extra: Record<string, string> = {}) =>
    new Promise<{ stdout: string; stderr: string }>((resolve) => {
      const child = spawn('python3', ['scripts/ops/check_perp_pager.py'], {
        cwd: RISK_CORE,
        env: {
          PATH: process.env.PATH,
          HOME: OUT,
          RPC_URL: RPC,
          FUTURE_ARTIFACT: join(LOCAL, 'MARGIN_ENGINE.json'),
          FUTURE_POOL_RESERVE_CNGN: '20000000',
          PAGER_STATE_FILE: join(OUT, 'pager-state.json'),
          MATCHER_HEALTH_URL: `http://127.0.0.1:${BOOK_PORT}/v1/health`,
          ALERT_WEBHOOK_URL: `http://127.0.0.1:${HOOK_PORT}/hook`,
          ...extra,
        },
      });
      let stdout = '';
      let stderr = '';
      child.stdout.on('data', (chunk) => (stdout += chunk));
      child.stderr.on('data', (chunk) => (stderr += chunk));
      child.on('exit', () => resolve({ stdout, stderr }));
    });
  const pager = await runPager();
  writeFileSync(join(OUT, 'pager.log'), `${pager.stdout}\n${pager.stderr}`);
  const futureLine = pager.stdout.split('\n').find((line) => line.startsWith('future:'));
  const coverageLine = pager.stdout.split('\n').find((line) => line.startsWith('sm coverage:'));
  log(`pager ${futureLine}`);
  log(`pager ${coverageLine}`);
  assert.match(futureLine ?? '', /^future: one side \$3,000 at IM 25%, open; pool [\d,]+ cNGN \(reserve 20,000,000 set\)/, 'pager reads the future');
  assert.match(coverageLine ?? '', /future \$3,000/, 'pager counts the future in SecurityModule coverage');
  assert.match(futureLine ?? '', /; escrow [\d,]+ of 100,000,000 cNGN$/, 'pager reads the escrow cap the deploy set');
  // ~8.3M of a 20M reserve is ~41%: under half, over a quarter, so a Slack warning and no page
  assert.ok(alerts.some((a) => a.text.includes('cNGN future VM pool at')), 'pool reserve warning reached the webhook');

  // ---- weeks later: the band narrows, cNGN weakens 2% ----------------------------------------
  await advanceToMark(EXPIRY - 10n * 86_400n - (await head()), 'E-10d after a 39-day gap, index +2%', carryNow, 0.0005, spot * 100n / 102n);
  await waitFor('the late-mark alert at the webhook', async () => alerts.some((a) => a.text.includes('last mark')));
  log(`late-mark alert reached the webhook: "${alerts.find((a) => a.text.includes('last mark'))!.text}"`);

  // Stopped straight after a mark, before (or during) its sweep: the restarted keeper must sweep on startup.
  await stopKeeper();
  const pendingAtStop = (await Promise.all(all.map((a) => read<bigint>(FUTURE, abi.future, 'getPendingVM', [a, SUB_ID])))).filter((v) => v !== 0n).length;
  startKeeper();
  await waitFor('the startup sweep', async () => {
    for (const a of all) if ((await read<bigint>(FUTURE, abi.future, 'getPendingVM', [a, SUB_ID])) !== 0n) return undefined;
    return true;
  });
  log(`keeper stopped with ${pendingAtStop} of 3 accounts' VM unrealised; restarted, its startup sweep left none`);
  await advanceToMark(LAST_TRADE - 20n * 60n - (await head()), 'E-1h20m, band at its floor', carryNow, 0.0005);

  // ---- last trade, the fixing window ---------------------------------------------------------
  await advance(LAST_TRADE + 10n - (await head()));
  let stoppedInWindow = false;
  for (let step = 0; (await head()) < EXPIRY; step++) {
    // a ±0.3% wiggle, so the fixing is a real time-weighted average and not one price
    const wiggle = [1000n, 1003n, 1001n, 997n, 999n, 1002n][step % 6];
    const price = (liveSpot * 100n / 102n) * wiggle / 1000n;
    if (step === 8 && !stoppedInWindow) {
      await stopKeeper();
      stoppedInWindow = true;
      log(`keeper stopped inside the fixing window at E-${EXPIRY - (await head())}s`);
    }
    if (step === 11) {
      startKeeper();
      log(`keeper restarted at E-${EXPIRY - (await head())}s`);
    }
    await sleep(2_500);
    await advance(120n, price);
  }
  const fixedContract = await waitFor('the settlement fixing', async () => {
    const c = await contractOf();
    return c.settled ? c : undefined;
  });

  const samples = (
    await pub.getLogs({ address: FUTURE, event: FIXING_SAMPLED, args: { subId: SUB_ID }, fromBlock: forkBlock.number + 1n, toBlock: 'latest' })
  ).map((l) => ({ time: BigInt(l.args.sampleTime!), price: l.args.indexPrice! }));
  let acc = 0n;
  for (let i = 1; i < samples.length; i++) acc += samples[i - 1].price * (samples[i].time - samples[i - 1].time);
  acc += samples.at(-1)!.price * (EXPIRY - samples.at(-1)!.time);
  const twap = acc / (EXPIRY - samples[0].time);
  const gaps = samples.slice(1).map((s, i) => s.time - samples[i].time);
  const largestGap = [samples[0].time - (EXPIRY - 3_600n), ...gaps, EXPIRY - samples.at(-1)!.time].reduce((a, b) => (a > b ? a : b));
  log(`fixing: ${samples.length} samples, largest gap ${largestGap}s (limit 900), settled at ${fmt(fixedContract.markPrice)}; TWAP of the samples ${fmt(twap)}`);
  assert.equal(fixedContract.markPrice, twap, 'settlement is the time-weighted average of the samples');
  assert.ok(largestGap <= 900n, 'the restart did not break the fixing');

  // ---- close-out ------------------------------------------------------------------------------
  await waitFor('close-out of every account', async () => {
    for (const a of all) if ((await position(a)) !== 0n) return undefined;
    return true;
  });
  assert.equal(await read<bigint>(FUTURE, abi.future, 'totalPosition', [MANAGER]), 0n, 'no open interest');
  await waitFor('the keeper to go quiet', async () => keeperLines.some((line) => line.includes('[expiry] closed-out')));
  const closeOuts = keeperLines.filter((line) => line.includes('closed out account')).length;
  log(`closed out ${closeOuts} accounts (batch of 2), positions all zero`);

  const settle = fixedContract.markPrice;
  const aliceTotal = (await cngnOf(alice)) - cngnStart.get(alice)!;
  const bobTotal = (await cngnOf(bob)) - cngnStart.get(bob)!;
  assert.equal(aliceTotal, 2n * 1_000n * (settle - mark0), 'alice: settlement - entry on 2 contracts, in cNGN');
  assert.equal(bobTotal, -3n * 1_000n * (settle - mark0), 'bob: the other side of 3');
  let cngnBefore = 0n;
  let cngnAfter = 0n;
  for (const a of [...all, POOL]) {
    cngnBefore += cngnStart.get(a)!;
    cngnAfter += await cngnOf(a);
  }
  assert.equal(cngnAfter, cngnBefore, 'VM only moves cNGN between the accounts and the pool');
  const carolUsdc = (await bal(carol, CASH)) - usdcStartCarol;
  assert.ok(carolUsdc < 0n, 'carol paid in USDC');
  assert.equal(await cngnOf(carol), 0n, 'carol never held cNGN');
  // the pool fronted Carol's contract in cNGN and holds her USDC for it
  assert.equal(await cngnOf(POOL), cngnStart.get(POOL)! + 1_000n * (settle - mark0), "the pool paid Carol's side in cNGN");
  assert.ok((await bal(POOL, CASH)) > 0n, 'and holds her USDC');
  log(`settled: alice ${fmt(aliceTotal)} cNGN, bob ${fmt(bobTotal)} cNGN, carol ${fmt(carolUsdc)} USDC (incl. interest), pool cNGN ${fmt(await cngnOf(POOL))}, pool USDC ${fmt(await bal(POOL, CASH))}`);
  log(`margins after: alice ${fmt(await read<bigint>(MANAGER, abi.manager, 'getMargin', [alice, false]))}, carol ${fmt(await read<bigint>(MANAGER, abi.manager, 'getMargin', [carol, false]))}`);

  // real tokens out
  const out = (await cngnOf(alice)) / 10n ** 12n;
  await send(await impersonated(USERS.alice), ESCROW, abi.deposit, 'withdraw', [alice, out, USERS.alice]);
  assert.equal(await read<bigint>(CNGN, abi.erc20, 'balanceOf', [USERS.alice]), out);
  log(`alice withdrew ${fmt(out, 6)} real cNGN`);

  // ---- pager drill: the pool drained by settlement, the page fires, then clears ------------------
  // A second series, so nothing above is disturbed. The pool's cNGN is withdrawn (no risk check on it), the market moves
  // twice for the longs, and the winners settle before the loser: the pool pays them in cash it does not have.
  await stopKeeper();
  const poolCngn = await cngnOf(POOL);
  // with no reserve the proposer's gate lets the pool's cNGN go to zero (cash is still held at zero, below)
  const emptying = ['--asset', 'cngn', '--amount', String(poolCngn / 10n ** 12n), '--recipient', USERS.treasury];
  assert.deepEqual(failing(await proposer('pool-withdraw', emptying)), [], 'with no reserve the proposer lets the pool be emptied of cNGN');
  log('pool-withdraw allowed: no reserve, so the pool may be emptied of cNGN (the drill withdraws as the vault directly)');
  await send(vault, MANAGER, abi.manager, 'withdrawFromPool', [ESCROW, poolCngn / 10n ** 12n, USERS.treasury]);
  assert.ok((await cngnOf(POOL)) < 10n ** 12n, 'the pool holds no cNGN');
  const now0 = await head();
  const drillSubId = BigInt(
    (await pub.simulateContract({ address: FUTURE, abi: abi.future, functionName: 'setContract', args: [now0 + 30n * 86_400n, now0 + 30n * 86_400n - 3_600n, invert(spot)], account: VAULT })).result,
  );
  await send(vault, FUTURE, abi.future, 'setContract', [now0 + 30n * 86_400n, now0 + 30n * 86_400n - 3_600n, invert(spot)]);
  const drillTrade = (seller: bigint, buyer: bigint) =>
    send(operator, SUBACCOUNTS, abi.subAccounts, 'submitTransfer', [
      { fromAcc: seller, toAcc: buyer, asset: FUTURE, subId: drillSubId, amount: ONE, assetData: toHex(invert(spot), { size: 32 }) },
      '0x',
    ]);
  await drillTrade(bob, alice);
  await drillTrade(bob, alice);
  await drillTrade(bob, carol);
  // cNGN weakens 10%: the index moves first, then three marks of 4% from the series' own mark, each inside the band and
  // under the 5% move limit (12.5% in all, about $115 a contract)
  await advance(3_601n, (spot * 100n) / 110n);
  for (let i = 0; i < 3; i++) {
    const last = ((await read(FUTURE, abi.future, 'futureContracts', [drillSubId])) as Contract).markPrice;
    await advance(60n);
    await send(vault, FUTURE, abi.future, 'setMark', [drillSubId, await head(), (last * 104n) / 100n]);
  }
  await send(operator, MANAGER, abi.manager, 'settleAccount', [alice]);
  await send(operator, MANAGER, abi.manager, 'settleAccount', [carol]);
  const poolCash = await bal(POOL, CASH);
  log(`pager drill: pool emptied of cNGN, longs paid first: pool cash ${fmt(poolCash)} USDC`);
  assert.ok(poolCash < -250n * ONE, 'the pool is past the -$250 page');
  const pageEnv = {
    PAGER_PROVIDER: 'pushover',
    PUSHOVER_TOKEN: 'drill',
    PUSHOVER_USER: 'drill',
    PUSHOVER_URL: `http://127.0.0.1:${HOOK_PORT}/pushover`,
    PAGER_HEARTBEAT_URL: `http://127.0.0.1:${HOOK_PORT}/heartbeat`,
  };
  const drilled = await runPager(pageEnv);
  writeFileSync(join(OUT, 'pager-drill.log'), `${drilled.stdout}\n${drilled.stderr}`);
  const borrowingPage = pages.find((p) => p.includes('below zero in USDC cash'));
  assert.ok(borrowingPage, `the future-pool-borrowing page reached the phone; pages: ${JSON.stringify(pages)}`);
  log(`pager paged: "${borrowingPage}"`);
  // The deficit outlasts a mark and its sweep: the pager's own timer says so after 75 min. Backdate where it
  // started rather than wait; the next run must page at any size.
  const pagerState = JSON.parse(readFileSync(join(OUT, 'pager-state.json'), 'utf8'));
  assert.ok(pagerState.futurePoolNegativeSince, 'the pager started its deficit timer on the negative read');
  pagerState.futurePoolNegativeSince -= 76 * 60;
  writeFileSync(join(OUT, 'pager-state.json'), JSON.stringify(pagerState));
  await runPager(pageEnv);
  const stuckPage = pages.find((p) => p.includes('past a mark and its sweep'));
  assert.ok(stuckPage, `the future-pool-deficit-stuck page reached the phone; pages: ${JSON.stringify(pages)}`);
  log(`pager paged: "${stuckPage}"`);
  // bob pays in (in cNGN, which he holds), and the treasury tops the pool's cash back up: the page resolves
  await send(operator, MANAGER, abi.manager, 'settleAccount', [bob]);
  // with 10 USDC to spare: interest accrues on the negative balance between reading it and the deposit landing
  await depositTo(USERS.treasury, POOL, USDC, CASH, (-(await bal(POOL, CASH)) / 10n ** 12n) + 10_000_000n);
  await runPager(pageEnv);
  assert.ok(pages.some((p) => p.includes('future-pool-borrowing cleared')), 'and the resolved notice followed');
  assert.ok(pages.some((p) => p.includes('future-pool-deficit-stuck cleared')), 'and the stuck deficit resolved with it');
  assert.ok(!JSON.parse(readFileSync(join(OUT, 'pager-state.json'), 'utf8')).futurePoolNegativeSince, 'and its timer stopped');
  // cash out of the pool: never below zero
  const poolCashNow = (await bal(POOL, CASH)) / 10n ** 12n;
  const cashOut = (amount: bigint) => ['--asset', 'cash', '--amount', String(amount), '--recipient', USERS.treasury];
  assert.deepEqual(failing(await proposer('pool-withdraw', cashOut(poolCashNow + 1n))), ['withdraw'], 'not past zero cash');
  assert.deepEqual(failing(await proposer('pool-withdraw', cashOut(poolCashNow))), [], 'down to zero is fine');
  log(`pool-withdraw gate: ${fmt(poolCashNow, 6)} USDC may leave the pool, one more unit may not`);
  log('pager resolved the page once the pool was topped up');

  // ---- alerts ---------------------------------------------------------------------------------
  const keys = keeperLines.filter((line) => line.startsWith('[alert]')).map((line) => line.split(':')[0].replace('[alert] ', ''));
  const counts = Object.entries(keys.reduce<Record<string, number>>((m, k) => ((m[k] = (m[k] ?? 0) + 1), m), {}));
  log(`alerts raised: ${counts.map(([k, n]) => `${k} x${n}`).join(', ') || 'none'}; ${alerts.length} reached the webhook`);
  const unexpected = counts.filter(([k]) => k !== 'forward-mark-late');
  log(unexpected.length ? `UNEXPECTED ALERTS: ${unexpected.map(([k]) => k).join(', ')}` : 'no unexpected alerts');
  log(`logs in ${OUT}`);
  log('PASS');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(`[rehearsal] FAIL: ${error instanceof Error ? error.stack : error}`);
    process.exit(1);
  });
