import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assessInventory, type InventoryThresholds } from './inventory.js';

/** Subaccount balances are 18dp whatever the token's own decimals are. */
const ledger = (units: number) => BigInt(Math.round(units * 1e6)) * 10n ** 12n;
const RATE = 1368.3155;
const thresholds: InventoryThresholds = { cngnMinShare: 0.35, cngnFloorUsd: 100, haltNetInventoryUsd: 800 };
const SUB = 15n;

test('a balanced, well-funded book asks for nothing', () => {
  // Sub 15's real state on 2026-09-18: 310 USDC and 475,896 cNGN — $310 against $348, cNGN 53%.
  // An earlier version of this check alerted here, on "idle USDC over $200", and would have asked
  // for a conversion that made the imbalance worse. This test exists to keep that fixed.
  const v = assessInventory({ usdc: ledger(310.002), cngn: ledger(475_896.28), rate: RATE }, thresholds, SUB);
  assert.equal(v.action, 'none');
  assert.deepEqual(v.reasons, []);
  assert.ok(v.cngnShare > 0.5, `expected cNGN over half, got ${v.cngnShare}`);
});

test('a book leaning to USDC is due a rebalance', () => {
  // The shape one-directional flow produces: cNGN sold down, USDC piled up.
  const v = assessInventory({ usdc: ledger(500), cngn: ledger(150_000), rate: RATE }, thresholds, SUB);
  assert.equal(v.action, 'rebalance');
  assert.match(v.reasons.join(' '), /cNGN is 18% of inventory, under the 35% floor/);
});

test('a nearly dark bid side is urgent', () => {
  const v = assessInventory({ usdc: ledger(10), cngn: ledger(50_000), rate: RATE }, thresholds, SUB);
  assert.equal(v.action, 'urgent');
  assert.match(v.reasons.join(' '), /bids will go dark/);
});

test('share alone does not raise urgency', () => {
  // Lopsided but with a cNGN side well above the floor: convert, do not page.
  const v = assessInventory({ usdc: ledger(5000), cngn: ledger(500_000), rate: RATE }, thresholds, SUB);
  assert.equal(v.action, 'rebalance');
});

test('warns when USDC approaches the market maker halt', () => {
  const v = assessInventory({ usdc: ledger(700), cngn: ledger(475_896), rate: RATE }, thresholds, SUB);
  assert.match(v.reasons.join(' '), /within 20% of the market maker's \$800 inventory halt/);
});

test('an empty subaccount is empty, not lopsided', () => {
  // Nothing here can fix an unfunded venue, and a 0/0 ratio must not page about it.
  const v = assessInventory({ usdc: 0n, cngn: 0n, rate: RATE }, thresholds, SUB);
  assert.equal(v.action, 'none');
  assert.deepEqual(v.reasons, []);
});

test('says what to do, because the next step cannot be automated', () => {
  const v = assessInventory({ usdc: ledger(500), cngn: ledger(150_000), rate: RATE }, thresholds, SUB);
  assert.match(v.message, /Withdraw USDC from the subaccount/);
  assert.match(v.message, /RUNBOOK\.md/);
});

test('the next step is described as two moves, not a withdrawal to the signer', () => {
  // A withdrawal's data is (asset, amount) with no recipient, so it ALWAYS pays the subaccount
  // owner. The message used to read "withdraw to the rebalance signer", which is an instruction the
  // chain cannot carry out -- the operator is sent looking for an argument that does not exist.
  const v = assessInventory({ usdc: ledger(500), cngn: ledger(150_000), rate: RATE }, thresholds, SUB);
  assert.match(v.message, /pays the owner/);
  assert.match(v.message, /forward it to the rebalance signer/);
  assert.doesNotMatch(v.message, /Withdraw USDC from the subaccount to the rebalance signer/);
});

test('refuses to value the cNGN side without a rate', () => {
  assert.throws(() => assessInventory({ usdc: ledger(250), cngn: ledger(1000), rate: 0 }, thresholds, SUB), /rate must be positive/);
});

test('the cNGN side is valued at the rate, not counted in tokens', () => {
  // 136,832 cNGN is a six-figure token balance and about $100 — the trap this valuation avoids.
  const v = assessInventory({ usdc: ledger(0), cngn: ledger(136_832), rate: RATE }, thresholds, SUB);
  assert.ok(Math.abs(v.cngnUsd - 100) < 1, `expected ~$100, got ${v.cngnUsd}`);
});
