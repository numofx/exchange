import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { withGasHeadroom } from './executor.js';

describe('withGasHeadroom', () => {
  it('covers the perp cash accrual path a block after the estimate (+48% measured)', () => {
    // CngnPerpStackFork: 122,902 gas estimated on the touching block, 181,787 a block later.
    assert.ok(withGasHeadroom(122_902n) >= 181_787n);
  });

  it('adds at least a fixed amount on small calls, where a percentage is thin', () => {
    assert.equal(withGasHeadroom(60_000n), 160_000n);
    assert.equal(withGasHeadroom(1_000_000n), 1_500_000n);
  });
});
