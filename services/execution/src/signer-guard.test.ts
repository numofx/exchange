import test from 'node:test';
import assert from 'node:assert/strict';

import { SignerNotOwnerError, assertSignerIsOwner, type GuardLog, type SubmittedAction } from './signer-guard.js';

// The live module set on Base, so "module-agnostic" is asserted against the real addresses rather
// than against placeholders.
const DEPOSIT = '0x6540f8d9Eb599b045C05E45cb6a5B1730a806658' as `0x${string}`;
const TRANSFER = '0xEd8f114982FDBb03B70D4AC427bec7A355Cb78e4' as `0x${string}`;
const WITHDRAWAL = '0x0a10AE2f5D2482cE1e43bC309D430B8861C2b5aB' as `0x${string}`;
const LIQUIDATE = '0x25CF912A21e25226F1Bd99E2ADA959cC80dC4338' as `0x${string}`;
const RFQ = '0x8399328AC53a279A3564E49c2cbC82Ce95ee62D3' as `0x${string}`;
const TRADE = '0x12423B366F6F07130961900bE00d05Ea63Acd071' as `0x${string}`;

const OWNER = '0x3448ac0A3283951A2AFD5B3A582329ECA43CB47B' as `0x${string}`;
const OTHER = '0x1661AA54fA390cd916722F971e4A9Fe4c01889fB' as `0x${string}`;

function action(over: Partial<SubmittedAction> = {}): SubmittedAction {
  return { subaccountId: 15n, module: TRADE, owner: OWNER, signer: OWNER, ...over };
}

/** node:assert's throws() returns undefined, so the error has to be caught to be inspected. */
function thrownBy(run: () => void): SignerNotOwnerError {
  try {
    run();
  } catch (error) {
    assert.ok(error instanceof SignerNotOwnerError, `expected SignerNotOwnerError, got ${String(error)}`);
    return error;
  }
  assert.fail('expected a rejection, got none');
}

function capture(): { log: GuardLog; lines: { level: string; message: string; fields: Record<string, unknown> }[] } {
  const lines: { level: string; message: string; fields: Record<string, unknown> }[] = [];
  return { log: (level, message, fields) => lines.push({ level, message, fields }), lines };
}

test('owner-signed actions pass on every live module', () => {
  for (const module of [DEPOSIT, TRANSFER, WITHDRAWAL, LIQUIDATE, RFQ, TRADE]) {
    assertSignerIsOwner([action({ module })], capture().log);
  }
});

test('a non-owner signer is rejected on every live module', () => {
  // The rule is module-agnostic on purpose: a session key registered for this owner would be
  // chain-valid through all six, so a guard that only covered trade or only covered withdrawal
  // would leave the others open.
  for (const module of [DEPOSIT, TRANSFER, WITHDRAWAL, LIQUIDATE, RFQ, TRADE]) {
    assert.throws(() => assertSignerIsOwner([action({ module, signer: OTHER })], capture().log), SignerNotOwnerError);
  }
});

test('an empty action list passes', () => {
  assertSignerIsOwner([], capture().log);
});

test('the first offending action is the one reported', () => {
  const { log, lines } = capture();
  const actions = [action(), action({ module: RFQ, signer: OTHER }), action({ module: TRANSFER, signer: OTHER })];
  const error = thrownBy(() => assertSignerIsOwner(actions, log));
  assert.equal(error.index, 1);
  assert.equal(error.module, RFQ);
  assert.equal(lines.length, 1, 'one refusal, not one per offending action');
});

test('the refusal logs signer, owner and module', () => {
  const { log, lines } = capture();
  assert.throws(() => assertSignerIsOwner([action({ signer: OTHER })], log));
  assert.equal(lines[0]?.level, 'error');
  assert.equal(lines[0]?.message, 'action_signer_not_owner');
  assert.deepEqual(lines[0]?.fields, {
    index: 0,
    owner: OWNER,
    signer: OTHER,
    module: TRADE,
    subaccount_id: '15',
  });
});

test('the error names both addresses, so a log line identifies the key', () => {
  const error = thrownBy(() => assertSignerIsOwner([action({ signer: OTHER })], capture().log));
  assert.equal(error.name, 'SignerNotOwnerError');
  assert.match(error.message, new RegExp(OTHER));
  assert.match(error.message, new RegExp(OWNER));
});

test('addresses are compared checksum-insensitively', () => {
  // Both builders run getAddress, but a differing case must never read as a different signer.
  assertSignerIsOwner([action({ owner: OWNER.toLowerCase() as `0x${string}` })], capture().log);
});
