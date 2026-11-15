import { createHash, createHmac } from 'node:crypto';

import { encodeAbiParameters, keccak256, parseAbi, parseSignature, concat, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { Alerter } from './alert.js';
import type { ContractChain } from './chain.js';
import type { ForwardConfig } from './forward-config.js';

/** EurcIndexFeed and StreamsIndexAdapter (contracts/risk-core/src/feeds). */
export const indexFeedAbi = parseAbi([
  'function adapter() view returns (address)',
  'function indexMaxAge() view returns (uint256)',
]);
export const adapterAbi = parseAbi([
  'function baseFeedId() view returns (bytes32)',
  'function quoteFeedId() view returns (bytes32)',
  'function latest(bytes32 feedId) view returns (uint256 price, uint64 observedAt)',
  'function postReports(bytes[] reports)',
]);

export type StreamsReport = { feedID: Hex; observationsTimestamp: number; fullReport: Hex };
export type ReportSource = (feedId: Hex) => Promise<StreamsReport>;

/**
 * The Data Streams REST API's latest report for a feed, HMAC-signed (docs.chain.link, "Authentication"):
 * signature = HMAC-SHA256(secret, "GET <path> <sha256(body)> <username> <timestamp ms>"). Cloudflare refuses the
 * default client user agent (error 1010), so a plain one is sent.
 */
export function signedReportSource(
  host: string,
  username: string,
  secret: string,
  fetchImpl: typeof fetch = fetch,
  now: () => number = Date.now,
): ReportSource {
  return async (feedId) => {
    const path = `/api/v1/reports/latest?feedID=${feedId}`;
    const timestamp = String(now());
    const bodyHash = createHash('sha256').update('').digest('hex');
    const signature = createHmac('sha256', secret).update(`GET ${path} ${bodyHash} ${username} ${timestamp}`).digest('hex');
    const response = await fetchImpl(`${host}${path}`, {
      headers: {
        Authorization: username,
        'X-Authorization-Timestamp': timestamp,
        'X-Authorization-Signature-SHA256': signature,
        'User-Agent': 'data-streams-client/1.0',
      },
    });
    if (!response.ok) throw new Error(`Data Streams ${response.status} for ${feedId}: ${(await response.text()).slice(0, 200)}`);
    const body = (await response.json()) as { report?: StreamsReport };
    const report = body.report;
    if (!report || report.feedID?.toLowerCase() !== feedId.toLowerCase() || !/^0x[0-9a-fA-F]+$/.test(report.fullReport ?? '')) {
      throw new Error(`Data Streams answered for ${feedId} without a report for it`);
    }
    return report;
  };
}

const reportV3 = [
  {
    type: 'tuple',
    components: [
      { name: 'feedId', type: 'bytes32' },
      { name: 'validFromTimestamp', type: 'uint32' },
      { name: 'observationsTimestamp', type: 'uint32' },
      { name: 'nativeFee', type: 'uint192' },
      { name: 'linkFee', type: 'uint192' },
      { name: 'expiresAt', type: 'uint32' },
      { name: 'benchmarkPrice', type: 'int192' },
      { name: 'bid', type: 'int192' },
      { name: 'ask', type: 'int192' },
    ],
  },
] as const;

const fullReportParams = [
  { type: 'bytes32[3]' },
  { type: 'bytes' },
  { type: 'bytes32[]' },
  { type: 'bytes32[]' },
  { type: 'bytes32' },
] as const;

/**
 * TESTNET ONLY: reports signed by our own key, for the Base Sepolia rehearsal's StandInStreamsVerifier
 * (contracts/risk-core/scripts/rehearsal), where we hold no testnet Data Streams credentials. Each report is a V3
 * report at `prices[feedId]` (18dp), observed at `now` (the chain's head time: equal to the wall clock on Sepolia, and
 * it follows a local chain whose time is advanced, so the whole drill can run there first), in Chainlink's full-report layout, signed as Chainlink's
 * verifier checks it: keccak256(keccak256(reportData) ‖ reportContext), v - 27 in the first byte of rawVs.
 * forward-config refuses it on Base mainnet.
 */
export function standInReportSource(
  key: Hex,
  prices: Record<string, bigint>,
  now: () => number | Promise<number> = () => Math.floor(Date.now() / 1000),
): ReportSource {
  const account = privateKeyToAccount(key);
  return async (feedId) => {
    const price = prices[feedId.toLowerCase()];
    if (price === undefined) throw new Error(`stand-in source has no price for ${feedId}`);
    const at = await now();
    const reportData = encodeAbiParameters(reportV3, [
      {
        feedId,
        validFromTimestamp: at,
        observationsTimestamp: at,
        nativeFee: 0n,
        linkFee: 0n,
        expiresAt: at + 86_400,
        benchmarkPrice: price,
        bid: price,
        ask: price,
      },
    ]);
    const context: [Hex, Hex, Hex] = [keccak256('0x01'), `0x${at.toString(16).padStart(64, '0')}`, `0x${'00'.repeat(32)}`];
    const digest = keccak256(concat([keccak256(reportData), ...context]));
    const signature = parseSignature(await account.sign({ hash: digest }));
    const v = Number(signature.yParity ?? (signature.v! - 27n));
    const rawVs = `0x${v.toString(16).padStart(2, '0')}${'00'.repeat(31)}` as Hex;
    const fullReport = encodeAbiParameters(fullReportParams, [context, reportData, [signature.r], [signature.s], rawVs]);
    return { feedID: feedId, observationsTimestamp: at, fullReport };
  };
}

export type PostOutcome = 'fresh' | 'posted' | 'failed';

/**
 * Keeps a v3 future's index fresh (docs/eurc-usdc-futures-spec.md, A2.2): each tick, if either stream's stored report
 * is older than STREAMS_REFRESH_S, fetches the newest of both and posts them to the adapter. Stage 1 has no reports
 * attached to orders, so every fill, mark and fixing sample depends on this.
 *
 * The adapter and its two feed ids are read from the index feed on chain, not configured. It alerts when a post fails,
 * and separately when a stream's stored report has passed indexMaxAge: from then on fills, marks and samples revert.
 */
export class StreamsPoster {
  private adapter?: Address;
  private feeds?: [Hex, Hex];
  private maxAge?: bigint;

  constructor(
    private readonly config: ForwardConfig,
    private readonly chain: ContractChain,
    private readonly alert: Alerter,
    private readonly source: ReportSource,
  ) {}

  private async wiring(): Promise<{ adapter: Address; feeds: [Hex, Hex]; maxAge: bigint }> {
    if (!this.adapter || !this.feeds || this.maxAge === undefined) {
      this.adapter = await this.chain.read<Address>(this.config.INDEX_FEED, indexFeedAbi, 'adapter');
      this.maxAge = await this.chain.read<bigint>(this.config.INDEX_FEED, indexFeedAbi, 'indexMaxAge');
      this.feeds = [
        await this.chain.read<Hex>(this.adapter, adapterAbi, 'baseFeedId'),
        await this.chain.read<Hex>(this.adapter, adapterAbi, 'quoteFeedId'),
      ];
    }
    return { adapter: this.adapter, feeds: this.feeds, maxAge: this.maxAge };
  }

  /** Refuses a refresh or tick too slow for the index's staleness limit. Run once at startup. */
  async checkCadence(): Promise<void> {
    const { maxAge } = await this.wiring();
    const refresh = BigInt(this.config.STREAMS_REFRESH_S);
    const tick = BigInt(Math.ceil(this.config.FORWARD_TICK_MS / 1000));
    // A report must be replaced before it ages out even if one tick's post fails: refresh + 2 ticks inside maxAge.
    if (refresh + 2n * tick > maxAge) {
      throw new Error(
        `STREAMS_REFRESH_S (${refresh}s) + 2 x FORWARD_TICK_MS (${tick}s) must fit inside the index's indexMaxAge (${maxAge}s)`,
      );
    }
  }

  async tick(): Promise<PostOutcome> {
    const { adapter, feeds, maxAge } = await this.wiring();
    const head = await this.chain.headTimestamp();
    const stored = await Promise.all(
      feeds.map((feed) => this.chain.read<readonly [bigint, bigint]>(adapter, adapterAbi, 'latest', [feed])),
    );
    // never posted: as old as the chain; stamped ahead of the block (clock skew): fresh, as EurcIndexFeed counts it
    const ages = stored.map(([, observedAt]) => (observedAt === 0n ? head : head > observedAt ? head - observedAt : 0n));
    if (ages.every((age) => age < BigInt(this.config.STREAMS_REFRESH_S))) return 'fresh';

    try {
      const reports = await Promise.all(feeds.map((feed) => this.source(feed)));
      if (this.config.DRY_RUN) {
        console.log(`[streams] DRY RUN: would post reports observed at ${reports.map((r) => r.observationsTimestamp).join(', ')}`);
        return 'posted';
      }
      const tx = await this.chain.write(adapter, adapterAbi, 'postReports', [reports.map((r) => r.fullReport)]);
      console.log(`[streams] posted reports observed at ${reports.map((r) => r.observationsTimestamp).join(', ')} tx=${tx}`);
      return 'posted';
    } catch (error) {
      await this.alert('streams-post-failed', `posting Data Streams reports failed: ${(error as Error).message.slice(0, 300)}`);
      const stale = ages.findIndex((age) => age > maxAge);
      if (stale >= 0) {
        await this.alert(
          'index-stale',
          `${this.config.BASE_SYMBOL} index stale: ${feeds[stale]} last observed ${ages[stale]}s ago (limit ${maxAge}s); fills, marks and fixing samples revert until a report lands`,
        );
      }
      return 'failed';
    }
  }
}
