/**
 * Every token the venue holds in custody can be stopped by its issuer: the whole token paused, or one address frozen.
 * Either stops every deposit and withdrawal of that token, for every holder, and nothing on the venue's side changes
 * when it happens -- the first anyone would hear of it is a trader's failed withdrawal, reported in the token's own
 * words ("Blacklistable: account is blacklisted" from USDC for any party; "Sender is blacklisted" from cNGN, meaning
 * the venue's escrow on a withdrawal). The canary reads the issuers' state directly so it pages first.
 *
 * Which addresses matter was established on a Base fork (2026-10-10) by freezing each in turn: the wrapped asset
 * contract (both directions) and the DepositModule (deposits). Matching and the executor are never a transfer party.
 * cNGN's admin contract has its own pause, which does not stop transfers, so it is not read. markets-service makes the
 * same reads per request (internal/api/token_controls.go) to tell a trader which it is.
 */
export type TokenControl = { symbol: string; blacklist: `0x${string}`; fn: 'isBlacklisted' | 'isBlackListed' };

/** By lowercased token address on Base. A token not listed has no known controls, and is reported as unwatched. */
export const TOKEN_CONTROLS: Record<string, TokenControl> = {
  '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913': { symbol: 'USDC', blacklist: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913', fn: 'isBlacklisted' },
  '0x46c85152bfe9f96829aa94755d9f915f9b10ef5f': { symbol: 'cNGN', blacklist: '0x2a7483194a651b398582c9a935f793ec2dee2fa7', fn: 'isBlackListed' },
};

export const TOKEN_CONTROLS_ABI = [
  { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'isBlacklisted', stateMutability: 'view', inputs: [{ name: 'account', type: 'address' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'isBlackListed', stateMutability: 'view', inputs: [{ name: 'account', type: 'address' }], outputs: [{ type: 'bool' }] },
] as const;

type Read = <T>(address: `0x${string}`, functionName: string, args?: readonly unknown[]) => Promise<T>;

/** One line per stop on `token`, for the venue's own `parties`; empty when the token moves freely. */
export async function tokenControlFailures(
  read: Read,
  token: `0x${string}`,
  parties: readonly { address: `0x${string}`; role: string }[],
): Promise<string[]> {
  const control = TOKEN_CONTROLS[token.toLowerCase()];
  if (!control) return [`token ${token} has no known issuer controls; a pause or freeze on it would not be caught`];
  const out: string[] = [];
  if (await read<boolean>(token, 'paused')) {
    out.push(`${control.symbol} (${token}) is PAUSED by its issuer: no ${control.symbol} deposit or withdrawal can succeed`);
  }
  for (const party of parties) {
    if (await read<boolean>(control.blacklist, control.fn, [party.address])) {
      out.push(
        `${control.symbol}'s issuer has FROZEN the venue's ${party.role} ${party.address}: ` +
          `${control.symbol} deposits${party.role === 'deposit module' ? '' : ' and withdrawals'} through it revert for everyone`,
      );
    }
  }
  return out;
}
