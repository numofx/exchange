/**
 * Reads the market maker's subaccount and says whether a rebalance is due.
 *
 * Meant for a timer. `--alert` posts to the ops webhook; without it this only prints, so the
 * threshold can be tuned against live numbers without paging anyone.
 */
import { formatUnits } from 'viem';
import { postAlert as defaultPostAlert, type PostAlert } from './alert.js';
import type { ReadClients } from './clients.js';
import type { Config } from './config.js';
import { assessInventory, type Verdict } from './inventory.js';

/**
 * Prefix for anything fired by hand into a shared channel. Without it a drill is indistinguishable
 * from a real finding, and someone spends their afternoon investigating a venue that is fine.
 */
export const TEST_PREFIX = '[TEST] ';
import { orderbookQuote, type FetchQuote } from './orderbook.js';
import { fetchMarkets as defaultFetchMarkets, resolveSpotVenue, type FetchMarkets } from './spot.js';
import { LEDGER_DECIMALS, SUBACCOUNTS, SUBACCOUNTS_ABI, TOKEN_DECIMALS } from './venue.js';

/**
 * Typed to ReadClients on purpose: tsc then refuses any future edit that reaches for a signer here.
 * `fetchQuote` is injectable so the verdict can be tested through this function rather than only
 * through assessInventory -- the thresholds, the price source and which escrows count are all
 * decided here, and testing a reimplementation of them proves nothing about this one.
 */
export async function check(
  config: Config,
  clients: ReadClients,
  alert: boolean,
  post: PostAlert = defaultPostAlert,
  fetchQuote: FetchQuote = orderbookQuote,
  heartbeat = false,
  /** Marks a message as a drill. Anything posted to a shared channel by hand must carry this. */
  testRun = false,
  fetchMarkets: FetchMarkets = defaultFetchMarkets,
): Promise<Verdict['action']> {
  // Validated BEFORE anything is read, not at the point of sending. Checked only when an alert
  // was due, a --alert run with no webhook configured looks healthy for as long as the inventory
  // is healthy, and fails for the first time on the run that finally had something to say.
  if ((alert || heartbeat) && !config.ALERT_WEBHOOK_URL) {
    throw new Error('ALERT_WEBHOOK_URL is not set, so --alert/--heartbeat would reach nobody');
  }

  const sub = config.MM_SUBACCOUNT_ID;
  const venue = await resolveSpotVenue(config.VENUE_API_URL, sub, clients.publicClient, fetchMarkets);
  // One whole USDC, priced through the same orderbook a rebalance would trade on, so the
  // valuation and the trade cannot disagree.
  const [rows, quote] = await Promise.all([
    clients.publicClient.readContract({ address: SUBACCOUNTS, abi: SUBACCOUNTS_ABI, functionName: 'getAccountBalances', args: [sub] }),
    fetchQuote(config.ORDERBOOK_URL, 10n ** BigInt(TOKEN_DECIMALS)),
  ]);
  const rate = quote.rate;
  const held = (asset: string) => rows.find((r) => r.asset.toLowerCase() === asset.toLowerCase())?.balance ?? 0n;
  const usdc = held(venue.quoteAsset);
  const cngn = held(venue.cngnEscrow);

  const verdict = assessInventory({ usdc, cngn, rate }, {
    cngnMinShare: config.CNGN_MIN_SHARE,
    cngnFloorUsd: config.CNGN_FLOOR_USD,
    haltNetInventoryUsd: config.HALT_NET_INVENTORY_USD,
  }, sub);

  console.log(`sub ${sub}      USDC ${formatUnits(usdc, LEDGER_DECIMALS)} / cNGN ${formatUnits(cngn, LEDGER_DECIMALS)}`);
  console.log(`rate        ${rate.toFixed(4)} (HyperFX orderbook, pessimistic)`);
  console.log(`valued      USDC $${verdict.usdcUsd.toFixed(2)} / cNGN $${verdict.cngnUsd.toFixed(2)} (cNGN ${(verdict.cngnShare * 100).toFixed(1)}%)`);
  console.log(`action      ${verdict.action}`);
  for (const reason of verdict.reasons) console.log(`  - ${reason}`);

  // --heartbeat posts on EVERY run, healthy or not. Without it a healthy --alert run is silent,
  // and silence is indistinguishable from a timer that stopped firing, a host that went away, or
  // credentials that lapsed. Schedule --alert often (pages only on a finding) and --heartbeat
  // rarely (proves the checker is alive and carries the numbers with it).
  const shouldPost = heartbeat || (alert && verdict.action !== 'none');
  if (!shouldPost) {
    if (!alert && verdict.action !== 'none') console.log('\n(pass --alert to post this to the ops webhook)');
    return verdict.action;
  }
  const prefix = `${testRun ? TEST_PREFIX : ''}${verdict.action === 'none' ? 'heartbeat — ' : ''}`;
  await post(config.ALERT_WEBHOOK_URL as string, `${prefix}${verdict.message}`);
  console.log(heartbeat && verdict.action === 'none' ? 'heartbeat posted' : 'alert posted');
  return verdict.action;
}
