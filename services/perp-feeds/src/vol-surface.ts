/**
 * The cNGN options' vol surface: a hand-set SVI per expiry (decided 2026-11-01: ATM vol set by governance, realised-vol
 * blending later). LyraVolFeed stores raw SVI in total-variance terms and the engine reads
 *
 *   w(k) = a + b * (rho * (k - m) + sqrt((k - m)^2 + sigma^2)),   k = ln(K / SVI_fwd),   vol = sqrt(w / refTau)
 *
 * (lyra-utils SVI.sol). The surface here is parameterised the way an operator thinks: an ATM vol, and a shape held
 * fixed relative to ATM variance, so that raising the ATM level (the degrade floor) raises the whole curve with it:
 *
 *   atmVar = atmVol^2 * tau,   b = bMult * atmVar,   a = atmVar - b * sigma   (m = 0, so w(0) = atmVar exactly)
 *
 * rho < 0 makes low strikes (cNGN weaker: devaluation) dearer, the puts' wing. Everything is 18dp bigint, as the
 * contract computes it, so what is checked here is what the chain will read.
 */

export const ONE = 10n ** 18n;
export const SECONDS_PER_YEAR = 31_536_000n; // Black76.annualise: 365 days

export type SurfaceShape = {
  /** b as a multiple of ATM total variance, 18dp. */
  bMult: bigint;
  /** Skew, 18dp, in (-1, 1). Negative: the devaluation wing is dearer. */
  rho: bigint;
  /** Curvature at the money, 18dp, > 0. */
  sigma: bigint;
};

export type SviParams = {
  expiry: bigint;
  a: bigint;
  b: bigint;
  rho: bigint;
  m: bigint;
  sigma: bigint;
  fwd: bigint;
  refTau: bigint;
  confidence: bigint;
};

/** Seconds to a year fraction, 18dp, exactly as Black76.annualise. */
export function annualise(secs: bigint): bigint {
  return (secs * ONE) / SECONDS_PER_YEAR;
}

function abs(x: bigint): bigint {
  return x < 0n ? -x : x;
}

/** floor(sqrt(x)) for x >= 0. */
export function isqrt(x: bigint): bigint {
  if (x < 0n) throw new Error('sqrt of a negative');
  if (x < 2n) return x;
  let r = BigInt(Math.floor(Math.sqrt(Number(x))));
  while (r * r > x) r -= 1n;
  while ((r + 1n) * (r + 1n) <= x) r += 1n;
  return r;
}

/** Why a shape cannot be published, or null. Checked at config load and before every publish. */
export function shapeProblem(shape: SurfaceShape): string | null {
  if (shape.bMult <= 0n) return 'VOL_B_MULT must be positive';
  if (abs(shape.rho) >= ONE) return 'VOL_RHO must be inside (-1, 1)';
  if (shape.sigma <= 0n) return 'VOL_SIGMA must be positive';
  // w's minimum, a + b * sigma * sqrt(1 - rho^2), must be > 0; with a = atmVar - b * sigma that is
  // 1 - bMult * sigma * (1 - sqrt(1 - rho^2)) > 0, independent of the ATM level.
  const sqrtOneMinusRho2 = isqrt(ONE * ONE - shape.rho * shape.rho);
  const dip = (shape.bMult * shape.sigma * (ONE - sqrtOneMinusRho2)) / ONE / ONE;
  if (dip >= ONE) return 'the shape makes total variance negative somewhere: lower VOL_B_MULT or VOL_SIGMA, or |VOL_RHO|';
  // a must be >= 0 for the contract's strike bound (SVI.getK takes sqrt(a + b * sigma), fine either way), but a
  // negative a with a deep wing invites w < 0 past the bound: refuse it.
  if ((shape.bMult * shape.sigma) / ONE > ONE) return 'VOL_B_MULT x VOL_SIGMA over 1 makes a negative';
  return null;
}

/**
 * Raw SVI for `expiry` at `atmVol`, published at `nowSec` against the forward `fwd`. Throws when the expiry has
 * passed (LyraVolFeed refuses data stamped after expiry), or on a shape or level that would not be a surface.
 */
export function buildSvi(args: {
  expiry: bigint;
  nowSec: bigint;
  atmVol: bigint;
  shape: SurfaceShape;
  fwd: bigint;
  confidence: bigint;
}): SviParams {
  const { expiry, nowSec, atmVol, shape, fwd, confidence } = args;
  if (nowSec >= expiry) throw new Error(`expiry ${expiry} has passed (now ${nowSec})`);
  if (atmVol <= 0n || atmVol > 5n * ONE) throw new Error(`ATM vol ${atmVol} is outside (0, 500%]`);
  if (fwd <= 0n) throw new Error('no forward');
  if (confidence <= 0n || confidence > ONE) throw new Error(`confidence ${confidence} is outside (0, 1]`);
  const problem = shapeProblem(shape);
  if (problem) throw new Error(problem);
  const refTau = annualise(expiry - nowSec);
  if (refTau === 0n) throw new Error('under a second of a year left: nothing to publish');
  const atmVar = (((atmVol * atmVol) / ONE) * refTau) / ONE;
  const b = (shape.bMult * atmVar) / ONE;
  const a = atmVar - (b * shape.sigma) / ONE;
  return { expiry, a, b, rho: shape.rho, m: 0n, sigma: shape.sigma, fwd, refTau, confidence };
}

/**
 * The vol the contract will read at log-moneyness `k` (18dp), for checks and logs. Unbounded k: the contract clamps k
 * to +/- 4 sqrt(a + b sigma), which only matters far out of the money.
 */
export function sviVol(p: SviParams, k: bigint): bigint {
  const km = k - p.m;
  const root = isqrt(km * km + p.sigma * p.sigma); // 18dp
  const w = p.a + (p.b * ((p.rho * km) / ONE + root)) / ONE;
  if (w < 0n) throw new Error('negative total variance');
  return isqrt((w * ONE * ONE) / p.refTau);
}

/** ln(x) for an 18dp ratio, as a float-derived 18dp bigint: for checks only, never signed. */
export function lnRatio(num: bigint, den: bigint): bigint {
  return BigInt(Math.round(Math.log(Number(num) / Number(den)) * 1e18));
}
