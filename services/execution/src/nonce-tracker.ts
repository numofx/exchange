/**
 * The executor's next nonce, kept locally rather than asked of the RPC on every send.
 *
 * serial-queue.ts already sends one transaction at a time, but viem reads the nonce from the RPC (`pending`) at send
 * time, and the RPC is load-balanced: the node that answers may not have seen the transaction broadcast a moment
 * earlier, and returns the same count. The second of two back-to-back settlements then reuses the first's nonce and
 * is rejected ("Missing or invalid parameters"). On 2026-10-09 this lost 8 of 22 fills in a burst on
 * execution:2478d1188563 -- each a taker crossing several maker orders at once.
 *
 * The nonce used is the higher of what this process last broadcast (+1) and the chain's pending count: a lagging node
 * can no longer hand out a used nonce, and a transaction sent from the same key by anything else is still respected.
 * Only confirm() advances it; broadcast.ts decides, per failure, whether a nonce was used (confirm) or given back
 * (nothing), so a failure before the broadcast never leaves a gap.
 *
 * Not safe on its own across concurrent callers: every take/confirm/forget runs inside the executor's serial queue.
 */
export class NonceTracker {
  private next: number | undefined;

  constructor(private readonly readPending: () => Promise<number>) {}

  async take(): Promise<number> {
    const chain = await this.readPending();
    return this.next === undefined ? chain : Math.max(this.next, chain);
  }

  /** This nonce is used: broadcast, or found taken. */
  confirm(nonce: number): void {
    this.next = nonce + 1;
  }
}
