/**
 * Counts the JSON-RPC calls this process makes, by endpoint host, method and HTTP status, and logs the counts once a
 * window as one JSON line per host: {"level":"info","msg":"rpc_calls","host":…,"by_method":"eth_call:120,…"}.
 *
 * It wraps the global fetch, which viem's http transport calls, so every client in the process is counted however it
 * was made. Only POSTs whose body is JSON-RPC are counted. A batch counts each call in it: providers bill per call.
 *
 * It exists because the venue's RPC plan ran out on 2026-11-12 with nothing saying which service or call used it.
 * The same file is in services/execution, services/perp-feeds and services/perp-keeper (the box builds each service
 * alone, so it is not a workspace package); market-maker and services/markets have the Go equivalent, `rpccount`.
 */

type Tally = { total: number; byMethod: Map<string, number>; byStatus: Map<string, number> };

export type RpcWindow = { host: string; total: number; by_method: string; by_status: string };

/** Pulls the JSON-RPC methods out of a request body, one per call; empty when it is not JSON-RPC. */
export function rpcMethods(body: unknown): string[] {
  if (typeof body !== 'string') return [];
  const trimmed = body.trimStart();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return [];
  }
  const calls = Array.isArray(parsed) ? parsed : [parsed];
  const methods: string[] = [];
  for (const call of calls) {
    if (typeof call !== 'object' || call === null) return [];
    const { jsonrpc, method } = call as { jsonrpc?: unknown; method?: unknown };
    if (typeof jsonrpc !== 'string' || typeof method !== 'string' || method === '') return [];
    methods.push(method);
  }
  return methods;
}

function joinCounts(counts: Map<string, number>): string {
  return [...counts.entries()]
    .sort(([a, x], [b, y]) => y - x || a.localeCompare(b))
    .map(([name, n]) => `${name}:${n}`)
    .join(',');
}

export class RpcCounter {
  private hosts = new Map<string, Tally>();

  record(host: string, methods: readonly string[], status: string): void {
    let tally = this.hosts.get(host);
    if (!tally) {
      tally = { total: 0, byMethod: new Map(), byStatus: new Map() };
      this.hosts.set(host, tally);
    }
    for (const method of methods) {
      tally.total += 1;
      tally.byMethod.set(method, (tally.byMethod.get(method) ?? 0) + 1);
      tally.byStatus.set(status, (tally.byStatus.get(status) ?? 0) + 1);
    }
  }

  /** The counts since the last drain, largest host first; starts a new window. */
  drain(): RpcWindow[] {
    const hosts = this.hosts;
    this.hosts = new Map();
    return [...hosts.entries()]
      .map(([host, t]) => ({ host, total: t.total, by_method: joinCounts(t.byMethod), by_status: joinCounts(t.byStatus) }))
      .sort((a, b) => b.total - a.total);
  }

  /** `fetch` with every JSON-RPC call through it recorded. */
  wrap(fetchImpl: typeof fetch): typeof fetch {
    return async (input, init) => {
      const methods = (init?.method ?? 'GET').toUpperCase() === 'POST' ? rpcMethods(init?.body) : [];
      if (methods.length === 0) return fetchImpl(input, init);
      const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      let host = 'unknown';
      try {
        host = new URL(url).host;
      } catch {
        // A relative or malformed URL still counts, under "unknown".
      }
      try {
        const response = await fetchImpl(input, init);
        this.record(host, methods, String(response.status));
        return response;
      } catch (error) {
        this.record(host, methods, 'error');
        throw error;
      }
    };
  }
}

/**
 * Puts a counter in front of the global fetch and logs its counts every `everyMs`. Call it once, at the start of the
 * process, before any client is made. The timer is unref'd, so it never holds the process open.
 */
export function installRpcCounter(everyMs = 60_000, log: (line: string) => void = (line) => console.log(line)): RpcCounter {
  const counter = new RpcCounter();
  globalThis.fetch = counter.wrap(globalThis.fetch.bind(globalThis));
  const flush = () => {
    for (const window of counter.drain()) {
      log(JSON.stringify({ level: 'info', msg: 'rpc_calls', window_s: Math.round(everyMs / 1000), ...window }));
    }
  };
  setInterval(flush, everyMs).unref();
  return counter;
}
