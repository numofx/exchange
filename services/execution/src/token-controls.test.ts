import test from 'node:test';
import assert from 'node:assert/strict';

import { tokenControlFailures } from './token-controls.js';

test('a token with no known controls is reported as unwatched rather than passed over', async () => {
  const read = async () => {
    throw new Error('an unknown token must not be read');
  };
  const failures = await tokenControlFailures(read as never, '0x000000000000000000000000000000000000dEaD', [
    { address: '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98', role: 'custody contract' },
  ]);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /no known issuer controls/);
});

// EURC is a Circle FiatToken: its pause and each party's freeze are read from the token itself, as for USDC.
test('EURC is watched, read from the token itself', async () => {
  const EURC = '0x60a3E35Cc302bFA44Cb288Bc5a4F316Fdb1adb42' as const;
  const ESCROW = '0x00000000000000000000000000000000000E0dC0' as const;
  const calls: string[] = [];
  const read = async (address: string, fn: string, args?: readonly unknown[]) => {
    calls.push(`${address.toLowerCase()} ${fn}${args ? ` ${String(args[0]).toLowerCase()}` : ''}`);
    return fn === 'isBlacklisted' && String(args?.[0]).toLowerCase() === ESCROW.toLowerCase();
  };
  const failures = await tokenControlFailures(read as never, EURC, [{ address: ESCROW, role: 'custody contract' }]);
  assert.deepEqual(calls, [`${EURC.toLowerCase()} paused`, `${EURC.toLowerCase()} isBlacklisted ${ESCROW.toLowerCase()}`]);
  assert.equal(failures.length, 1);
  assert.match(failures[0], /EURC's issuer has FROZEN the venue's custody contract/);
});
