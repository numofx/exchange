import assert from 'node:assert/strict';
import test from 'node:test';

import { loadConfig } from './config.js';

const BASE_ENV = {
  RPC_URL: 'https://example.invalid/rpc',
  PRIVATE_KEY: `0x${'11'.repeat(32)}`,
  CHAIN_ID: '8453',
};

const MANAGER = '0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b';

function withEnv<T>(extra: Record<string, string | undefined>, fn: () => T): T {
  const keys = [
    ...Object.keys(BASE_ENV),
    'SETTLEMENT_CANARY_MANAGER',
    'SETTLEMENT_CANARY_ACCOUNTS',
    'SETTLEMENT_CANARY_INTERVAL_MS',
    'SETTLEMENT_CANARY_FAILS_HEALTHCHECK',
    'SETTLEMENT_CANARY_FEE_SUBACCOUNT',
    'SETTLEMENT_CANARY_FEE_OWNER',
    'SETTLEMENT_CANARY_FEE_MODULE',
    'SETTLEMENT_CANARY_FEE_QUOTE_ASSET',
  ];
  const saved = Object.fromEntries(keys.map((k) => [k, process.env[k]]));
  Object.assign(process.env, BASE_ENV);
  for (const [k, v] of Object.entries(extra)) {
    if (v === undefined) delete process.env[k];
    else process.env[k] = v;
  }
  try {
    return fn();
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k];
      else process.env[k] = v;
    }
  }
}

test('no manager means no canary, not an empty one', () => {
  const config = withEnv({ SETTLEMENT_CANARY_MANAGER: undefined }, loadConfig);
  assert.equal(config.settlementCanary, undefined);
});

test('a manager with accounts is parsed and checksummed', () => {
  const config = withEnv(
    { SETTLEMENT_CANARY_MANAGER: MANAGER.toLowerCase(), SETTLEMENT_CANARY_ACCOUNTS: '15, 16' },
    loadConfig,
  );
  assert.equal(config.settlementCanary?.manager, MANAGER);
  assert.deepEqual(config.settlementCanary?.accountIds, [15, 16]);
  assert.equal(config.settlementCanary?.intervalMs, 60_000);
  assert.equal(config.settlementCanary?.failsHealthcheck, false);
});

// The whole point of the canary is that it checks something. A configuration that would
// report healthy while checking nothing must not start.
test('a manager with no accounts is a startup failure', () => {
  assert.throws(
    () => withEnv({ SETTLEMENT_CANARY_MANAGER: MANAGER, SETTLEMENT_CANARY_ACCOUNTS: '' }, loadConfig),
    /SETTLEMENT_CANARY_ACCOUNTS is empty/,
  );
});

test('a malformed account id is a startup failure, not a silently dropped entry', () => {
  assert.throws(
    () => withEnv({ SETTLEMENT_CANARY_MANAGER: MANAGER, SETTLEMENT_CANARY_ACCOUNTS: '15,fifteen' }, loadConfig),
    /"fifteen" is not a subaccount id/,
  );
});

test('failsHealthcheck is opt-in', () => {
  const config = withEnv(
    {
      SETTLEMENT_CANARY_MANAGER: MANAGER,
      SETTLEMENT_CANARY_ACCOUNTS: '15',
      SETTLEMENT_CANARY_FAILS_HEALTHCHECK: 'true',
    },
    loadConfig,
  );
  assert.equal(config.settlementCanary?.failsHealthcheck, true);
});

// All four or none: a partially configured fee check looks configured while checking nothing.
test('fee recipient config requires all four values together', () => {
  assert.throws(
    () =>
      withEnv(
        {
          SETTLEMENT_CANARY_MANAGER: MANAGER,
          SETTLEMENT_CANARY_ACCOUNTS: '15',
          SETTLEMENT_CANARY_FEE_SUBACCOUNT: '99',
        },
        loadConfig,
      ),
    /must be set together/,
  );
});

test('no fee recipient config at all is fine', () => {
  const config = withEnv(
    { SETTLEMENT_CANARY_MANAGER: MANAGER, SETTLEMENT_CANARY_ACCOUNTS: '15' },
    loadConfig,
  );
  assert.equal(config.settlementCanary?.feeRecipient, undefined);
});
