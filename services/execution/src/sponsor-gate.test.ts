import test from 'node:test';
import assert from 'node:assert/strict';

import { parseEther } from 'viem';

import { SponsorGate, receiptCostWei } from './sponsor-gate.js';
import { DepositRejectedError } from './deposit.js';
import { WithdrawalRejectedError } from './withdrawal.js';

function gate(balanceEth: string, opts: { now?: () => number } = {}) {
  const posted: string[] = [];
  let balance = parseEther(balanceEth);
  const g = new SponsorGate({
    subject: 'deposits',
    reject: (message) => new DepositRejectedError(message, undefined, 503),
    minExecutorWei: parseEther('0.006'),
    maxGasWeiPerHour: parseEther('0.002'),
    readBalance: async () => balance,
    alertWebhookUrl: 'https://hooks.example.invalid/x',
    post: async (_u, text) => { posted.push(text); },
    now: opts.now,
  });
  return { g, posted, setBalance: (eth: string) => { balance = parseEther(eth); } };
}

const is503 = (pattern: RegExp) => (e: unknown) => e instanceof DepositRejectedError && e.status === 503 && pattern.test(e.message);

test('deposits pause below the executor floor, naming both amounts, and alert once', async () => {
  const { g, posted } = gate('0.0059');
  await assert.rejects(g.check(), is503(/holds 0\.0059 ETH, below the 0\.006 ETH deposit floor/));
  await assert.rejects(g.check(), is503(/deposit floor/));
  assert.equal(posted.length, 1, 'one alert per pause, not one per refused deposit');
  assert.match(posted[0]!, /^NUMO DEPOSITS PAUSED/);
  assert.match(posted[0]!, /Settlement and withdrawals are unaffected/);
});

test('deposits pass at the floor and above', async () => {
  const { g, posted } = gate('0.006');
  await g.check();
  assert.equal(posted.length, 0);
});

test('gas spent in the last hour pauses deposits at the budget, then recovers as it ages out', async () => {
  let now = 0;
  const { g, posted } = gate('1', { now: () => now });
  g.record(parseEther('0.0015'));
  await g.check(); // 0.0015 < 0.002
  g.record(parseEther('0.0005'));
  await assert.rejects(g.check(), is503(/spent 0\.002 ETH of gas in the last hour, the most allowed \(0\.002 ETH\)/));
  assert.throws(() => g.assertBudget(), is503(/the most allowed/));
  now = 3_600_001;
  await g.check();
  assert.deepEqual(posted.map((p) => p.split('\n')[0]), ['NUMO DEPOSITS PAUSED', 'NUMO DEPOSITS RESUMED']);
});

test('a lasting pause re-alerts hourly, and a change of reason alerts at once', async () => {
  let now = 0;
  const { g, posted, setBalance } = gate('0.001', { now: () => now });
  await assert.rejects(g.check());
  now = 1_800_000;
  await assert.rejects(g.check());
  assert.equal(posted.length, 1, 'not again within the hour');
  now = 3_600_000;
  await assert.rejects(g.check());
  assert.equal(posted.length, 2, 'again after an hour');
  setBalance('1');
  g.record(parseEther('0.003'));
  await assert.rejects(g.check(), is503(/gas in the last hour/));
  assert.equal(posted.length, 3, 'floor -> budget is a new reason');
});

test('watch() reports a floor breach with no deposit to trigger it', async () => {
  const { g, posted } = gate('0.001');
  g.watch(60_000);
  await new Promise((r) => setTimeout(r, 20));
  g.stop();
  assert.equal(posted.length, 1);
  assert.match(posted[0]!, /deposit floor/);
});

test('a receipt costs gasUsed x effectiveGasPrice plus the L1 fee when present', () => {
  assert.equal(receiptCostWei({ gasUsed: 467_000n, effectiveGasPrice: 6_000_000n }), 2_802_000_000_000n);
  assert.equal(receiptCostWei({ gasUsed: 467_000n, effectiveGasPrice: 6_000_000n, l1Fee: 1_000n }), 2_802_000_001_000n);
  assert.equal(receiptCostWei({ gasUsed: 1n, effectiveGasPrice: 1n, l1Fee: '0x10' }), 17n);
});

// ---- withdrawals: their own budget, and no floor

function withdrawalGate(balanceEth: string) {
  const posted: string[] = [];
  const g = new SponsorGate({
    subject: 'withdrawals',
    reject: (message) => new WithdrawalRejectedError(message, undefined, 503),
    maxGasWeiPerHour: parseEther('0.002'),
    readBalance: async () => parseEther(balanceEth),
    alertWebhookUrl: 'https://hooks.example.invalid/x',
    post: async (_u, text) => { posted.push(text); },
  });
  return { g, posted };
}

const withdrawal503 = (pattern: RegExp) => (e: unknown) =>
  e instanceof WithdrawalRejectedError && e.status === 503 && pattern.test(e.message);

test('withdrawals have no executor floor: a nearly empty executor still lets users withdraw', async () => {
  const { g, posted } = withdrawalGate('0.0001');
  await g.check();
  assert.equal(posted.length, 0);
});

test('without a floor the balance is never read, so an unreadable RPC cannot refuse a withdrawal', async () => {
  const g = new SponsorGate({
    subject: 'withdrawals',
    reject: (message) => new WithdrawalRejectedError(message, undefined, 503),
    maxGasWeiPerHour: parseEther('0.002'),
    readBalance: async () => { throw new Error('rpc down'); },
  });
  await g.check();
});

test('withdrawals pause at their own hourly gas budget, with their own alert', async () => {
  const { g, posted } = withdrawalGate('1');
  g.record(parseEther('0.002'));
  await assert.rejects(g.check(), withdrawal503(/^withdrawals are paused: sponsored withdrawals spent 0\.002 ETH/));
  assert.throws(() => g.assertBudget(), withdrawal503(/withdrawals are paused/));
  assert.match(posted[0]!, /^NUMO WITHDRAWALS PAUSED/);
  assert.match(posted[0]!, /Settlement and deposits are unaffected/);
});

test('the deposit and withdrawal budgets are separate', async () => {
  const deposits = gate('1').g;
  const withdrawals = withdrawalGate('1').g;
  deposits.record(parseEther('0.002'));
  await assert.rejects(deposits.check(), is503(/deposits are paused/));
  await withdrawals.check();
});
