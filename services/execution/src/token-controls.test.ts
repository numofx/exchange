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
