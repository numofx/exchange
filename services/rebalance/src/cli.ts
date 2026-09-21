/**
 * cNGN rebalance CLI. Every command is a DRY RUN unless `--execute` is passed.
 *
 *   rebalance check   [--alert]           is a rebalance due? (for a timer)
 *   rebalance quote   [amount]           what the live feed prices this at
 *   rebalance approve [amount]           exact-amount USDC allowance to the gateway
 *   rebalance swap    [amount]           place, run the auction, fill
 *   rebalance cancel  [commitment]       reclaim an unfilled order's escrow
 *   rebalance deposit [amount]           move cNGN into the market maker's subaccount
 *
 * Amounts are decimal token units (`20` = 20 USDC). `cancel` with no commitment targets the
 * newest still-PLACED order from this signer; `deposit` with no amount moves the whole balance.
 */
import { pathToFileURL } from 'node:url';
import { formatUnits, parseUnits } from 'viem';
import { createClients, createReadClient, type Clients, type ReadClients } from './clients.js';
import { postAlert, type PostAlert } from './alert.js';
import { loadConfig, type Config } from './config.js';
import { cancel } from './cancel.js';
import { check } from './check.js';
import { deposit } from './deposit.js';
import { latestSnapshot, priceFromSnapshot } from './quote.js';
import { approve, swap } from './swap.js';
import { CNGN, TOKEN_DECIMALS, USDC } from './venue.js';

const USAGE = `usage: rebalance <check|quote|approve|swap|cancel|deposit> [amount|commitment] [--execute]`;

/**
 * The seams a test needs. `signingClients` is separate from `readClients` so a test can assert it
 * is NEVER called for a read-only command -- the regression this guards against is a future edit
 * hoisting client construction above the switch again, which typechecks fine and leaves CI green
 * while breaking the one command meant to run unattended.
 */
export type CliDeps = {
  readClients: (config: Config) => ReadClients;
  signingClients: (config: Config) => Promise<Clients>;
  post: PostAlert;
  fetchSnapshot: typeof latestSnapshot;
};

export const defaultDeps: CliDeps = {
  readClients: createReadClient,
  signingClients: createClients,
  post: postAlert,
  fetchSnapshot: latestSnapshot,
};

export async function runCommand(argv: string[], config: Config, deps: CliDeps = defaultDeps): Promise<void> {
  const execute = argv.includes('--execute');
  const positional = argv.filter((a) => !a.startsWith('--'));
  const command = positional[0];
  const arg = positional[1];

  if (!command || command === 'help' || command === '--help') { console.log(USAGE); return; }

  if (command === 'quote') {
    const amount = parseUnits(arg ?? '20', TOKEN_DECIMALS);
    const snapshot = await deps.fetchSnapshot(config.INDEXER_URL, USDC, CNGN);
    const q = priceFromSnapshot(snapshot, amount, config.MAX_SNAPSHOT_AGE_SECONDS);
    console.log(`snapshot    ${snapshot.snapshotTime.toISOString()} (${(q.ageSeconds / 60).toFixed(1)} min, ${snapshot.bidCount} bids)`);
    console.log(`dispersion  ${snapshot.lowestPrice} / ${snapshot.medianPrice} / ${snapshot.highestPrice}`);
    console.log(`quote       ${formatUnits(amount, TOKEN_DECIMALS)} USDC -> ${formatUnits(q.amountOut, TOKEN_DECIMALS)} cNGN @ ${q.rate.toFixed(4)}`);
    return;
  }

  // Read-only commands must never reach for the signer.
  if (command === 'check') {
    const wantAlert = argv.includes('--alert');
    try {
      return await check(config, deps.readClients(config), wantAlert, deps.post, deps.fetchSnapshot);
    } catch (error) {
      // A check that could not RUN is not a quiet check. Unattended, a crash into a log nobody
      // reads is the same failure as an alert that reaches nobody, so a failed run pages exactly
      // like a fired one -- and still exits non-zero so a scheduler's OnFailure can catch it when
      // the webhook is what broke.
      if (wantAlert && config.ALERT_WEBHOOK_URL) {
        const why = String(error instanceof Error ? error.message : error).split('\n')[0];
        const text =
          `cNGN rebalance check FAILED TO RUN (sub ${config.MM_SUBACCOUNT_ID}): ${why}. ` +
          'Inventory is UNKNOWN, not healthy — nothing has been checked.';
        try {
          await deps.post(config.ALERT_WEBHOOK_URL, text);
        } catch (postError) {
          console.error(`failure alert could not be posted: ${String(postError)}`);
        }
      }
      throw error;
    }
  }

  const clients = await deps.signingClients(config);
  switch (command) {
    case 'approve': return approve(config, clients, parseUnits(arg ?? '20', TOKEN_DECIMALS), execute);
    case 'swap': return swap(config, clients, parseUnits(arg ?? '20', TOKEN_DECIMALS), execute);
    case 'cancel': return cancel(config, clients, arg, execute);
    case 'deposit': return deposit(config, clients, arg ? parseUnits(arg, TOKEN_DECIMALS) : undefined, execute);
    default: throw new Error(`unknown command "${command}"\n${USAGE}`);
  }
}

async function main(): Promise<void> {
  await runCommand(process.argv.slice(2), loadConfig());
}

// Only when run as the CLI. Without this guard, importing this module executes main() -- which
// calls loadConfig() and throws before a test can reach anything.
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((e: unknown) => {
    console.error(String(e instanceof Error ? e.message : e));
    process.exit(1);
  });
}
