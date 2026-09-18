/**
 * Reclaim the escrowed input of an order that did not fill.
 *
 * Rebuilds the CANONICAL order from the indexer, not from what was submitted: the gateway assigns
 * the nonce and deducts the 5bps protocol fee from the input at placement, and `cancelOrder` hashes
 * the whole struct. The rebuild is checked against the on-chain commitment before anything is
 * sent — the indexer exposes no `beneficiary`, so that one field is assumed to equal `user` (true
 * for every order this service places) and the hash check is what proves the assumption.
 *
 * Recovery returns the escrow AND the solver fee; only the protocol fee is kept. Same-chain orders
 * need no destination proof, so `{ relayerFee: 0, height: 0 }` and a single transaction suffice.
 */
import { encodeAbiParameters, formatUnits, keccak256, pad, toHex, type Hex } from 'viem';
import type { Clients } from './clients.js';
import type { Config } from './config.js';
import { CANCEL_ORDER_ABI, ERC20_ABI, INTENT_GATEWAY, ORDER_TUPLE, TOKEN_DECIMALS, USDC, type Order } from './venue.js';
import { waitFor } from './clients.js';

const FIELDS = `user sourceChain destChain deadline nonce fees session status commitment predispatchCalldata
  predispatchAssets{nodes{token amount}} inputAssets{nodes{token amount}} outputAssets{nodes{token amount}}`;

type Row = {
  user: Hex; sourceChain: string; destChain: string; deadline: string; nonce: string; fees: string;
  session: Hex; status: string; commitment: Hex; predispatchCalldata: Hex;
  predispatchAssets: { nodes: { token: Hex; amount: string }[] };
  inputAssets: { nodes: { token: Hex; amount: string }[] };
  outputAssets: { nodes: { token: Hex; amount: string }[] };
};

async function query<T>(url: string, q: string): Promise<T> {
  const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) });
  const body = (await res.json()) as { data?: T; errors?: unknown };
  if (!body.data) throw new Error(`indexer: ${JSON.stringify(body.errors)}`);
  return body.data;
}

export function orderFromRow(row: Row): Order {
  const asset = (a: { token: Hex; amount: string }) => ({ token: a.token.toLowerCase() as Hex, amount: BigInt(a.amount) });
  return {
    user: pad(row.user, { size: 32 }).toLowerCase() as Hex,
    source: toHex(row.sourceChain),
    destination: toHex(row.destChain),
    deadline: BigInt(row.deadline),
    nonce: BigInt(row.nonce),
    fees: BigInt(row.fees),
    session: row.session,
    predispatch: { assets: row.predispatchAssets.nodes.map(asset), call: row.predispatchCalldata || '0x' },
    inputs: row.inputAssets.nodes.map(asset),
    output: { beneficiary: pad(row.user, { size: 32 }).toLowerCase() as Hex, assets: row.outputAssets.nodes.map(asset), call: '0x' },
  };
}

export function commitmentOf(order: Order): Hex {
  return keccak256(encodeAbiParameters([ORDER_TUPLE], [order as never]));
}

export async function cancel(config: Config, clients: Clients, commitment: string | undefined, execute: boolean): Promise<void> {
  const { account, publicClient, walletClient } = clients;
  const row = commitment
    ? (await query<{ iOrderV3: Row }>(config.INDEXER_URL, `{ iOrderV3(id:"${commitment}"){ ${FIELDS} } }`)).iOrderV3
    : (await query<{ iOrderV3s: { nodes: Row[] } }>(
        config.INDEXER_URL,
        `{ iOrderV3s(filter:{user:{equalTo:"${account.address.toLowerCase()}"},status:{equalTo:PLACED}}, orderBy: BLOCK_TIMESTAMP_DESC, first:1){ nodes{ ${FIELDS} } } }`,
      )).iOrderV3s.nodes[0];
  if (!row) { console.log('no PLACED order to cancel'); return; }

  const order = orderFromRow(row);
  const rebuilt = commitmentOf(order);
  console.log(`order       ${row.commitment} (${row.status})`);
  if (rebuilt !== row.commitment) {
    // Refuse rather than send a cancel for a struct the gateway will not recognise.
    console.log(`rebuild     MISMATCH — got ${rebuilt}; refusing`);
    return;
  }
  console.log('rebuild     matches commitment');

  const block = await publicClient.getBlockNumber();
  const reclaim = order.inputs.reduce((sum, i) => sum + i.amount, 0n);
  console.log(`deadline    ${order.deadline} (now ${block}, ${block > order.deadline ? `expired by ${block - order.deadline}` : 'STILL LIVE'})`);
  console.log(`reclaiming  ${formatUnits(reclaim, TOKEN_DECIMALS)} USDC`);

  const { request } = await publicClient.simulateContract({
    address: INTENT_GATEWAY, abi: CANCEL_ORDER_ABI, functionName: 'cancelOrder',
    args: [order as never, { relayerFee: 0n, height: 0n } as never], account,
  });
  console.log('simulation  OK');
  if (!execute) { console.log('(dry run; pass --execute to send)'); return; }

  const balance = () => publicClient.readContract({ address: USDC, abi: ERC20_ABI, functionName: 'balanceOf', args: [account.address] });
  const before = await balance();
  const hash = await walletClient.writeContract(request);
  console.log(`cancel tx   ${hash}`);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`${receipt.status} in block ${receipt.blockNumber}`);
  await waitFor(async () => (await balance()) > before, { what: 'refund' });
  const after = await balance();
  console.log(`USDC        ${formatUnits(before, TOKEN_DECIMALS)} -> ${formatUnits(after, TOKEN_DECIMALS)} (+${formatUnits(after - before, TOKEN_DECIMALS)})`);
}
