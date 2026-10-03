/**
 * The keeper against the real perp stack on an anvil fork of Base: deployed by risk-core's deploy
 * script (test/e2e/DeployPerpStackForE2E.s.sol), accepted by the vault, traded on, crashed, and then
 * liquidated by `runOnce` — the same function the service loops on.
 *
 *   anvil --fork-url $BASE_RPC_URL --chain-id 31337 --port 8600 &
 *   (cd ../../contracts/risk-core && FEED_SIGNER=0x413EC43faa999e8BAd0A1Bd71E3D09B056de2913 \
 *     forge script test/e2e/DeployPerpStackForE2E.s.sol --sig "runE2E()" --rpc-url http://127.0.0.1:8600 \
 *     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 --broadcast)
 *   KEEPER_E2E_RPC_URL=http://127.0.0.1:8600 pnpm test
 *
 * The feed signer above is keccak256("numo.perp-keeper.e2e.feed-signer"). Skipped without the env.
 */
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { before, describe, it } from 'node:test';
import { createPublicClient, createWalletClient, defineChain, encodeAbiParameters, http, keccak256, pad, parseAbi, toHex, } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createKeeperChain, withGasHeadroom } from './chain.js';
import { loadConfig } from './config.js';
import { runOnce } from './keeper.js';
const RPC = process.env.KEEPER_E2E_RPC_URL;
const STACK_FILE = join(import.meta.dirname, '../../../contracts/risk-core/cache/e2e-perp-stack.json');
const USDC = '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913';
const SUB_ACCOUNTS = '0x7019244E25FA416e6Ca2ed2F3cA25277aef72843';
const DATA_SUBMITTER = '0xe0C06DD245f1e8C8bC516c66C66e64648987F912';
const VAULT = '0x1dcA42ab54Bd3862853A821F84B29BF65245F435';
const USDC_BALANCE_SLOT = 9n; // FiatToken v2.2 balanceAndBlacklistStates; checked on the fork
// Derived, not anvil's defaults: those well-known addresses carry EIP-7702 delegations on Base, so on
// a fork they are not plain EOAs. Gas comes from anvil_setBalance.
const key = (label) => keccak256(toHex(`numo.perp-keeper.e2e.${label}`));
const KEYS = {
    relayer: key('relayer'),
    alice: key('alice'),
    carol: key('carol'),
    bob: key('bob'),
    keeper: key('keeper'),
    operator: key('operator'),
};
const FEED_SIGNER = privateKeyToAccount(keccak256(toHex('numo.perp-keeper.e2e.feed-signer')));
/**
 * A signed Lyra feed update, as services/perp-feeds signs it (feed-data.ts). Inlined rather than
 * imported so the two services stay separate packages; the perp-feeds anvil suite pins the format.
 */
async function signedUpdate(kind, feed, data, timestamp, deadline) {
    const signature = await FEED_SIGNER.signTypedData({
        domain: { name: kind, version: '1', chainId: 31337, verifyingContract: feed },
        types: { FeedData: [{ name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' }] },
        primaryType: 'FeedData',
        message: { data, deadline, timestamp },
    });
    const encoded = encodeAbiParameters([{ type: 'tuple', components: [
                { name: 'data', type: 'bytes' }, { name: 'deadline', type: 'uint256' }, { name: 'timestamp', type: 'uint64' },
                { name: 'signers', type: 'address[]' }, { name: 'signatures', type: 'bytes[]' },
            ] }], [{ data, deadline, timestamp, signers: [FEED_SIGNER.address], signatures: [signature] }]);
    return { receiver: feed, data: encoded };
}
const E18 = 10n ** 18n;
const INDEX = 720000000000000n; // 0.00072 USDC per cNGN
const CRASHED = 432000000000000n; // -40%
const SIZE = 10000000n * E18;
const abi = parseAbi([
    'function acceptOwnership()',
    'function disable()',
    'function setTotalPositionCap(address manager, uint256 cap)',
    'function createAccount(address owner, address manager) returns (uint256)',
    'function createAccountWithApproval(address owner, address spender, address manager) returns (uint256)',
    'function lastAccountId() view returns (uint256)',
    'function approve(address spender, uint256 amount) returns (bool)',
    'function deposit(uint256 recipientAccount, uint256 stableAmount)',
    'function donate(uint256 stableAmount)',
    'function submitTransfers((uint256 fromAcc, uint256 toAcc, address asset, uint256 subId, int256 amount, bytes32 assetData)[] transfers, bytes managerData) returns (uint256)',
    'function submitData(bytes managerData)',
    'function getBalance(uint256 accountId, address asset, uint256 subId) view returns (int256)',
    'function getAuction(uint256 accountId) view returns ((uint256 accountId, uint256 scenarioId, bool insolvent, bool ongoing, uint256 cachedMM, uint256 startTime, uint256 reservedCash))',
]);
describe('keeper against the real perp stack on an anvil fork', { skip: !RPC }, () => {
    const chain = defineChain({
        id: 31337,
        name: 'anvil-fork',
        nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
        rpcUrls: { default: { http: [RPC ?? ''] } },
    });
    const client = createPublicClient({ chain, transport: http(RPC) });
    const stack = (RPC ? JSON.parse(readFileSync(STACK_FILE, 'utf8')) : {});
    const accounts = {};
    function walletOf(account) {
        return createWalletClient({ account, chain, transport: http(RPC) });
    }
    async function write(from, address, functionName, args) {
        // Simulated first, so a revert surfaces with its reason instead of a bare failed receipt.
        await client.simulateContract({ address, abi, functionName: functionName, args: args, account: from });
        // Sent with the keeper's headroom: an exact estimate from the block that last touched the perp
        // cash skips its interest accrual and runs out of gas a block later (the CI flake of 2026-09-29).
        const estimate = await client.estimateContractGas({ address, abi, functionName: functionName, args: args, account: from });
        const hash = await walletOf(from).writeContract({
            address,
            abi,
            functionName: functionName,
            args: args,
            chain,
            account: from,
            gas: withGasHeadroom(estimate),
        });
        const receipt = await client.waitForTransactionReceipt({ hash });
        if (receipt.status !== 'success') {
            // A call that simulated fine and then reverted: say whether it ran out of gas and whether the
            // same call succeeds against the same pre-state with unlimited gas.
            const tx = await client.getTransaction({ hash });
            const block = await client.getBlock({ blockNumber: receipt.blockNumber });
            const replay = await client
                .call({ account: tx.from, to: tx.to, data: tx.input, blockNumber: receipt.blockNumber - 1n })
                .then(() => 'succeeds with unlimited gas')
                .catch((error) => `reverts: ${error.message.split('\n')[0]}`);
            assert.fail(`${functionName} reverted: gasUsed ${receipt.gasUsed} of limit ${tx.gas} at block ${receipt.blockNumber} ` +
                `(timestamp ${block.timestamp}); replay at the previous block ${replay}`);
        }
    }
    async function rpc(method, params) {
        return client.request({ method: method, params: params });
    }
    async function giveUsdc(to, amount) {
        const slot = keccak256(encodeAbiParameters([{ type: 'address' }, { type: 'uint256' }], [to, USDC_BALANCE_SLOT]));
        await rpc('anvil_setStorageAt', [USDC, slot, pad(toHex(amount), { size: 32 })]);
    }
    async function newAccount(owner, approvedTo) {
        if (approvedTo)
            await write(owner, SUB_ACCOUNTS, 'createAccountWithApproval', [owner.address, approvedTo, stack.srm]);
        else
            await write(owner, SUB_ACCOUNTS, 'createAccount', [owner.address, stack.srm]);
        return (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'lastAccountId' }));
    }
    async function depositCash(owner, accountId, usdc) {
        await giveUsdc(owner.address, usdc);
        await write(owner, USDC, 'approve', [stack.cash, usdc]);
        await write(owner, stack.cash, 'deposit', [accountId, usdc]);
    }
    /** Index, mark and both impacts at `index`, signed as the publishers sign them. */
    async function publish(index) {
        const block = await client.getBlock();
        const timestamp = block.timestamp - 1n;
        const deadline = block.timestamp + 600n;
        const spot = (price) => encodeAbiParameters([{ type: 'uint96' }, { type: 'uint64' }], [price, E18]);
        const diff = encodeAbiParameters([{ type: 'int96' }, { type: 'uint64' }], [0n, E18]);
        const updates = await Promise.all([
            signedUpdate('LyraSpotFeed', stack.indexFeed, spot(index), timestamp, deadline),
            signedUpdate('LyraSpotDiffFeed', stack.markFeed, diff, timestamp, deadline),
            signedUpdate('LyraSpotDiffFeed', stack.impactAskFeed, diff, timestamp, deadline),
            signedUpdate('LyraSpotDiffFeed', stack.impactBidFeed, diff, timestamp, deadline),
        ]);
        const managerData = encodeAbiParameters([{ type: 'tuple[]', components: [{ name: 'receiver', type: 'address' }, { name: 'data', type: 'bytes' }] }], [updates]);
        await write(privateKeyToAccount(KEYS.relayer), DATA_SUBMITTER, 'submitData', [managerData]);
    }
    async function warp(seconds) {
        await rpc('evm_increaseTime', [seconds]);
        await rpc('evm_mine', []);
    }
    function keeperConfig(dryRun) {
        return loadConfig({
            RPC_URL: RPC,
            CHAIN_ID: '31337',
            KEEPER_KEY: KEYS.keeper,
            KEEPER_ACCOUNT: accounts.keeper.toString(),
            DRY_RUN: dryRun ? 'true' : 'false',
            SUB_ACCOUNTS,
            SRM: stack.srm,
            AUCTION: stack.auction,
            CASH: stack.cash,
            PERP: stack.perp,
            SECURITY_MODULE_ACCOUNT: String(stack.securityModuleAccount),
            START_BLOCK: String(stack.blockNumber),
        });
    }
    const perpOf = async (id) => (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [id, stack.perp, 0n] }));
    const cashOf = async (id) => (await client.readContract({ address: SUB_ACCOUNTS, abi, functionName: 'getBalance', args: [id, stack.cash, 0n] }));
    const auctionOf = async (id) => (await client.readContract({ address: stack.auction, abi, functionName: 'getAuction', args: [id] }));
    const alerts = [];
    const alert = async (key, message) => {
        alerts.push(key);
        console.log(`[alert] ${key}: ${message}`);
    };
    before(async () => {
        // The vault's side of CNGN_PERP_STACK_VAULT_ACTIONS.
        await rpc('anvil_impersonateAccount', [VAULT]);
        for (const address of [VAULT, ...Object.values(KEYS).map((k) => privateKeyToAccount(k).address)]) {
            await rpc('anvil_setBalance', [address, toHex(10n ** 18n)]);
        }
        for (const contract of stack.owned)
            await write(VAULT, contract, 'acceptOwnership', []);
        // The stack deploys closed; the cap half of the enable action opens it.
        await write(VAULT, stack.perp, 'setTotalPositionCap', [stack.srm, 50000000n * E18]);
        await publish(INDEX);
        const operator = privateKeyToAccount(KEYS.operator);
        const alice = privateKeyToAccount(KEYS.alice);
        const bob = privateKeyToAccount(KEYS.bob);
        const carol = privateKeyToAccount(KEYS.carol);
        const keeper = privateKeyToAccount(KEYS.keeper);
        accounts.alice = await newAccount(alice, operator.address);
        accounts.carol = await newAccount(carol, operator.address);
        accounts.bob = await newAccount(bob, operator.address);
        accounts.keeper = await newAccount(keeper);
        await depositCash(alice, accounts.alice, 2500n * 10n ** 6n);
        await depositCash(carol, accounts.carol, 3500n * 10n ** 6n);
        await depositCash(bob, accounts.bob, 20000n * 10n ** 6n);
        await depositCash(keeper, accounts.keeper, 20000n * 10n ** 6n);
        // Seed the security module.
        await giveUsdc(operator.address, 5000n * 10n ** 6n);
        await write(operator, USDC, 'approve', [stack.securityModule, 5000n * 10n ** 6n]);
        await write(operator, stack.securityModule, 'donate', [5000n * 10n ** 6n]);
        // Bob shorts to alice and to carol: 10M cNGN ($7,200) each.
        await write(operator, SUB_ACCOUNTS, 'submitTransfers', [
            [
                { fromAcc: accounts.bob, toAcc: accounts.alice, asset: stack.perp, subId: 0n, amount: SIZE, assetData: pad('0x', { size: 32 }) },
                { fromAcc: accounts.bob, toAcc: accounts.carol, asset: stack.perp, subId: 0n, amount: SIZE, assetData: pad('0x', { size: 32 }) },
            ],
            '0x',
        ]);
        // NGN falls 40%: alice (-$2,880 on $2,500) is insolvent, carol ($620 left, $864 MM) is not.
        await publish(CRASHED);
    });
    it('in dry run, decides and simulates but changes nothing', async () => {
        const actions = await runOnce(keeperConfig(true), createKeeperChain(keeperConfig(true)), alert);
        const started = actions.filter((a) => a.kind === 'start').map((a) => a.accountId);
        assert.deepEqual(started.sort(), [accounts.alice, accounts.carol].sort());
        assert.equal((await auctionOf(accounts.alice)).ongoing, false, 'dry run must not start anything');
    });
    it('starts an insolvent auction on alice and a solvent one on carol', async () => {
        await runOnce(keeperConfig(false), createKeeperChain(keeperConfig(false)), alert);
        const alice = await auctionOf(accounts.alice);
        const carol = await auctionOf(accounts.carol);
        assert.ok(alice.ongoing && alice.insolvent, 'alice insolvent auction');
        assert.ok(carol.ongoing && !carol.insolvent, 'carol solvent auction');
    });
    it('buys into carol at a discount but waits on alice until the payout covers her deficit', async () => {
        await publish(CRASHED);
        await runOnce(keeperConfig(false), createKeeperChain(keeperConfig(false)), alert);
        assert.ok((await perpOf(accounts.carol)) < SIZE, 'carol partly liquidated');
        assert.equal(await perpOf(accounts.keeper), 0n, 'the funding account stays cash-only: the position went to a bid account');
        assert.ok(alerts.includes('keeper-inventory'), 'and the keeper reports the inventory it now carries');
        assert.equal(await perpOf(accounts.alice), SIZE, 'alice untouched: her payout does not yet cover her deficit');
    });
    it('takes alice once the security module pays enough, and the security module pays', async () => {
        const smBefore = await cashOf(BigInt(stack.securityModuleAccount));
        await warp(60 * 60); // the insolvent auction's full length: payout at its maximum
        await publish(CRASHED);
        await runOnce(keeperConfig(false), createKeeperChain(keeperConfig(false)), alert);
        assert.equal(await perpOf(accounts.alice), 0n, 'alice closed out: a second bid works after the first');
        assert.ok((await cashOf(BigInt(stack.securityModuleAccount))) < smBefore, 'security module paid the keeper');
        assert.equal(await perpOf(accounts.keeper), 0n, 'funding account still cash-only');
    });
    // The runbook's step past INDEX_STEP_MAX_BPS: the vault freezes the perp, then --settle-frozen
    // settles everything still open -- the counterparty and the keeper's own bid accounts -- so the cap
    // can be closed without freezing anyone.
    it('after the vault freezes the perp, --settle-frozen leaves nobody holding it', async () => {
        const chainView = createKeeperChain(keeperConfig(false));
        await publish(CRASHED);
        await assert.rejects(chainView.settleFrozenPositions(false), /not disabled/);
        await write(VAULT, stack.perp, 'disable', []);
        const dry = await createKeeperChain(keeperConfig(true)).settleFrozenPositions(true);
        assert.ok(dry.settled.includes(accounts.bob), 'the dry run lists bob, the open counterparty');
        assert.notEqual(await perpOf(accounts.bob), 0n, 'and changes nothing');
        // Accounts mid-auction cannot be settled: they are reported, not settled. Whether any are left
        // at this point depends on how carol's auction went, so this asserts the invariant, not a list.
        const first = await chainView.settleFrozenPositions(false);
        assert.ok(first.settled.includes(accounts.bob), 'bob, the open counterparty, is settled');
        for (const id of first.underLiquidation)
            assert.ok((await auctionOf(id)).ongoing, `${id} is reported because it is mid-auction`);
        // A solvent auction that sold what it can but left buffer margin a hair below zero cannot be
        // terminated until its solvent phase (15 min fast + 12 h slow) runs out; then the keeper's
        // normal pass terminates or converts it, and the sweep completes. The runbook allows for this.
        let pending = first.underLiquidation;
        const settledIds = [...first.settled];
        for (let round = 0; round < 3 && pending.length > 0; round++) {
            await warp(12 * 60 * 60 + 15 * 60 + 60);
            await publish(CRASHED);
            await runOnce(keeperConfig(false), chainView, alert);
            const next = await chainView.settleFrozenPositions(false);
            settledIds.push(...next.settled);
            pending = next.underLiquidation;
        }
        assert.deepEqual(pending, [], 'nothing left under liquidation');
        for (const id of [...settledIds, accounts.alice, accounts.bob, accounts.carol]) {
            assert.equal(await perpOf(id), 0n, `account ${id} still holds the perp`);
        }
        const third = await chainView.settleFrozenPositions(false);
        assert.deepEqual([third.settled, third.underLiquidation], [[], []], 'a last pass finds nothing');
    });
});
