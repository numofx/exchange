/**
 * cNGN rebalance CLI. Every command is a DRY RUN unless `--execute` is passed.
 *
 *   rebalance quote   [amount]           what the live feed prices this at
 *   rebalance approve [amount]           exact-amount USDC allowance to the gateway
 *   rebalance swap    [amount]           place, run the auction, fill
 *   rebalance cancel  [commitment]       reclaim an unfilled order's escrow
 *   rebalance deposit [amount]           move cNGN into the market maker's subaccount
 *
 * Amounts are decimal token units (`20` = 20 USDC). `cancel` with no commitment targets the
 * newest still-PLACED order from this signer; `deposit` with no amount moves the whole balance.
 */
import { formatUnits, parseUnits } from 'viem';
import { createClients } from './clients.js';
import { loadConfig } from './config.js';
import { cancel } from './cancel.js';
import { deposit } from './deposit.js';
import { latestSnapshot, priceFromSnapshot } from './quote.js';
import { approve, swap } from './swap.js';
import { CNGN, TOKEN_DECIMALS, USDC } from './venue.js';

const USAGE = `usage: rebalance <quote|approve|swap|cancel|deposit> [amount|commitment] [--execute]`;

async function main(): Promise<void> {
  const argv = process.argv.slice(2);
  const execute = argv.includes('--execute');
  const positional = argv.filter((a) => !a.startsWith('--'));
  const command = positional[0];
  const arg = positional[1];

  if (!command || command === 'help' || command === '--help') { console.log(USAGE); return; }

  const config = loadConfig();

  if (command === 'quote') {
    const amount = parseUnits(arg ?? '20', TOKEN_DECIMALS);
    const snapshot = await latestSnapshot(config.INDEXER_URL, USDC, CNGN);
    const q = priceFromSnapshot(snapshot, amount, config.MAX_SNAPSHOT_AGE_SECONDS);
    console.log(`snapshot    ${snapshot.snapshotTime.toISOString()} (${(q.ageSeconds / 60).toFixed(1)} min, ${snapshot.bidCount} bids)`);
    console.log(`dispersion  ${snapshot.lowestPrice} / ${snapshot.medianPrice} / ${snapshot.highestPrice}`);
    console.log(`quote       ${formatUnits(amount, TOKEN_DECIMALS)} USDC -> ${formatUnits(q.amountOut, TOKEN_DECIMALS)} cNGN @ ${q.rate.toFixed(4)}`);
    return;
  }

  const clients = await createClients(config);
  switch (command) {
    case 'approve': return approve(config, clients, parseUnits(arg ?? '20', TOKEN_DECIMALS), execute);
    case 'swap': return swap(config, clients, parseUnits(arg ?? '20', TOKEN_DECIMALS), execute);
    case 'cancel': return cancel(config, clients, arg, execute);
    case 'deposit': return deposit(config, clients, arg ? parseUnits(arg, TOKEN_DECIMALS) : undefined, execute);
    default: throw new Error(`unknown command "${command}"\n${USAGE}`);
  }
}

main().catch((e: unknown) => {
  console.error(String(e instanceof Error ? e.message : e));
  process.exit(1);
});
