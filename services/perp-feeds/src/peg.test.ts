import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { pegMid, pegReading } from './peg.js';

const rules = { windowMs: 15 * 60_000, maxAgeMs: 15 * 60_000, maxSpreadBps: 50, guardBps: 100 };
const now = 1_000_000_000;

describe('pegMid', () => {
  it('takes the mid of a tight two-sided book', () => {
    assert.deepEqual(pegMid({ buy: 0.9999, sell: 1.0001 }, 50), { ok: true, mid: 1 });
  });
  it('refuses a one-sided, crossed, or wide book, and a zero print', () => {
    assert.equal(pegMid({ buy: 0, sell: 1.0001 }, 50).ok, false); // Quidax served a 0.0 close in September
    assert.equal(pegMid({ buy: 1.001, sell: 1.0 }, 50).ok, false);
    assert.equal(pegMid({ buy: 0.99, sell: 1.01 }, 50).ok, false);
  });
});

describe('pegReading', () => {
  it('is a time-weighted average of the sampled mids, not the last one', () => {
    const reading = pegReading([{ price: 1.0, at: now - 10 * 60_000 }, { price: 1.004, at: now - 60_000 }], now, rules);
    assert.ok(reading.ok);
    // 1.0 stood 9 minutes, 1.004 the last 1: (9 x 1.0 + 1 x 1.004) / 10
    assert.ok(reading.ok && Math.abs(reading.ngnPerCngn - 1.0004) < 1e-12);
    assert.ok(reading.ok && !reading.guardTripped);
  });
  it('lets the last good peg stand for 15 minutes, then reports it unavailable', () => {
    assert.ok(pegReading([{ price: 1, at: now - 14 * 60_000 }], now, rules).ok);
    const stale = pegReading([{ price: 1, at: now - 16 * 60_000 }], now, rules);
    assert.equal(stale.ok, false);
    assert.match(!stale.ok ? stale.reason : '', /peg unavailable/);
  });
  it('trips the guard past 100bps from parity', () => {
    const reading = pegReading([{ price: 0.985, at: now - 60_000 }], now, rules);
    assert.ok(reading.ok && reading.guardTripped && reading.deviationBps > 100);
  });
});
