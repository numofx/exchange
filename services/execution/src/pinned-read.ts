/**
 * Reads that must see a transaction this executor has just mined.
 *
 * The RPC is load-balanced: the node that returned a receipt is not necessarily the one that answers the next call,
 * and a call at "latest" on a node that has not yet imported the receipt's block reads the state before it. That is
 * how a deposit carrying a permit was refused in production for "ERC20: transfer amount exceeds allowance" with the
 * permit already mined. Pinning the read to the receipt's block makes it exact: a node that has the block answers
 * with it, and one that does not refuses the block outright, which is retried here, rather than answering stale.
 */

// How nodes say they do not have a block yet: geth/op-geth "header not found", reth "block not found" or
// "unknown block", Alchemy and others in their own words.
const MISSING_BLOCK = /header not found|block not found|unknown block|block .*not (?:yet )?available|requested block .*ahead/i;

export function isMissingBlock(error: unknown): boolean {
  for (let cause: unknown = error; cause instanceof Error; cause = (cause as { cause?: unknown }).cause) {
    const details = (cause as { details?: unknown }).details;
    if (MISSING_BLOCK.test(cause.message) || (typeof details === 'string' && MISSING_BLOCK.test(details))) return true;
  }
  return false;
}

/**
 * Runs `read` at `block`, or at "latest" when there is no block to wait for. While the node answering has not got the
 * block, retries every `delayMs`, `attempts` times in all; any other outcome, a revert included, is returned or thrown
 * as it is, because a read pinned to a block cannot change by asking again.
 */
export async function readAtOrAfter<T>(
  block: bigint | undefined,
  read: (at: { blockNumber?: bigint }) => Promise<T>,
  { attempts = 15, delayMs = 1_000 }: { attempts?: number; delayMs?: number } = {},
): Promise<T> {
  if (block === undefined) return read({});
  for (let attempt = 1; ; attempt++) {
    try {
      return await read({ blockNumber: block });
    } catch (error) {
      if (attempt >= attempts || !isMissingBlock(error)) throw error;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}
