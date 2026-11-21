/**
 * Serves the cNGN reference (rate.ts) on GET /usd-per-cngn, refreshed every REFRESH_SECONDS. Runs as a sidecar in the
 * cNGN book maker's task, which reads it at http://127.0.0.1:PORT/usd-per-cngn (MM_BOOK_REFERENCE_URL).
 *
 * Answers 503 until the first good reading and whenever the last one is older than MAX_AGE_SECONDS, so a picker that
 * keeps failing takes the maker's spline down rather than leaving it on an old price. /healthz is the container's
 * health check: 200 while serving.
 *
 * GET /daya serves Daya Pro's USD-NGN book in cNGN terms (daya.ts), refreshed every DAYA_REFRESH_SECONDS and 503 once
 * Daya's own timestamp is older than DAYA_MAX_AGE_SECONDS. Its failures never touch /usd-per-cngn: the two are
 * meant to be compared, so neither may take the other down.
 */
import { createServer, type Server } from 'node:http';

import { fetchDayaBook, type DayaBook } from './daya.js';
import { reading, usdcPicker, type Quote, type Reading } from './rate.js';

export type State = { last?: Reading; lastError?: string; daya?: DayaBook; dayaError?: string };

export const DAYA_MAX_AGE_SECONDS = 15;

export function handler(state: State, maxAgeSeconds: number, nowMs: () => number, dayaMaxAgeSeconds = DAYA_MAX_AGE_SECONDS) {
  return (url: string): { status: number; body: unknown } => {
    if (url === '/healthz') return { status: 200, body: { ok: true } };
    if (url === '/daya') {
      const age = state.daya ? nowMs() / 1000 - state.daya.observed_at : Infinity;
      if (!state.daya || age > dayaMaxAgeSeconds) {
        return { status: 503, body: { error: 'no fresh Daya book', age_seconds: Number.isFinite(age) ? Math.round(age) : null, last_error: state.dayaError ?? null } };
      }
      return { status: 200, body: state.daya };
    }
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

export async function refreshDaya(state: State, read: () => Promise<DayaBook>): Promise<void> {
  try {
    state.daya = await read();
    state.dayaError = undefined;
  } catch (err) {
    state.dayaError = err instanceof Error ? err.message : String(err);
    console.error(JSON.stringify({ level: 'error', msg: 'daya_refresh_failed', error: state.dayaError }));
  }
}

export function serve(port: number, maxAgeSeconds: number, refreshSeconds: number, dayaMaxAgeSeconds: number, dayaRefreshSeconds: number): Server {
  const state: State = {};
  const picker = usdcPicker();
  const route = handler(state, maxAgeSeconds, Date.now, dayaMaxAgeSeconds);
  void refresh(state, picker, Date.now);
  setInterval(() => void refresh(state, picker, Date.now), refreshSeconds * 1000).unref();
  const readDaya = () => fetchDayaBook(Date.now);
  void refreshDaya(state, readDaya);
  setInterval(() => void refreshDaya(state, readDaya), dayaRefreshSeconds * 1000).unref();
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
  // Daya allows 100 requests per minute per IP; the 2 s default is 30.
  const dayaRefresh = num('DAYA_REFRESH_SECONDS', 2);
  if (dayaRefresh < 1) throw new Error('DAYA_REFRESH_SECONDS below 1 exceeds Daya\'s 100 per minute per IP');
  serve(port, num('MAX_AGE_SECONDS', 300), num('REFRESH_SECONDS', 30), num('DAYA_MAX_AGE_SECONDS', DAYA_MAX_AGE_SECONDS), dayaRefresh);
  console.log(JSON.stringify({ level: 'info', msg: 'cngn-rate serving', port }));
}
