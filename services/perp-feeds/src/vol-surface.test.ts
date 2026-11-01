import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { annualise, buildSvi, isqrt, lnRatio, ONE, shapeProblem, sviVol, type SurfaceShape } from './vol-surface.js';

// The shape the fork test proves (CngnOptionsV2Fork._publishVolAt): b = 2 x ATM variance, sigma 0.1, rho -0.5.
const SHAPE: SurfaceShape = { bMult: 2n * ONE, rho: -5n * 10n ** 17n, sigma: 10n ** 17n };
const EXPIRY = 1796047200n;
const NOW = EXPIRY - 29n * 86_400n;
const FWD = 721_748_919_677_396n; // the cNGN-30NOV26 forward, USDC per cNGN, 2026-11-01

function build(atmVol = 4n * 10n ** 17n, confidence = ONE) {
  return buildSvi({ expiry: EXPIRY, nowSec: NOW, atmVol, shape: SHAPE, fwd: FWD, confidence });
}

const near = (x: bigint, y: bigint, tol: bigint) => (x > y ? x - y : y - x) <= tol;

describe('vol surface', () => {
  it('annualises exactly as Black76', () => {
    assert.equal(annualise(31_536_000n), ONE);
    assert.equal(annualise(86_400n), 2_739_726_027_397_260n);
  });

  it('reads back the hand-set ATM vol at the forward', () => {
    const p = build();
    assert.equal(p.m, 0n);
    assert.ok(near(sviVol(p, 0n), 4n * 10n ** 17n, 10n ** 12n), `ATM ${sviVol(p, 0n)}`);
  });

  it('skews to the devaluation wing, as the fork test reads it (49% / 40% / 41%)', () => {
    const p = build();
    const down = sviVol(p, lnRatio(8n, 10n));
    const up = sviVol(p, lnRatio(12n, 10n));
    assert.ok(near(down, 491_892_760_187_596_205n, 10n ** 15n), `0.8F ${down}`);
    assert.ok(near(up, 406_656_810_377_455_654n, 10n ** 15n), `1.2F ${up}`);
    assert.ok(down > up);
  });

  it('scales the whole curve with the ATM level (the degrade floor lifts the wings too)', () => {
    const k = lnRatio(8n, 10n);
    const ratio = (sviVol(build(8n * 10n ** 17n), k) * ONE) / sviVol(build(4n * 10n ** 17n), k);
    assert.ok(near(ratio, 2n * ONE, 10n ** 12n), `ratio ${ratio}`);
  });

  it('carries the confidence it is given', () => {
    assert.equal(build(4n * 10n ** 17n, 5n * 10n ** 17n).confidence, 5n * 10n ** 17n);
  });

  it('refuses a passed expiry, a bad level, no forward, or confidence out of range', () => {
    assert.throws(() => buildSvi({ expiry: EXPIRY, nowSec: EXPIRY, atmVol: ONE, shape: SHAPE, fwd: FWD, confidence: ONE }), /has passed/);
    assert.throws(() => build(0n), /ATM vol/);
    assert.throws(() => build(6n * ONE), /ATM vol/);
    assert.throws(() => buildSvi({ expiry: EXPIRY, nowSec: NOW, atmVol: ONE, shape: SHAPE, fwd: 0n, confidence: ONE }), /no forward/);
    assert.throws(() => build(ONE, 0n), /confidence/);
    assert.throws(() => build(ONE, ONE + 1n), /confidence/);
  });

  it('refuses shapes that are not a surface', () => {
    assert.equal(shapeProblem(SHAPE), null);
    assert.match(shapeProblem({ ...SHAPE, rho: ONE }) ?? '', /RHO/);
    assert.match(shapeProblem({ ...SHAPE, sigma: 0n }) ?? '', /SIGMA/);
    assert.match(shapeProblem({ ...SHAPE, bMult: 0n }) ?? '', /B_MULT/);
    assert.match(shapeProblem({ ...SHAPE, bMult: 20n * ONE }) ?? '', /negative/);
  });

  it('takes integer square roots exactly', () => {
    for (const x of [0n, 1n, 2n, 15n, 16n, 17n, 10n ** 36n, 10n ** 36n - 1n]) {
      const r = isqrt(x);
      assert.ok(r * r <= x && (r + 1n) * (r + 1n) > x, `${x}`);
    }
  });
});
