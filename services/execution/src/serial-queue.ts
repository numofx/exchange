/**
 * Runs tasks one at a time, in the order they were queued.
 *
 * The executor EOA has one nonce sequence. Settlements, withdrawals and deposits all send from it, so two sends in
 * flight at once could take the same nonce and one replace or reject the other. Ordering alone is not enough: a
 * load-balanced RPC can report a stale pending count right after a broadcast, so the nonce itself is tracked locally
 * inside this queue (nonce-tracker.ts). A task covers simulate-and-broadcast; waiting for the receipt happens after, once the nonce
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
