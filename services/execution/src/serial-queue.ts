/**
 * Runs tasks one at a time, in the order they were queued.
 *
 * The executor EOA has one nonce sequence. Settlements and withdrawals both send from it, and viem reads the next
 * nonce from the RPC at send time, so two sends in flight at once can take the same nonce and one replaces or
 * rejects the other. A task covers simulate-and-broadcast; waiting for the receipt happens after, once the nonce
 * is spoken for, so a slow block does not hold up the next send.
 */
export function createSerialQueue() {
  let tail: Promise<unknown> = Promise.resolve();

  return function enqueue<T>(task: () => Promise<T>): Promise<T> {
    const run = tail.then(task);
    // A failed task must not wedge the queue for the tasks behind it.
    tail = run.catch(() => undefined);
    return run;
  };
}
