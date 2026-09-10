import { createPublicClient, defineChain, http, type PublicClient } from 'viem';

/**
 * Periodically asks the risk manager to price a real subaccount.
 *
 * The failure this exists to catch is a *silent* one. On 2026-09-01 the feed signer ran
 * out of gas, the spot feed went stale, and every settlement reverted `BLF_DataTooOld` for
 * 6.8 days without anything noticing: the services were healthy, the API answered, orders
 * matched, and only the on-chain leg failed. It was found by accident.
 *
 * `getMargin` is the cheapest call that walks the same path a settlement does — it reads
 * every spot feed for every market the account holds a position in — so a revert here means
 * the book cannot settle, whatever the reason. That is strictly more than a feed-staleness
 * check: a bad feed repoint, a market misconfiguration or a paused asset all surface too.
 *
 * Deliberately NOT part of container liveness by default. A stale oracle is not fixed by
 * restarting this process, and failing the ALB health check over one would take the API
 * down and flap tasks while the real problem sits off-box. See SETTLEMENT_CANARY_FAILS_HEALTHCHECK.
 */

const INVARIANT_ABI = [
  { type: 'function', name: 'cashAsset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'wrappedAsset', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'decimals', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  {
    type: 'function', name: 'balanceOf', stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }], outputs: [{ type: 'uint256' }],
  },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalBorrow', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'netSettledCash', stateMutability: 'view', inputs: [], outputs: [{ type: 'int256' }] },
  {
    type: 'function', name: 'totalPosition', stateMutability: 'view',
    inputs: [{ name: 'manager', type: 'address' }], outputs: [{ type: 'uint256' }],
  },
] as const;

const ASSET_WHITELISTED_EVENT = {
  type: 'event',
  name: 'AssetWhitelisted',
  inputs: [
    { name: 'asset', type: 'address', indexed: false },
    { name: 'marketId', type: 'uint256', indexed: false },
    { name: 'assetType', type: 'uint8', indexed: false },
  ],
} as const;

const GET_MARGIN_ABI = [
  {
    type: 'function',
    name: 'getMargin',
    stateMutability: 'view',
    inputs: [
      { name: 'accountId', type: 'uint256' },
      { name: 'isInitial', type: 'bool' },
    ],
    outputs: [{ name: 'margin', type: 'int256' }],
  },
] as const;

export type CanaryFailure = { account_id: number; error: string };

/**
 * A token balance in its native decimals, restated at the 18dp the ledgers use. Both tokens
 * here are 6dp while every ledger figure is 18dp, so comparing raw numbers would make a
 * fully-backed wrapper look 1e12 short. The scaling is the check.
 */
export function to18(amount: bigint, decimals: number): bigint {
  if (decimals > 18) throw new Error(`token has ${decimals} decimals; refusing to round down to 18`);
  return amount * 10n ** BigInt(18 - decimals);
}

function fmt(v: bigint): string {
  const neg = v < 0n;
  const a = neg ? -v : v;
  return `${neg ? '-' : ''}${a / 10n ** 18n}.${(a % 10n ** 18n).toString().padStart(18, '0').slice(0, 6)}`;
}

export type CanarySnapshot = {
  enabled: boolean;
  /** null until the first check completes, so "not yet known" is never reported as healthy. */
  ok: boolean | null;
  checked_at: string | null;
  manager: string | null;
  account_ids: number[];
  failures: CanaryFailure[];
  /**
   * Solvency, kept separate from `failures` on purpose. A margin failure means the venue cannot
   * settle and is loud on its own. A backing failure means it still can -- against collateral
   * that is not there, which is worse and reads completely differently to whoever is woken up.
   */
  invariant_failures: string[];
  consecutive_failures: number;
};

export type CanaryOptions = {
  rpcUrl: string;
  chainId: number;
  manager: `0x${string}`;
  accountIds: number[];
  intervalMs: number;
  /** Slack/Discord-compatible webhook. Without it the canary logs and reaches nobody. */
  alertWebhookUrl?: string;
  /**
   * Re-alert after this many consecutive failing checks, so a single dropped webhook does not
   * mean silence for the whole outage. 0 disables repeats.
   */
  alertRepeatAfterChecks?: number;
  /**
   * Send one notice on the first check after start-up, whatever the result.
   *
   * Found by drill, not by reasoning: an outage fixed by a redeploy produces NO recovery message,
   * because recovery is a within-process transition and the fixed process starts with ok = null.
   * The operator sees HALTED and then silence, which is the ambiguity the recovery message exists
   * to remove. Since the usual repair for a halted venue IS a redeploy, that gap swallowed the
   * common case. One line per deploy is the price of never having to wonder.
   */
  announceOnStart?: boolean;
  /** Injected in tests. */
  postAlert?: (url: string, text: string) => Promise<void>;
  /** Injected in tests; defaults to a viem client over rpcUrl. */
  client?: Pick<PublicClient, 'readContract' | 'getLogs'>;
  log?: (level: 'info' | 'error', message: string, fields: Record<string, unknown>) => void;
};

export class SettlementCanary {
  private readonly client: Pick<PublicClient, 'readContract' | 'getLogs'>;
  /** Discovered once: the whitelist does not change between checks, and a log scan every 60s would. */
  private wrappers: `0x${string}`[] | undefined;
  private readonly log: NonNullable<CanaryOptions['log']>;
  private readonly postAlert: NonNullable<CanaryOptions['postAlert']>;
  private timer: NodeJS.Timeout | undefined;
  private snapshotValue: CanarySnapshot;

  constructor(private readonly options: CanaryOptions) {
    this.client =
      options.client ??
      createPublicClient({
        chain: defineChain({
          id: options.chainId,
          name: `chain-${options.chainId}`,
          nativeCurrency: { name: 'Native', symbol: 'ETH', decimals: 18 },
          rpcUrls: { default: { http: [options.rpcUrl] } },
        }),
        transport: http(options.rpcUrl),
      });
    this.log = options.log ?? (() => {});
    this.postAlert = options.postAlert ?? defaultPostAlert;
    this.snapshotValue = {
      enabled: true,
      ok: null,
      checked_at: null,
      manager: options.manager,
      account_ids: options.accountIds,
      failures: [],
      invariant_failures: [],
      consecutive_failures: 0,
    };
  }

  snapshot(): CanarySnapshot {
    return this.snapshotValue;
  }

  /** Runs one check immediately, then every intervalMs. Unref'd so it never holds the process open. */
  start(): void {
    void this.check();
    this.timer = setInterval(() => void this.check(), this.options.intervalMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
  }

  async check(): Promise<CanarySnapshot> {
    const failures: CanaryFailure[] = [];

    for (const accountId of this.options.accountIds) {
      try {
        await this.client.readContract({
          address: this.options.manager,
          abi: GET_MARGIN_ABI,
          functionName: 'getMargin',
          args: [BigInt(accountId), true],
        });
      } catch (error) {
        failures.push({ account_id: accountId, error: describe(error) });
      }
    }

    const invariant_failures = await this.checkInvariants();
    const ok = failures.length === 0 && invariant_failures.length === 0;
    const wasOk = this.snapshotValue.ok;
    this.snapshotValue = {
      enabled: true,
      ok,
      checked_at: new Date().toISOString(),
      manager: this.options.manager,
      account_ids: this.options.accountIds,
      failures,
      invariant_failures,
      // Counts checks, not accounts: one bad account for ten checks reads as ten, which is
      // what an alert threshold should be counting.
      consecutive_failures: ok ? 0 : this.snapshotValue.consecutive_failures + 1,
    };

    // One line per check, at a level a log filter can alarm on without parsing prose.
    this.log(ok ? 'info' : 'error', 'settlement_canary', {
      ok,
      manager: this.options.manager,
      failures,
      invariant_failures,
      consecutive_failures: this.snapshotValue.consecutive_failures,
    });

    await this.maybeAlert(ok, wasOk);
    return this.snapshotValue;
  }

  /**
   * Solvency invariants. Read-only, and independent of whether anything can be priced:
   *
   *   1. Every unit of cash is backed by a real token in the CashAsset, nothing borrowed, and
   *      nothing manager-printed. netSettledCash is CashAsset's own name for the credited-not-
   *      deposited component of totalSupply, so a non-zero value is exactly that.
   *   2. A WrappedERC20Asset mints on deposit and burns on withdraw, so its real token balance
   *      must equal the position it has credited. Any divergence means tokens entered or left
   *      without going through deposit()/withdraw().
   *
   * Wrappers are discovered from AssetWhitelisted rather than configured, so a new market is
   * covered without a redeploy. totalPosition is per-manager and the manager set is not
   * enumerable on chain, so this compares against the configured manager: another manager
   * holding a position makes the check go RED rather than silently pass.
   */
  private async checkInvariants(): Promise<string[]> {
    const out: string[] = [];
    // viem infers functionName/args from the ABI literal; this call site is deliberately generic
    // over eight zero- and one-argument view functions, so the cast is at the boundary only.
    const read = <T>(address: `0x${string}`, functionName: string, args: readonly unknown[] = []) =>
      (this.client.readContract as (a: unknown) => Promise<unknown>)({
        address,
        abi: INVARIANT_ABI,
        functionName,
        args,
      }) as Promise<T>;

    try {
      const cash = await read<`0x${string}`>(this.options.manager, 'cashAsset');
      const token = await read<`0x${string}`>(cash, 'wrappedAsset');
      const decimals = await read<number>(token, 'decimals');
      const held = to18(await read<bigint>(token, 'balanceOf', [cash]), decimals);
      const supply = await read<bigint>(cash, 'totalSupply');
      const borrow = await read<bigint>(cash, 'totalBorrow');
      const settled = await read<bigint>(cash, 'netSettledCash');

      if (held < supply) {
        out.push(
          `cash ${cash} UNDER-BACKED: holds ${fmt(held)} against ${fmt(supply)} of cash supply ` +
            `(short ${fmt(supply - held)})`,
        );
      }
      if (borrow !== 0n) out.push(`cash ${cash} totalBorrow is ${fmt(borrow)}, expected 0`);
      if (settled !== 0n) {
        out.push(
          `cash ${cash} netSettledCash is ${fmt(settled)}, expected 0 — that much cash was ` +
            'credited by a manager rather than deposited',
        );
      }
    } catch (error) {
      out.push(`cash backing check failed to run: ${describe(error)}`);
    }

    try {
      if (!this.wrappers) {
        const logs = await this.client.getLogs({
          address: this.options.manager,
          event: ASSET_WHITELISTED_EVENT,
          fromBlock: 0n,
          toBlock: 'latest',
        });
        this.wrappers = [
          ...new Set(logs.map((l) => (l as { args: { asset: `0x${string}` } }).args.asset)),
        ];
      }
      for (const asset of this.wrappers) {
        let token: `0x${string}`;
        let decimals: number;
        try {
          token = await read<`0x${string}`>(asset, 'wrappedAsset');
          decimals = await read<number>(token, 'decimals');
        } catch {
          continue; // not a wrapper; nothing to compare
        }
        const held = to18(await read<bigint>(token, 'balanceOf', [asset]), decimals);
        const credited = await read<bigint>(asset, 'totalPosition', [this.options.manager]);
        if (held !== credited) {
          out.push(
            `wrapper ${asset} BACKING MISMATCH: holds ${fmt(held)} of ${token} but has credited ` +
              `${fmt(credited)} (delta ${fmt(held - credited)}) — tokens moved without deposit()/withdraw()`,
          );
        }
      }
    } catch (error) {
      out.push(`wrapper backing check failed to run: ${describe(error)}`);
    }

    return out;
  }

  /**
   * Edge-triggered, not level-triggered: one message when it breaks, one when it recovers, and a
   * repeat every alertRepeatAfterChecks while it stays broken. A message every interval would be
   * ignored within the hour, which is the same as not sending one.
   *
   * Never throws. A webhook that is down must not stop the canary checking; the log line is still
   * emitted either way.
   */
  private async maybeAlert(ok: boolean, wasOk: boolean | null): Promise<void> {
    const url = this.options.alertWebhookUrl;
    if (!url) return;

    const repeatAfter = this.options.alertRepeatAfterChecks ?? 30;
    const failures = this.snapshotValue.consecutive_failures;

    // wasOk === null is the first check of the process. A failure there is still worth sending:
    // starting up broken is exactly the case where nobody is watching yet.
    const brokeNow = !ok && (wasOk === true || wasOk === null);
    const stillBroken = !ok && repeatAfter > 0 && failures > 1 && failures % repeatAfter === 0;
    const recovered = ok && wasOk === false;
    // A healthy first check. Only worth sending because the alternative is silence after a
    // redeploy-shaped recovery -- see announceOnStart.
    const announced = ok && wasOk === null && (this.options.announceOnStart ?? true);
    if (!brokeNow && !stillBroken && !recovered && !announced) return;

    const detail = this.snapshotValue.failures
      .map((f) => `  - subaccount ${f.account_id}: ${f.error}`)
      .join('\n');
    const invariantDetail = this.snapshotValue.invariant_failures.map((f) => `  - ${f}`).join('\n');
    // Two different emergencies. A halt stops trading and is loud on its own; a backing failure
    // lets trading continue against collateral that is not there.
    const halted = this.snapshotValue.failures.length > 0;

    const text = announced
      ? `NUMO SETTLEMENT CANARY STARTED\ngetMargin succeeds on ${this.options.manager}. Watching subaccount(s) ${this.options.accountIds.join(', ')}.`
      : recovered
      ? `NUMO SETTLEMENT CANARY RECOVERED\ngetMargin succeeds again on ${this.options.manager}.`
      : [
          halted ? 'NUMO SETTLEMENT HALTED' : 'NUMO COLLATERAL BACKING FAILURE',
          halted
            ? 'The risk manager cannot price a live subaccount, so on-chain settlement is failing.\nOrders will keep matching off-chain and every fill will revert, silently.'
            : 'The venue can still price and settle — and that is the problem. Ledger balances are\nnot matched by the tokens behind them, so fills continue against collateral that is\nnot there.',
          '',
          `manager: ${this.options.manager}`,
          `consecutive failing checks: ${failures}`,
          [detail, invariantDetail].filter(Boolean).join('\n'),
        ].join('\n');

    try {
      await this.postAlert(url, text);
      this.log('info', 'settlement_canary_alert_sent', { recovered, announced, consecutive_failures: failures });
    } catch (error) {
      this.log('error', 'settlement_canary_alert_failed', { error: describe(error) });
    }
  }
}

async function defaultPostAlert(url: string, text: string): Promise<void> {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    // Both keys on purpose: Slack reads `text`, Discord reads `content`. The ops-box alert
    // scripts post the same shape, so one webhook serves both senders.
    body: JSON.stringify({ text, content: text }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`webhook returned ${response.status}`);
}

export const DISABLED_CANARY: CanarySnapshot = {
  enabled: false,
  ok: null,
  checked_at: null,
  manager: null,
  account_ids: [],
  failures: [],
  invariant_failures: [],
  consecutive_failures: 0,
};

/**
 * viem wraps a revert in several layers of prose. Keep the useful parts and drop the rest:
 * a health payload that embeds a multi-line stack is one nobody reads.
 */
function describe(error: unknown): string {
  if (!(error instanceof Error)) return String(error);
  const selector = /0x[0-9a-fA-F]{8}\b/.exec(error.message)?.[0];
  const named = /reverted with (?:the following reason|custom error):\s*\n?(.+)/.exec(error.message)?.[1];
  const first = error.message.split('\n')[0]!.trim();
  return [named?.trim() ?? first, selector && !(named ?? first).includes(selector) ? `(${selector})` : '']
    .filter(Boolean)
    .join(' ')
    .slice(0, 300);
}
