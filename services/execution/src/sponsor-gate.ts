import { formatEther } from 'viem';

/**
 * Whether sponsored transactions of one kind -- deposits, or withdrawals -- may spend the executor's gas right now.
 * Two reasons to pause, both answered with 503:
 *
 *   - floor:  the executor holds less than minExecutorWei. The same EOA settles every trade, so deposits stop well
 *             above the perp pager's low-gas page (0.002 ETH) and settlement always keeps a reserve. Withdrawals have
 *             no floor: a user can always take their money out while the executor can pay for it.
 *   - budget: this kind has spent maxGasWeiPerHour in the last rolling hour, measured from receipts
 *             (gasUsed x effectiveGasPrice, plus Base's L1 data fee when the receipt carries it). Each kind has its
 *             own budget, so a run of deposits cannot lock withdrawals out, or the reverse.
 *
 * A pause posts once to the ops webhook ("NUMO DEPOSITS PAUSED" / "NUMO WITHDRAWALS PAUSED"), again at most hourly
 * while it lasts or when its reason changes, and "... RESUMED" when a later check passes. It is evaluated on every
 * request and, through watch(), on a timer -- so a floor breach is reported even when nobody is depositing.
 */

/** Gas assumed for a transaction whose receipt never came back, so an unknown outcome still counts against the hour. */
export const PROVISIONAL_SPONSORED_GAS = 1_000_000n;

export type GateOptions = {
  /** "deposits" or "withdrawals": names the pause in messages and alerts. */
  subject: 'deposits' | 'withdrawals';
  /** The 503 a paused request is refused with: the subject's own rejection error. */
  reject: (message: string) => Error;
  /** Absent for withdrawals: no floor. */
  minExecutorWei?: bigint;
  maxGasWeiPerHour: bigint;
  readBalance: () => Promise<bigint>;
  alertWebhookUrl?: string;
  post?: (url: string, text: string) => Promise<void>;
  now?: () => number;
  log?: (level: 'info' | 'error', message: string, fields: Record<string, unknown>) => void;
};

type Pause = { kind: 'floor' | 'budget'; message: string };

export class SponsorGate {
  private readonly spends: { at: number; wei: bigint }[] = [];
  private paused: Pause | undefined;
  private lastAlertAt = 0;
  private timer: NodeJS.Timeout | undefined;
  private readonly now: () => number;
  private readonly log: NonNullable<GateOptions['log']>;

  constructor(private readonly opts: GateOptions) {
    this.now = opts.now ?? Date.now;
    this.log = opts.log ?? (() => {});
  }

  /** Gas spent by this kind in the last rolling hour, in wei. */
  spentLastHour(): bigint {
    const cutoff = this.now() - 3_600_000;
    while (this.spends.length > 0 && this.spends[0]!.at < cutoff) this.spends.shift();
    return this.spends.reduce((sum, s) => sum + s.wei, 0n);
  }

  /** Records what a sponsored transaction cost, once its receipt (or its provisional cost) is known. */
  record(wei: bigint): void {
    this.spends.push({ at: this.now(), wei });
  }

  /** Throws the subject's 503 when paused; reports pauses and recoveries. */
  async check(): Promise<void> {
    // Without a floor the balance is irrelevant: not read, so an RPC hiccup there cannot refuse a withdrawal.
    const pause = this.opts.minExecutorWei === undefined ? this.budgetReason() : this.reason(await this.opts.readBalance());
    if (pause) {
      await this.pause(pause);
      throw this.opts.reject(pause.message);
    }
    await this.resume();
  }

  /** The budget half alone, synchronously, for the moment just before a broadcast. */
  assertBudget(): void {
    const pause = this.budgetReason();
    if (pause) {
      void this.pause(pause);
      throw this.opts.reject(pause.message);
    }
  }

  /** Re-evaluates on a timer, so a pause is reported without a deposit to trigger it. Unref'd. */
  watch(intervalMs: number): void {
    const tick = () => this.check().catch(() => {});
    void tick();
    this.timer = setInterval(tick, intervalMs);
    this.timer.unref?.();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
  }

  private reason(balance: bigint): Pause | undefined {
    const floor = this.opts.minExecutorWei!;
    if (balance < floor) {
      return {
        kind: 'floor',
        message:
          `${this.opts.subject} are paused: the executor holds ${formatEther(balance)} ETH, below the ${formatEther(floor)} ETH ` +
          `${this.opts.subject === 'deposits' ? 'deposit' : 'withdrawal'} floor that keeps a gas reserve for settlement; retry later`,
      };
    }
    return this.budgetReason();
  }

  private budgetReason(): Pause | undefined {
    const spent = this.spentLastHour();
    if (spent >= this.opts.maxGasWeiPerHour) {
      return {
        kind: 'budget',
        message:
          `${this.opts.subject} are paused: sponsored ${this.opts.subject} spent ${formatEther(spent)} ETH of gas in the last hour, the most allowed ` +
          `(${formatEther(this.opts.maxGasWeiPerHour)} ETH); retry later`,
      };
    }
    return undefined;
  }

  private async pause(pause: Pause): Promise<void> {
    const changed = this.paused?.kind !== pause.kind;
    const due = this.now() - this.lastAlertAt >= 3_600_000;
    this.paused = pause;
    if (!changed && !due) return;
    this.lastAlertAt = this.now();
    this.log('error', `${this.opts.subject}_paused`, { kind: pause.kind, reason: pause.message });
    const others = this.opts.subject === 'deposits' ? 'withdrawals' : 'deposits';
    await this.alert(`NUMO ${this.opts.subject.toUpperCase()} PAUSED\n${pause.message}\nSettlement and ${others} are unaffected.`);
  }

  private async resume(): Promise<void> {
    if (!this.paused) return;
    const was = this.paused.kind;
    this.paused = undefined;
    this.lastAlertAt = 0;
    this.log('info', `${this.opts.subject}_resumed`, { was });
    await this.alert(`NUMO ${this.opts.subject.toUpperCase()} RESUMED\nThe ${was === 'floor' ? 'executor balance is above the floor' : 'hourly gas budget has room'} again.`);
  }

  private async alert(text: string): Promise<void> {
    const url = this.opts.alertWebhookUrl;
    if (!url) return;
    try {
      await (this.opts.post ?? defaultPost)(url, text);
    } catch (error) {
      this.log('error', `${this.opts.subject}_alert_failed`, { error: error instanceof Error ? error.message : String(error) });
    }
  }
}

/** What a mined transaction cost: L2 execution plus, on Base, the L1 data fee the receipt reports. */
export function receiptCostWei(receipt: { gasUsed: bigint; effectiveGasPrice: bigint; l1Fee?: unknown }): bigint {
  const l1 = receipt.l1Fee;
  const l1Fee = typeof l1 === 'bigint' ? l1 : typeof l1 === 'string' && l1 !== '' ? BigInt(l1) : 0n;
  return receipt.gasUsed * receipt.effectiveGasPrice + l1Fee;
}

async function defaultPost(url: string, text: string): Promise<void> {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text, content: text }),
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) throw new Error(`webhook returned ${response.status}`);
}
