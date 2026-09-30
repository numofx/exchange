import { readFile, writeFile, rename } from 'node:fs/promises';

import type { PricePoint } from 'cngn-rate-picker';

import type { Alerter } from './alert.js';
import type { Chain } from './chain.js';
import type { Config } from './config.js';
import { encodeManagerData, encodeSpotData, signFeedUpdate } from './feed-data.js';
import { aggregateSample, checkJump, toUsdPerNgn, windowTwap } from './index-aggregation.js';
import type { IndexSource, SourceReading } from './index-sources.js';
import { fetchPegTicker, pegMid, pegReading, type PegReading, type PegTicker } from './peg.js';

type IndexState = {
  /** Accepted samples: the median cNGN per USDT, when it was taken. */
  samples: PricePoint[];
  /** Good cNGN/NGN peg samples (NGN per cNGN, book mid), for the tripwire's TWAP. */
  pegSamples?: PricePoint[];
  /** Last index this process got onto the chain, USDC per cNGN 18dp, as a decimal string. */
  lastPublished: string | null;
};

export class IndexPublisher {
  private state: IndexState = { samples: [], lastPublished: null, pegSamples: [] };

  constructor(
    private readonly config: Config,
    private readonly chain: Chain,
    private readonly sources: IndexSource[],
    private readonly alert: Alerter,
    private readonly now: () => number = Date.now,
    /** The peg market's ticker; injectable so tests (and --local-sources) need no network. */
    private readonly readPegTicker: (signal: AbortSignal) => Promise<PegTicker> = (signal) =>
      fetchPegTicker(config.QUIDAX_API_URL, signal),
  ) {}

  /**
   * Restores samples so a restart does not wait a whole window before it can publish. Samples older
   * than the window are dropped on load; a missing or unreadable file starts empty.
   */
  async load(): Promise<void> {
    try {
      const raw = JSON.parse(await readFile(this.config.INDEX_STATE_FILE, 'utf8')) as IndexState;
      const cutoff = this.now() - this.config.INDEX_TWAP_WINDOW_MS;
      this.state = {
        samples: (raw.samples ?? []).filter((point) => point.at >= cutoff),
        lastPublished: raw.lastPublished ?? null,
        pegSamples: (raw.pegSamples ?? []).filter((point) => point.at >= this.now() - this.config.PEG_TWAP_WINDOW_MS),
      };
    } catch {
      this.state = { samples: [], lastPublished: null, pegSamples: [] };
    }
  }

  /** Accepted samples, as loaded: what `--accept-index-step` checks the operator's level against. */
  samples(): PricePoint[] {
    return [...this.state.samples];
  }

  /** The last index this process got onto the chain, if any. */
  lastPublished(): bigint | null {
    return this.state.lastPublished === null ? null : BigInt(this.state.lastPublished);
  }

  /** Records a publish made outside publish(): the index step, so the next restart guards from it. */
  async recordPublished(value: bigint): Promise<void> {
    this.state.lastPublished = value.toString();
    await this.save();
  }

  private async save(): Promise<void> {
    const tmp = `${this.config.INDEX_STATE_FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(this.state));
    await rename(tmp, this.config.INDEX_STATE_FILE);
  }

  /** Samples the peg tripwire once; a bad or failed read just leaves the last good samples standing. */
  private async samplePeg(): Promise<PegReading> {
    const at = this.now();
    const rules = {
      windowMs: this.config.PEG_TWAP_WINDOW_MS,
      maxSpreadBps: this.config.PEG_MAX_SPREAD_BPS,
      guardBps: this.config.PEG_GUARD_BPS,
    };
    try {
      const mid = pegMid(await this.readPegTicker(AbortSignal.timeout(this.config.PROVIDER_TIMEOUT_MS)), rules.maxSpreadBps);
      if (mid.ok) {
        const kept = (this.state.pegSamples ?? []).filter((p) => p.at >= at - rules.windowMs);
        this.state.pegSamples = [...kept, { price: mid.mid, at }];
      } else {
        console.warn(`[index] peg sample refused: ${mid.reason}`);
      }
    } catch (error) {
      console.warn(`[index] peg read failed: ${(error as Error).message}`);
    }
    return pegReading(this.state.pegSamples ?? [], at, rules);
  }

  /**
   * One sample: the peg tripwire, then every source in parallel, each reporting cNGN per USDT at
   * redemption parity; a source that throws or times out is simply absent. A tripped wire refuses
   * the sample outright (cNGN has left its NGN parity) and the operator is paged. A blind wire (the
   * peg market not answering) does not stop the index: the parity it checks does not depend on it.
   */
  async sample(): Promise<void> {
    const peg = await this.samplePeg();
    if (peg.state === 'blind') {
      console.warn(`[index] peg tripwire blind: ${peg.reason}`);
      await this.alert('peg-blind', `peg tripwire blind (index continues at parity): ${peg.reason}`);
    }
    const readings = await Promise.all(
      this.sources.map(async (source): Promise<SourceReading | { source: string; failed: string }> => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), this.config.PROVIDER_TIMEOUT_MS);
        try {
          return await source.read({ signal: controller.signal, fetch });
        } catch (error) {
          console.warn(`[index] ${source.name} absent: ${(error as Error).message}`);
          return { source: source.name, failed: (error as Error).message };
        } finally {
          clearTimeout(timer);
        }
      }),
    );
    const answered = readings.filter((r): r is SourceReading => 'cngnPerUsdt' in r);

    const at = this.now();
    let outcome: { ok: true; median: number } | { ok: false; reason: string };
    if (peg.state === 'watching' && peg.tripped) {
      outcome = { ok: false, reason: `peg guard: cNGN at ${peg.ngnPerCngn.toFixed(6)} NGN is ${peg.deviationBps.toFixed(0)}bps from parity (limit ${this.config.PEG_GUARD_BPS}bps)` };
      await this.alert('peg-guard', `index HALTED by the peg guard: ${outcome.reason}`);
    } else {
      const result = aggregateSample(
        answered.map((r) => ({ source: r.source, cngnPerUsdt: r.cngnPerUsdt })),
        { minSources: this.config.INDEX_MIN_SOURCES, maxSourceDeviationBps: this.config.INDEX_MAX_SOURCE_DEVIATION_BPS },
      );
      outcome = result;
      if (result.ok) {
        this.state.samples = [...this.state.samples.filter((p) => p.at >= at - this.config.INDEX_TWAP_WINDOW_MS), { price: result.median, at }];
        console.log(`[index] sample ${result.median} cNGN/USDT from ${result.sources.join(', ')}`);
      } else {
        console.warn(`[index] sample refused: ${result.reason}`);
        await this.alert('index-sample-refused', `index sample refused: ${result.reason}`);
      }
    }
    await this.save();
    await this.writeStatus(at, peg, readings, outcome);
  }

  /** What the last sample saw, for the pager (peg-guard page) and for an operator reading the host. */
  private async writeStatus(
    at: number,
    peg: PegReading,
    readings: (SourceReading | { source: string; failed: string })[],
    outcome: { ok: true; median: number } | { ok: false; reason: string },
  ): Promise<void> {
    const status = {
      at,
      peg:
        peg.state === 'watching'
          ? { state: 'watching', ngnPerCngn: peg.ngnPerCngn, deviationBps: peg.deviationBps, samples: peg.samples }
          : { state: 'blind', reason: peg.reason },
      pegGuardTripped: peg.state === 'watching' && peg.tripped,
      sources: readings,
      sample: outcome.ok ? { ok: true, cngnPerUsdt: outcome.median } : { ok: false, reason: outcome.reason },
    };
    const tmp = `${this.config.INDEX_STATUS_FILE}.tmp`;
    await writeFile(tmp, JSON.stringify(status));
    await rename(tmp, this.config.INDEX_STATUS_FILE);
  }

  /** Publishes the window TWAP, inverted to USDC per cNGN, if every guard passes. */
  async publish(): Promise<void> {
    const twap = windowTwap(this.state.samples, this.now(), {
      windowMs: this.config.INDEX_TWAP_WINDOW_MS,
      minSamples: this.config.INDEX_MIN_WINDOW_SAMPLES,
      maxNewestAgeMs: this.config.INDEX_MAX_SAMPLE_AGE_MS,
    });
    if (!twap.ok) {
      console.warn(`[index] not publishing: ${twap.reason}`);
      await this.alert('index-window-short', `index not published: ${twap.reason}`);
      return;
    }

    const next = toUsdPerNgn(twap.cngnPerUsdt);
    // The chain's value is the reference when it is readable; this process's memory otherwise, so a
    // restart against a stale feed still guards against the jump it would otherwise publish.
    const onChain = await this.chain.readIndex(this.config.INDEX_FEED);
    const reference = onChain ?? (this.state.lastPublished === null ? null : BigInt(this.state.lastPublished));
    const jump = checkJump(next, reference, { maxJumpBps: this.config.INDEX_MAX_JUMP_BPS });
    if (!jump.ok) {
      console.error(`[index] not publishing: ${jump.reason}`);
      await this.alert(
        'index-jump',
        `index NOT published, market will halt when it goes stale: ${jump.reason}. ` +
          'If the move is real, follow the index-step procedure (perp-feeds README): --accept-index-step.',
      );
      return;
    }

    const head = await this.chain.headTimestamp();
    const timestamp = head - BigInt(this.config.TIMESTAMP_SAFETY_SEC);
    const update = await signFeedUpdate({
      signer: this.chain.signer,
      kind: 'LyraSpotFeed',
      feed: this.config.INDEX_FEED,
      chainId: this.chain.chainId,
      data: encodeSpotData(next),
      timestamp,
      deadline: head + BigInt(this.config.DEADLINE_SEC),
    });

    if (this.config.DRY_RUN) {
      console.log(`[index] dry-run: would publish ${next} (TWAP ${twap.cngnPerUsdt} NGN/USDT, ${twap.samples} samples)`);
      return;
    }
    const tx = await this.chain.submit(encodeManagerData([update]));
    this.state.lastPublished = next.toString();
    await this.save();
    console.log(`[index] published ${next} (TWAP ${twap.cngnPerUsdt} NGN/USDT, ${twap.samples} samples) tx=${tx}`);
  }
}
