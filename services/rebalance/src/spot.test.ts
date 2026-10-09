import test from 'node:test';
import assert from 'node:assert/strict';

import { resolveSpotVenue, type FetchMarkets } from './spot.js';

const ESCROW = '0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98';
const CASH = '0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272';
const MANAGER = '0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4';
const OLD_MANAGER = '0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b';

const spot = { contract_type: 'spot', base_asset_symbol: 'cNGN', asset_address: ESCROW, quote_asset_address: CASH, margin_manager_address: MANAGER };
const perp = { contract_type: 'perpetual', base_asset_symbol: 'cNGN', asset_address: '0xC74EfC8B4808803dBCF439E76Fde076d56625b8E', quote_asset_address: CASH, margin_manager_address: MANAGER };
const markets = (...m: object[]): FetchMarkets => async () => m;

/** The live chain as of 2026-10-09: 26 under the perp SRM, 15 under the retired spot manager. */
function chain(o: { whitelisted?: boolean; cash?: string } = {}) {
  return {
    readContract: async (a: { functionName: string; args?: readonly unknown[] }) => {
      switch (a.functionName) {
        case 'manager': return a.args?.[0] === 15n ? OLD_MANAGER : MANAGER;
        case 'assetDetails': return { isWhitelisted: o.whitelisted ?? true, assetType: 3, marketId: 1n };
        case 'cashAsset': return o.cash ?? CASH;
        default: throw new Error(`unexpected call ${a.functionName}`);
      }
    },
  } as never;
}

test('account 26 resolves to the spot market the venue serves', async () => {
  const v = await resolveSpotVenue('http://venue', 26n, chain(), markets(perp, spot));
  assert.deepEqual(v, { cngnEscrow: ESCROW, quoteAsset: CASH, manager: MANAGER });
});

// The defect this module exists for: the old default, 15, sits on the retired stack.
test('a subaccount under a different manager is refused, naming both', async () => {
  await assert.rejects(resolveSpotVenue('http://venue', 15n, chain(), markets(spot)), (e: Error) =>
    e.message.includes(OLD_MANAGER) && e.message.includes(MANAGER));
});

// The API names the deposit target; a response pointing anywhere the manager does not recognise
// must not become a transfer.
test('an escrow the manager has not whitelisted is refused', async () => {
  await assert.rejects(resolveSpotVenue('http://venue', 26n, chain({ whitelisted: false }), markets(spot)), /not whitelisted/);
});

test('a quote asset that is not the manager cash is refused', async () => {
  await assert.rejects(
    resolveSpotVenue('http://venue', 26n, chain({ cash: '0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84' }), markets(spot)),
    /quotes in/,
  );
});

test('no spot market, or more than one, is refused rather than guessed', async () => {
  await assert.rejects(resolveSpotVenue('http://venue', 26n, chain(), markets(perp)), /found 0/);
  await assert.rejects(resolveSpotVenue('http://venue', 26n, chain(), markets(spot, spot)), /found 2/);
});
