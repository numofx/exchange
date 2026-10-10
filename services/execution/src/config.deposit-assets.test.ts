import test from 'node:test';
import assert from 'node:assert/strict';

import { parseDepositAssets } from './config.js';

const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272';
const ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98';

test('DEPOSIT_ASSETS gives each asset its symbol and its own minimum', () => {
  assert.deepEqual(parseDepositAssets(`${CASH.toLowerCase()}:USDC:10000000, ${ESCROW}:cNGN:15000000000`, [], 1n), [
    { address: CASH, symbol: 'USDC', minAmount: 10_000_000n },
    { address: ESCROW, symbol: 'cNGN', minAmount: 15_000_000_000n },
  ]);
});

test('without DEPOSIT_ASSETS the older address list and minimum still mean USDC', () => {
  assert.deepEqual(parseDepositAssets('', [CASH], 10_000_000n), [{ address: CASH, symbol: 'USDC', minAmount: 10_000_000n }]);
});

test('a malformed entry stops the process rather than serving a guessed policy', () => {
  for (const spec of [`${CASH}:USDC`, `nope:USDC:1`, `${CASH}::1`, `${CASH}:USDC:0`, `${CASH}:USDC:1.5`, `${CASH}:USDC:1,${CASH.toLowerCase()}:USDC:2`]) {
    assert.throws(() => parseDepositAssets(spec, [], 1n), /DEPOSIT_ASSETS/, spec);
  }
});
