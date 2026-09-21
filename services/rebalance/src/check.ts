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
import { assessInventory } from './inventory.js';
import { latestSnapshot, priceFromSnapshot } from './quote.js';
import { CNGN, CNGN_ESCROW, LEDGER_DECIMALS, SUBACCOUNTS, SUBACCOUNTS_ABI, TOKEN_DECIMALS, USDC, USDC_ESCROW } from './venue.js';

/**
 * Typed to ReadClients on purpose: tsc then refuses any future edit that reaches for a signer here.
 * `fetchSnapshot` is injectable so the verdict can be tested through this function rather than only
 * through assessInventory -- the thresholds, the price source and which escrows count are all
 * decided here, and testing a reimplementation of them proves nothing about this one.
 */
export async function check(
  config: Config,
  clients: ReadClients,
  alert: boolean,
  post: PostAlert = defaultPostAlert,
  fetchSnapshot: typeof latestSnapshot = latestSnapshot,
  heartbeat = false,
): Promise<void> {
  // Validated BEFORE anything is read, not at the point of sending. Checked only when an alert
  // was due, a --alert run with no webhook configured looks healthy for as long as the inventory
  // is healthy, and fails for the first time on the run that finally had something to say.
  if ((alert || heartbeat) && !config.ALERT_WEBHOOK_URL) {
    throw new Error('ALERT_WEBHOOK_URL is not set, so --alert/--heartbeat would reach nobody');
  }

  const sub = config.MM_SUBACCOUNT_ID;
  const [rows, snapshot] = await Promise.all([
    clients.publicClient.readContract({ address: SUBACCOUNTS, abi: SUBACCOUNTS_ABI, functionName: 'getAccountBalances', args: [sub] }),
    fetchSnapshot(config.INDEXER_URL, USDC, CNGN),
  ]);
  const held = (escrow: string) => rows.find((r) => r.asset.toLowerCase() === escrow.toLowerCase())?.balance ?? 0n;

  // One whole USDC, priced through the same path a rebalance would use, so the valuation and the
  // trade cannot disagree.
  const oneUsdc = 10n ** BigInt(TOKEN_DECIMALS);
  const rate = priceFromSnapshot(snapshot, oneUsdc, config.MAX_SNAPSHOT_AGE_SECONDS).rate;

  const verdict = assessInventory({ usdc: held(USDC_ESCROW), cngn: held(CNGN_ESCROW), rate }, {
    cngnMinShare: config.CNGN_MIN_SHARE,
    cngnFloorUsd: config.CNGN_FLOOR_USD,
    haltNetInventoryUsd: config.HALT_NET_INVENTORY_USD,
  }, sub);

  console.log(`sub ${sub}      USDC ${formatUnits(held(USDC_ESCROW), LEDGER_DECIMALS)} / cNGN ${formatUnits(held(CNGN_ESCROW), LEDGER_DECIMALS)}`);
  console.log(`rate        ${rate.toFixed(4)} (snapshot ${snapshot.snapshotTime.toISOString()})`);
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
    return;
  }
  const prefix = verdict.action === 'none' ? 'heartbeat — ' : '';
  await post(config.ALERT_WEBHOOK_URL as string, `${prefix}${verdict.message}`);
  console.log(heartbeat && verdict.action === 'none' ? 'heartbeat posted' : 'alert posted');
}
