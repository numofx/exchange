import { BaseError, HttpRequestError, RpcRequestError, TimeoutError, keccak256 } from 'viem';

import type { NonceTracker } from './nonce-tracker.js';

/**
 * One sponsored transaction from nonce to broadcast, with the nonce accounted for on every path.
 *
 * Signing happens here, not inside viem's writeContract, so a failure can be placed relative to the broadcast:
 *
 *   - before it (fill, estimate, signing): nothing left this process. The nonce is given back -- the next send takes
 *     the same one -- so no gap is left behind.
 *   - the node answers "already known": the transaction is in the mempool. The nonce is used; the hash is returned.
 *   - "nonce too low" / "replacement transaction underpriced": something else holds this nonce. It is used; the
 *     tracker moves past it, and this send fails.
 *   - an HTTP 4xx (rate limit, auth): the server refused the request, nothing was broadcast. The nonce is given back.
 *   - a timeout, a dropped connection or an HTTP 5xx: the transaction may be out. The same signed bytes are sent again (a duplicate
 *     answers "already known"); either way the nonce stays used and the hash is returned for the receipt wait to
 *     settle. Giving it back instead could sign a second transaction with a nonce the first one already took.
 *   - any other rejection (underfunded, invalid): not accepted. The nonce is given back.
 */
export type BroadcastOutcome = 'consumed' | 'taken-elsewhere' | 'transport' | 'rejected';

export function classifyBroadcastError(error: unknown): BroadcastOutcome {
  const text = describe(error);
  if (/already known|known transaction|already imported|ALREADY_EXISTS/i.test(text)) return 'consumed';
  if (/nonce too low|nonce has already been used|replacement transaction underpriced|NONCE_EXPIRED/i.test(text)) {
    return 'taken-elsewhere';
  }
  const walked = error instanceof BaseError ? error.walk((e) => e instanceof RpcRequestError || e instanceof TimeoutError || e instanceof HttpRequestError) : error;
  // A JSON-RPC error body is the node's answer: it saw the request and refused it.
  if (walked instanceof RpcRequestError) return 'rejected';
  // An HTTP 4xx (a rate limit's 429, an auth 401/403) is the server refusing the request before any node took it: nothing
  // was broadcast. Counting it as "may be out" returned a hash no node had and left the nonce ahead of the chain
  // (2026-11-16 23:57, a phantom fill). A 5xx can come from a gateway after the node accepted it, so it stays unknown.
  if (walked instanceof HttpRequestError && walked.status !== undefined && walked.status >= 400 && walked.status < 500) {
    return 'rejected';
  }
  if (walked instanceof TimeoutError || walked instanceof HttpRequestError) return 'transport';
  if (/timed out|timeout|fetch failed|ECONNRESET|ECONNREFUSED|socket hang up|network/i.test(text)) return 'transport';
  return 'rejected';
}

function describe(error: unknown): string {
  if (error instanceof BaseError) return [error.shortMessage, error.details, error.message].filter(Boolean).join(' | ');
  return error instanceof Error ? error.message : String(error);
}

export async function broadcastWithNonce(args: {
  nonces: NonceTracker;
  sign: (nonce: number) => Promise<`0x${string}`>;
  sendRaw: (raw: `0x${string}`) => Promise<unknown>;
  /** Re-sends of the same bytes after a transport failure. */
  resends?: number;
}): Promise<`0x${string}`> {
  const nonce = await args.nonces.take();
  // Throws before anything is broadcast: the tracker is untouched, so this nonce is taken again next time.
  const raw = await args.sign(nonce);
  const hash = keccak256(raw);
  let attempts = 0;
  for (;;) {
    try {
      await args.sendRaw(raw);
      args.nonces.confirm(nonce);
      return hash;
    } catch (error) {
      const outcome = classifyBroadcastError(error);
      if (outcome === 'consumed') {
        args.nonces.confirm(nonce);
        return hash;
      }
      if (outcome === 'taken-elsewhere') {
        args.nonces.confirm(nonce);
        throw error;
      }
      if (outcome === 'transport') {
        if (attempts++ < (args.resends ?? 2)) continue;
        args.nonces.confirm(nonce);
        return hash;
      }
      throw error;
    }
  }
}
