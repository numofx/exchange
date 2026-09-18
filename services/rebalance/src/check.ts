/**
 * Reads the market maker's subaccount and says whether a rebalance is due.
 *
 * Meant for a timer. `--alert` posts to the ops webhook; without it this only prints, so the
 * threshold can be tuned against live numbers without paging anyone.
 */
import { formatUnits } from 'viem';
import { postAlert as defaultPostAlert, type PostAlert } from './alert.js';
import type { Clients } from './clients.js';
import type { Config } from './config.js';
import { assessInventory } from './inventory.js';
import { latestSnapshot, priceFromSnapshot } from './quote.js';
import { CNGN, CNGN_ESCROW, LEDGER_DECIMALS, SUBACCOUNTS, SUBACCOUNTS_ABI, TOKEN_DECIMALS, USDC, USDC_ESCROW } from './venue.js';

export async function check(
  config: Config,
  clients: Clients,
  alert: boolean,
  post: PostAlert = defaultPostAlert,
): Promise<void> {
  const sub = config.MM_SUBACCOUNT_ID;
  const [rows, snapshot] = await Promise.all([
    clients.publicClient.readContract({ address: SUBACCOUNTS, abi: SUBACCOUNTS_ABI, functionName: 'getAccountBalances', args: [sub] }),
    latestSnapshot(config.INDEXER_URL, USDC, CNGN),
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

  if (!alert) { if (verdict.action !== 'none') console.log('\n(pass --alert to post this to the ops webhook)'); return; }
  if (verdict.action === 'none') return;
  if (!config.ALERT_WEBHOOK_URL) {
    // Refuse rather than log-and-exit-0: an alert path that reaches nobody while reporting success
    // is the failure mode this repo keeps finding.
    throw new Error('ALERT_WEBHOOK_URL is not set, so --alert would reach nobody');
  }
  await post(config.ALERT_WEBHOOK_URL, verdict.message);
  console.log('alert posted');
}
