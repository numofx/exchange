/**
 * One take on risk-core's OnchainBook with fresh Data Streams reports attached: the book quotes only while both of
 * the adapter's stored reports are at most `takeMaxAge` (1 s) old, so a take posts its own (`optionalReport`,
 * abi.encode(bytes[])). For the Stage 2 mainnet canary's test takes (spec Part B); not a trading client.
 *
 *   RPC_URL=… TAKER_PRIVATE_KEY=… DATA_STREAMS_USERNAME=… DATA_STREAMS_SECRET=… \
 *     pnpm --dir services/perp-feeds exec tsx scripts/book-take.ts \
 *       --book=0x… --account=<taker id> --side=buy|sell --lots=<n> --limit=<USDC per EURC> --max-fee=<USDC> [--execute]
 *
 * minFill is the whole amount: a take that would fill less (stale reports, no quote in band) reverts at the estimate
 * and sends nothing. Without --execute it only simulates.
 */
import {
  createPublicClient,
  createWalletClient,
  decodeEventLog,
  encodeAbiParameters,
  http,
  parseAbi,
  parseUnits,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base } from 'viem/chains';

import { adapterAbi, signedReportSource } from '../src/streams-poster.js';

const arg = (name: string): string | undefined =>
  process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const need = (name: string): string => {
  const v = arg(name);
  if (!v) throw new Error(`--${name} is required`);
  return v;
};
const env = (name: string): string => {
  const v = process.env[name]?.trim();
  if (!v) throw new Error(`${name} is required`);
  return v;
};

const bookAbi = parseAbi([
  'function markets(uint256) view returns (address future, address engine, uint96 subId, uint64 expiry, uint64 lastTradeTime, address adapter, uint256 tickSize, uint256 lotSize, uint256 takerFeeRate, uint32 takeMaxAge, uint32 maxTtl, uint16 maxMakers, bool enabled)',
  'struct TakeOrder { uint256 marketId; uint256 takerAccountId; bool isBuy; uint256 amount; uint256 limitPrice; uint256 minFill; uint256 maxFee; uint64 deadline; uint16 maxLevels; uint8 selfTradeMode; bytes managerData; }',
  'function take(TakeOrder o, bytes optionalReport) returns (uint256 filled, uint256 avgPrice)',
  'event Fill(uint256 indexed marketId, uint256 indexed takerAccountId, uint256 indexed makerAccountId, bool isBuy, uint256 amount, uint256 price, uint256 fee)',
  'event TakeExecuted(uint256 indexed marketId, uint256 indexed takerAccountId, bool isBuy, uint256 filled, uint256 avgPrice, uint256 fee)',
  // OnchainBook's and StreamsIndexAdapter's errors (risk-core out/), so a revert names itself.
  'error OB_AlreadyRegistered()',
  'error OB_BatchOutOfGas()',
  'error OB_BelowMinFill()',
  'error OB_CrossedSpline()',
  'error OB_Expired()',
  'error OB_FeeTooHigh()',
  'error OB_GasFloor()',
  'error OB_InvalidCurve()',
  'error OB_InvalidMarket()',
  'error OB_InvalidParams()',
  'error OB_InvalidTtl()',
  'error OB_MakerNotAllowed()',
  'error OB_MarketDisabled()',
  'error OB_NotAuthorized()',
  'error OB_NotRegistered()',
  'error OB_SelfTrade()',
  'error OB_StaleSeq()',
  'error OB_TakerAllowanceTooLow()',
  'error OB_TooManyMakers()',
  'error OB_TradingClosed()',
  'error OB_WrongManager()',
  'error OwnableInvalidOwner(address)',
  'error OwnableUnauthorizedAccount(address)',
  'error ReentrancyGuardReentrantCall()',
  'error SafeCastOverflowedUintDowncast(uint8,uint256)',
  'error SafeCastOverflowedUintToInt(uint256)',
  'error SIA_FeedMismatch()',
  'error SIA_InvalidConfig()',
  'error SIA_InvalidPrice()',
  'error SIA_UnknownFeed(bytes32)',
]);

async function main() {
  const book = need('book') as Address;
  const marketId = BigInt(arg('market') ?? '1');
  const account = BigInt(need('account'));
  const side = need('side');
  if (side !== 'buy' && side !== 'sell') throw new Error('--side is buy or sell');
  const lots = BigInt(need('lots'));
  const limit = parseUnits(need('limit'), 18);
  const maxFee = parseUnits(need('max-fee'), 18);
  const execute = process.argv.includes('--execute');

  const rpc = env('RPC_URL');
  const client = createPublicClient({ chain: base, transport: http(rpc) });
  const taker = privateKeyToAccount(env('TAKER_PRIVATE_KEY') as Hex);
  const wallet = createWalletClient({ chain: base, transport: http(rpc), account: taker });

  const m = await client.readContract({ address: book, abi: bookAbi, functionName: 'markets', args: [marketId] });
  const [, , , , , adapter, , lotSize, , takeMaxAge, , , enabled] = m;
  if (!enabled) throw new Error(`market ${marketId} is not enabled`);
  const baseFeed = await client.readContract({ address: adapter, abi: adapterAbi, functionName: 'baseFeedId' });
  const quoteFeed = await client.readContract({ address: adapter, abi: adapterAbi, functionName: 'quoteFeedId' });
  const source = signedReportSource(process.env.DATA_STREAMS_HOST ?? 'https://api.dataengine.chain.link', env('DATA_STREAMS_USERNAME'), env('DATA_STREAMS_SECRET'));

  const amount = lots * lotSize;
  const head = await client.getBlock();
  const [b, q] = await Promise.all([source(baseFeed), source(quoteFeed)]);
  const report = encodeAbiParameters([{ type: 'bytes[]' }], [[b.fullReport, q.fullReport]]);
  const order = {
    marketId,
    takerAccountId: account,
    isBuy: side === 'buy',
    amount,
    limitPrice: limit,
    minFill: amount,
    maxFee,
    deadline: head.timestamp + 60n,
    maxLevels: 20,
    selfTradeMode: 0,
    managerData: '0x' as Hex,
  };
  console.log(`${side} ${lots} lots (${amount}) on market ${marketId} from #${account}, limit ${limit}, maxFee ${maxFee}; ` +
    `reports at ${b.observationsTimestamp}/${q.observationsTimestamp}, head ${head.timestamp}, takeMaxAge ${takeMaxAge}s`);

  const sim = await client.simulateContract({ address: book, abi: bookAbi, functionName: 'take', args: [order, report], account: taker });
  console.log(`simulated: filled ${sim.result[0]}, avgPrice ${sim.result[1]}`);
  if (!execute) {
    console.log('dry run: nothing sent (--execute to send)');
    return;
  }
  const hash = await wallet.writeContract(sim.request);
  const receipt = await client.waitForTransactionReceipt({ hash });
  console.log(`tx ${hash} block ${receipt.blockNumber} status ${receipt.status} gas ${receipt.gasUsed}`);
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== book.toLowerCase()) continue;
    try {
      const ev = decodeEventLog({ abi: bookAbi, data: log.data, topics: log.topics });
      console.log(`  ${ev.eventName} ${JSON.stringify(ev.args, (_, v) => (typeof v === 'bigint' ? v.toString() : v))}`);
    } catch {
      // not one of the two
    }
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? err.message : err);
  process.exit(1);
});
