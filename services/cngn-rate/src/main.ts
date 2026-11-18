/**
 * Serves the cNGN reference (rate.ts) on GET /usd-per-cngn, refreshed every REFRESH_SECONDS. Runs as a sidecar in the
 * cNGN book maker's task, which reads it at http://127.0.0.1:PORT/usd-per-cngn (MM_BOOK_REFERENCE_URL).
 *
 * Answers 503 until the first good reading and whenever the last one is older than MAX_AGE_SECONDS, so a picker that
 * keeps failing takes the maker's spline down rather than leaving it on an old price. /healthz is the container's
 * health check: 200 while serving.
 */
import { createServer, type Server } from 'node:http';

import { reading, usdcPicker, type Quote, type Reading } from './rate.js';

export type State = { last?: Reading; lastError?: string };

export function handler(state: State, maxAgeSeconds: number, nowMs: () => number) {
  return (url: string): { status: number; body: unknown } => {
    if (url === '/healthz') return { status: 200, body: { ok: true } };
    if (url !== '/usd-per-cngn') return { status: 404, body: { error: 'not found' } };
    const age = state.last ? nowMs() / 1000 - state.last.observed_at : Infinity;
    if (!state.last || age > maxAgeSeconds) {
      return { status: 503, body: { error: 'no fresh reading', age_seconds: Number.isFinite(age) ? Math.round(age) : null, last_error: state.lastError ?? null } };
    }
    return { status: 200, body: state.last };
  };
}

export async function refresh(state: State, picker: { getStablecoinToNgn(): Promise<Quote> }, nowMs: () => number): Promise<void> {
  try {
    state.last = reading(await picker.getStablecoinToNgn(), nowMs());
    state.lastError = undefined;
  } catch (err) {
    state.lastError = err instanceof Error ? err.message : String(err);
    console.error(JSON.stringify({ level: 'error', msg: 'rate_refresh_failed', error: state.lastError }));
  }
}

export function serve(port: number, maxAgeSeconds: number, refreshSeconds: number): Server {
  const state: State = {};
  const picker = usdcPicker();
  const route = handler(state, maxAgeSeconds, Date.now);
  void refresh(state, picker, Date.now);
  setInterval(() => void refresh(state, picker, Date.now), refreshSeconds * 1000).unref();
  return createServer((req, res) => {
    const { status, body } = route((req.url ?? '').split('?')[0]);
    res.writeHead(status, { 'content-type': 'application/json' });
    res.end(JSON.stringify(body));
  }).listen(port, '127.0.0.1');
}

const isMain = process.argv[1]?.endsWith('main.js');
if (isMain) {
  const num = (k: string, d: number) => {
    const n = Number(process.env[k] ?? d);
    if (!Number.isFinite(n) || n <= 0) throw new Error(`${k} must be a positive number`);
    return n;
  };
  const port = num('PORT', 8787);
  serve(port, num('MAX_AGE_SECONDS', 300), num('REFRESH_SECONDS', 30));
  console.log(JSON.stringify({ level: 'info', msg: 'cngn-rate serving', port }));
}
