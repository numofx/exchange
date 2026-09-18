/**
 * Swap USDC for cNGN on the HyperFX IntentGateway.
 *
 * Placement is a plain contract call, but it is only half the job: `session` is an ephemeral
 * keypair the SDK generates per order, and whoever holds that key selects the winning bid. Kill
 * this process mid-auction and the order rides to its deadline and refunds — so the lifecycle is
 * driven by the SDK rather than hand-rolled, with only the quote replaced.
 */
import { EvmChain, IntentGateway, IntentsCoprocessor, createQueryClient } from '@hyperbridge/sdk';
import { formatUnits, pad, toHex, type Hex } from 'viem';
import type { Clients } from './clients.js';
import type { Config } from './config.js';
import { latestSnapshot, priceFromSnapshot } from './quote.js';
import { CNGN, ERC20_ABI, INTENT_GATEWAY, STATE_MACHINE_ID, TOKEN_DECIMALS, USDC, type Order } from './venue.js';

/** Orderflow attribution, so our own orders are findable in the indexer. */
const GRAFFITI = toHex('numo-rebalance', { size: 32 });

/**
 * Status updates embed live SDK objects: a Bid reaches through Swap -> UniswapQuoteEngine ->
 * adapter and closes a cycle, so a plain JSON.stringify throws and takes down a process that is
 * holding escrowed funds. Diagnostics must never be able to do that.
 */
function brief(value: unknown, limit = 400): string {
  const seen = new WeakSet<object>();
  let out: string;
  try {
    out = JSON.stringify(value, (_key, v: unknown) => {
      if (typeof v === 'bigint') return v.toString();
      if (typeof v === 'function') return '[fn]';
      if (typeof v === 'object' && v !== null) {
        if (seen.has(v)) return '[circular]';
        seen.add(v);
      }
      return v;
    }) ?? String(value);
  } catch (e) {
    out = `[unserialisable: ${String(e instanceof Error ? e.message : e)}]`;
  }
  return out.length > limit ? `${out.slice(0, limit)}...` : out;
}

export async function swap(config: Config, clients: Clients, amountIn: bigint, execute: boolean): Promise<void> {
  const { account, publicClient, walletClient } = clients;
  const log = (msg: string) => console.log(`${new Date().toISOString().slice(11, 19)}  ${msg}`);

  const [eth, usdc, allowance, block, snapshot] = await Promise.all([
    publicClient.getBalance({ address: account.address }),
    publicClient.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [account.address] }),
    publicClient.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'allowance', args: [account.address, INTENT_GATEWAY] }),
    publicClient.getBlockNumber(),
    latestSnapshot(config.INDEXER_URL, USDC, CNGN),
  ]);
  const quote = priceFromSnapshot(snapshot, amountIn, config.MAX_SNAPSHOT_AGE_SECONDS);

  // The gateway pulls principal PLUS fees, so the balance must cover both.
  const required = amountIn + config.SOLVER_FEE;
  console.log(`signer      ${account.address}`);
  console.log(`bundler     ${config.bundlerUrl === config.BASE_RPC_URL ? 'same endpoint as RPC' : config.bundlerUrl}`);
  console.log(`ETH         ${formatUnits(eth, 18)}`);
  console.log(`USDC        ${formatUnits(usdc, TOKEN_DECIMALS)} (need ${formatUnits(required, TOKEN_DECIMALS)})`);
  console.log(`snapshot    ${snapshot.snapshotTime.toISOString()} (${(quote.ageSeconds / 60).toFixed(1)} min, ${snapshot.bidCount} bids)`);
  console.log(`dispersion  ${snapshot.lowestPrice} / ${snapshot.medianPrice} / ${snapshot.highestPrice}`);
  console.log(`quote       ${formatUnits(amountIn, TOKEN_DECIMALS)} USDC -> ${formatUnits(quote.amountOut, TOKEN_DECIMALS)} cNGN @ ${quote.rate.toFixed(4)}`);

  const blockers: string[] = [];
  if (eth === 0n) blockers.push('signer holds no ETH for gas');
  if (usdc < required) blockers.push(`holds ${formatUnits(usdc, TOKEN_DECIMALS)} USDC, needs ${formatUnits(required, TOKEN_DECIMALS)}`);
  if (allowance < required) blockers.push(`USDC allowance to the gateway is ${formatUnits(allowance, TOKEN_DECIMALS)}, needs ${formatUnits(required, TOKEN_DECIMALS)} (run \`approve\`)`);

  const order: Order = {
    user: pad(account.address, { size: 32 }),
    source: toHex(STATE_MACHINE_ID),
    destination: toHex(STATE_MACHINE_ID),
    deadline: block + config.DEADLINE_BLOCKS,
    // Submitted as 0; the gateway assigns the real nonce, which is what the commitment hashes.
    nonce: 0n,
    fees: config.SOLVER_FEE,
    // Overwritten by the SDK with a freshly generated session key.
    session: '0x0000000000000000000000000000000000000000',
    predispatch: { assets: [], call: '0x' },
    inputs: [{ token: pad(USDC, { size: 32 }), amount: amountIn }],
    output: {
      beneficiary: pad(account.address, { size: 32 }),
      assets: [{ token: pad(CNGN, { size: 32 }), amount: quote.amountOut }],
      call: '0x',
    },
  };

  if (!execute) {
    console.log(`deadline    block ${order.deadline} (now ${block}, +${config.DEADLINE_BLOCKS})`);
    console.log(`graffiti    ${GRAFFITI}`);
    console.log(blockers.length ? `\nBLOCKERS:\n  - ${blockers.join('\n  - ')}` : '\nno blockers: ready to --execute');
    return;
  }
  if (blockers.length) throw new Error(`refusing to execute:\n  - ${blockers.join('\n  - ')}`);

  const chain = await EvmChain.create(config.BASE_RPC_URL, config.bundlerUrl);
  const coprocessor = await IntentsCoprocessor.connect(config.COPROCESSOR_URL);
  const gateway = (await IntentGateway.create(chain, chain, coprocessor))
    .withQueryClient(createQueryClient({ url: config.INDEXER_URL }));

  const run = gateway.executeBest(order as never, GRAFFITI, { auctionTimeMs: config.AUCTION_MS });
  let resume: Hex | undefined;
  for (;;) {
    const step = resume === undefined ? await run.next() : await run.next(resume);
    if (step.done) break;
    const update = step.value as unknown as Record<string, never> & { status: string };
    resume = undefined;

    switch (update.status) {
      case 'AWAITING_PLACE_ORDER': {
        const p = update as unknown as { to: Hex; data: Hex; value: bigint; feeTokenAmount: bigint; feeTokenAddress: Hex };
        log(`AWAITING_PLACE_ORDER  fee ${formatUnits(p.feeTokenAmount, TOKEN_DECIMALS)} in ${p.feeTokenAddress}`);
        const hash = await walletClient.sendTransaction({ account, chain: walletClient.chain, to: p.to, data: p.data, value: p.value });
        log(`  placement tx ${hash}`);
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        log(`  ${receipt.status} in block ${receipt.blockNumber}, gas ${receipt.gasUsed}`);
        resume = hash;
        break;
      }
      case 'ORDER_PLACED':
        log(`ORDER_PLACED          ${String((update as unknown as { order?: { id?: string } }).order?.id ?? '')}`);
        break;
      case 'AWAITING_BIDS':
        log(`AWAITING_BIDS         ${String(update.commitment)}`);
        break;
      case 'NEW_BID':
        // Narrow on purpose: the full Bid is circular.
        log('NEW_BID');
        break;
      case 'BIDS_RECEIVED':
        log(`BIDS_RECEIVED         ${String(update.bidCount)} bid(s)`);
        break;
      case 'BID_SELECTED':
        log(`BID_SELECTED          solver ${String(update.selectedSolver)}`);
        break;
      case 'FILLED':
      case 'PARTIAL_FILL': {
        const assets = (update.totalFilledAssets ?? []) as unknown as { token: Hex; amount: bigint }[];
        log(`${update.status}                ${assets.map((a) => formatUnits(a.amount, TOKEN_DECIMALS)).join(', ')} cNGN`);
        if (update.transactionHash) log(`  fill tx ${String(update.transactionHash)}`);
        break;
      }
      case 'FAILED':
      case 'CANCELLED':
      case 'TIMED_OUT':
        log(`${update.status}`);
        log(`  error: ${String(update.error ?? '(none reported)')}`);
        if (update.commitment) log(`  commitment ${String(update.commitment)} — run \`cancel\` to reclaim the escrow`);
        break;
      default:
        log(`${update.status}  ${brief(update)}`);
    }
  }
}

/** Exact-amount approval: an unbounded allowance is a standing claim on whatever this key holds. */
export async function approve(config: Config, clients: Clients, amountIn: bigint, execute: boolean): Promise<void> {
  const { account, publicClient, walletClient } = clients;
  const needed = amountIn + config.SOLVER_FEE;
  const current = await publicClient.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'allowance', args: [account.address, INTENT_GATEWAY] });
  console.log(`allowance   ${formatUnits(current, TOKEN_DECIMALS)} -> ${formatUnits(needed, TOKEN_DECIMALS)} USDC`);
  if (current >= needed) { console.log('already sufficient; nothing to do'); return; }
  if (!execute) { console.log('(dry run; pass --execute to send)'); return; }
  const hash = await walletClient.writeContract({ account, chain: walletClient.chain, address: USDC, abi: ERC20_ABI, functionName: 'approve', args: [INTENT_GATEWAY, needed] });
  console.log(`approve tx  ${hash}`);
  await publicClient.waitForTransactionReceipt({ hash });
  console.log('approved');
}
