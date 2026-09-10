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

export type CanarySnapshot = {
  enabled: boolean;
  /** null until the first check completes, so "not yet known" is never reported as healthy. */
  ok: boolean | null;
  checked_at: string | null;
  manager: string | null;
  account_ids: number[];
  failures: CanaryFailure[];
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
  /** Injected in tests. */
  postAlert?: (url: string, text: string) => Promise<void>;
  /** Injected in tests; defaults to a viem client over rpcUrl. */
  client?: Pick<PublicClient, 'readContract'>;
  log?: (level: 'info' | 'error', message: string, fields: Record<string, unknown>) => void;
};

export class SettlementCanary {
  private readonly client: Pick<PublicClient, 'readContract'>;
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

    const ok = failures.length === 0;
    const wasOk = this.snapshotValue.ok;
    this.snapshotValue = {
      enabled: true,
      ok,
      checked_at: new Date().toISOString(),
      manager: this.options.manager,
      account_ids: this.options.accountIds,
      failures,
      // Counts checks, not accounts: one bad account for ten checks reads as ten, which is
      // what an alert threshold should be counting.
      consecutive_failures: ok ? 0 : this.snapshotValue.consecutive_failures + 1,
    };

    // One line per check, at a level a log filter can alarm on without parsing prose.
    this.log(ok ? 'info' : 'error', 'settlement_canary', {
      ok,
      manager: this.options.manager,
      failures,
      consecutive_failures: this.snapshotValue.consecutive_failures,
    });

    await this.maybeAlert(ok, wasOk);
    return this.snapshotValue;
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
    if (!brokeNow && !stillBroken && !recovered) return;

    const detail = this.snapshotValue.failures
      .map((f) => `  - subaccount ${f.account_id}: ${f.error}`)
      .join('\n');

    const text = recovered
      ? `NUMO SETTLEMENT CANARY RECOVERED\ngetMargin succeeds again on ${this.options.manager}.`
      : [
          'NUMO SETTLEMENT HALTED',
          'The risk manager cannot price a live subaccount, so on-chain settlement is failing.',
          'Orders will keep matching off-chain and every fill will revert, silently.',
          '',
          `manager: ${this.options.manager}`,
          `consecutive failing checks: ${failures}`,
          detail,
        ].join('\n');

    try {
      await this.postAlert(url, text);
      this.log('info', 'settlement_canary_alert_sent', { recovered, consecutive_failures: failures });
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
