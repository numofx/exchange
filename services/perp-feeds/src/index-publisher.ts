import { readFile, writeFile, rename } from 'node:fs/promises';

import {
  BlockradarProvider,
  BybitP2PProvider,
  QuidaxProvider,
  TextileProvider,
  type PricePoint,
  type RateProvider,
} from 'cngn-rate-picker';

import type { Alerter } from './alert.js';
import type { Chain } from './chain.js';
import type { Config } from './config.js';
import { encodeManagerData, encodeSpotData, signFeedUpdate } from './feed-data.js';
import { aggregateSample, checkJump, toUsdPerNgn, windowTwap, type SourceQuote } from './index-aggregation.js';

/** Every USDT-quoting provider the library offers; Blockradar only when a key is configured. */
export function buildProviders(config: Config): RateProvider[] {
  const providers: RateProvider[] = [new QuidaxProvider(), new TextileProvider(), new BybitP2PProvider()];
  if (config.BLOCKRADAR_API_KEY) providers.push(new BlockradarProvider({ apiKey: config.BLOCKRADAR_API_KEY }));
  return providers;
}

type IndexState = {
  /** Accepted samples: the median NGN per USDT, when it was taken. */
  samples: PricePoint[];
  /** Last index this process got onto the chain, USD per NGN 18dp, as a decimal string. */
  lastPublished: string | null;
};

export class IndexPublisher {
  private state: IndexState = { samples: [], lastPublished: null };

  constructor(
    private readonly config: Config,
    private readonly chain: Chain,
    private readonly providers: RateProvider[],
    private readonly alert: Alerter,
    private readonly now: () => number = Date.now,
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
      };
    } catch {
      this.state = { samples: [], lastPublished: null };
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

  /** Queries every provider in parallel; a provider that throws or times out is simply absent. */
  async sample(): Promise<void> {
    const quotes = await Promise.all(
      this.providers.map(async (provider): Promise<SourceQuote | null> => {
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), this.config.PROVIDER_TIMEOUT_MS);
        try {
          const quote = await provider.getPriceInNgn({ signal: controller.signal, fetch });
          return { source: provider.name, ngnPerUsdt: quote.price };
        } catch (error) {
          console.warn(`[index] ${provider.name} failed: ${(error as Error).message}`);
          return null;
        } finally {
          clearTimeout(timer);
        }
      }),
    );

    const result = aggregateSample(
      quotes.filter((quote): quote is SourceQuote => quote !== null),
      { minSources: this.config.INDEX_MIN_SOURCES, maxSourceDeviationBps: this.config.INDEX_MAX_SOURCE_DEVIATION_BPS },
    );
    if (!result.ok) {
      console.warn(`[index] sample refused: ${result.reason}`);
      await this.alert('index-sample-refused', `index sample refused: ${result.reason}`);
      return;
    }

    const at = this.now();
    this.state.samples = [...this.state.samples.filter((p) => p.at >= at - this.config.INDEX_TWAP_WINDOW_MS), { price: result.median, at }];
    console.log(`[index] sample ${result.median} NGN/USDT from ${result.sources.join(', ')}`);
    await this.save();
  }

  /** Publishes the window TWAP, inverted to USD per NGN, if every guard passes. */
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

    const next = toUsdPerNgn(twap.ngnPerUsdt);
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
      console.log(`[index] dry-run: would publish ${next} (TWAP ${twap.ngnPerUsdt} NGN/USDT, ${twap.samples} samples)`);
      return;
    }
    const tx = await this.chain.submit(encodeManagerData([update]));
    this.state.lastPublished = next.toString();
    await this.save();
    console.log(`[index] published ${next} (TWAP ${twap.ngnPerUsdt} NGN/USDT, ${twap.samples} samples) tx=${tx}`);
  }
}
