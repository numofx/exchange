import { readFile, rename, writeFile } from 'node:fs/promises';

import { parseAbi, type Address } from 'viem';

import type { Alerter } from './alert.js';
import type { ContractChain } from './chain.js';
import { encodeManagerData, encodeVolData, signFeedUpdate } from './feed-data.js';
import type { VolConfig } from './vol-config.js';
import { buildSvi, ONE, sviVol, type SviParams } from './vol-surface.js';

export const volFeedAbi = parseAbi([
  'function getVol(uint128 strike, uint64 expiry) view returns (uint256 vol, uint256 confidence)',
  'function getExpiryMinConfidence(uint64 expiry) view returns (uint256)',
  'function heartbeat() view returns (uint64)',
  'function isSigner(address) view returns (bool)',
]);
export const forwardFeedAbi = parseAbi(['function getForwardPrice(uint64 expiry) view returns (uint256, uint256)']);
export const engineAbi = parseAbi([
  'function oracleContingencyParams(uint256) view returns (uint256 perpThreshold, uint256 optionThreshold, uint256 baseThreshold, uint256 OCFactor)',
  'function getMarketFeeds(uint256) view returns (address spot, address forward, address vol)',
]);

export type VolMode = { mode: 'normal' } | { mode: 'degraded'; reasons: string[] };

export type VolOutcome = 'published' | 'dry-run' | 'not-due' | 'expired' | 'no-forward' | 'sign-failed' | 'publish-failed';

/** What the index publisher writes each minute (index-publisher.ts writeStatus): only what this reads. */
type IndexStatus = { at?: unknown; pegGuardTripped?: unknown; sample?: { ok?: unknown; reason?: unknown } };

/**
 * Whether the index can be trusted right now, from what the index publisher and its step procedure leave on the host
 * and from the chain. Any reason degrades the surface; none, and it is published as set.
 *
 *   - the status file is missing, unreadable, or older than maxAgeMs: the index publisher is silent;
 *   - the peg tripwire is tripped (cNGN off its NGN parity);
 *   - the last index sample was refused (sources disagree, or the jump guard held a real move);
 *   - an index step was published within stepDegradeMs (a devaluation was just let through);
 *   - the chain's index is unreadable (stale: margin reads it too). Reported for the alert's sake: with no index the
 *     forward reverts as well, so the tick ends at 'no-forward' and the surface ages out, alongside the index's own halt.
 */
export function uncertaintyReasons(args: {
  status: IndexStatus | null;
  statusError?: string;
  stepLog: string | null;
  indexOnChain: bigint | null;
  nowMs: number;
  maxAgeMs: number;
  stepDegradeMs: number;
}): string[] {
  const reasons: string[] = [];
  const { status } = args;
  if (!status) {
    reasons.push(`index status unreadable (${args.statusError ?? 'missing'})`);
  } else {
    const at = typeof status.at === 'number' ? status.at : NaN;
    if (!Number.isFinite(at)) reasons.push('index status carries no time');
    else if (args.nowMs - at > args.maxAgeMs) reasons.push(`index status ${Math.round((args.nowMs - at) / 1000)}s old: index publisher silent`);
    if (status.pegGuardTripped === true) reasons.push('peg tripwire tripped');
    if (status.sample && status.sample.ok === false) reasons.push(`last index sample refused: ${String(status.sample.reason ?? '').slice(0, 120)}`);
  }
  for (const line of (args.stepLog ?? '').split('\n')) {
    if (!line.trim()) continue;
    try {
      const record = JSON.parse(line) as { event?: unknown; status?: unknown; at?: unknown };
      if (record.event !== 'index-step' || record.status !== 'published') continue;
      const atMs = Date.parse(String(record.at));
      if (Number.isFinite(atMs) && args.nowMs - atMs <= args.stepDegradeMs) {
        reasons.push(`index step published ${Math.round((args.nowMs - atMs) / 60_000)} min ago`);
      }
    } catch {
      // a torn last line while the step procedure is appending: read again next tick
    }
  }
  if (args.indexOnChain === null) reasons.push('the chain index is unreadable (stale or unset)');
  return reasons;
}

/** The ATM vol and confidence to publish in a mode. Degraded never cheapens: the floor is at least the set level. */
export function levels(config: Pick<VolConfig, 'VOL_ATM' | 'VOL_DEGRADED_ATM_FLOOR' | 'VOL_DEGRADED_CONFIDENCE'>, mode: VolMode) {
  if (mode.mode === 'normal') return { atmVol: config.VOL_ATM, confidence: ONE };
  const atmVol = config.VOL_DEGRADED_ATM_FLOOR > config.VOL_ATM ? config.VOL_DEGRADED_ATM_FLOOR : config.VOL_ATM;
  return { atmVol, confidence: config.VOL_DEGRADED_CONFIDENCE };
}

/**
 * Publishes the cNGN options' surface for one expiry (vol-surface.ts) into their LyraVolFeed, through the
 * OracleDataSubmitter: every VOL_PUBLISH_INTERVAL_MS, and at once when the mode changes. Each publish is read back from
 * the chain (the ATM vol and the confidence the feed now returns) and a mismatch alerts.
 *
 * Fails closed only when it is itself broken: no forward, a signing or relay failure. Then the feed ages out past its
 * heartbeat and option accounts stop margining; every such tick alerts.
 */
export class VolPublisher {
  private lastPublishedMs = 0;
  private lastMode: VolMode['mode'] | null = null;

  constructor(
    private readonly config: VolConfig,
    private readonly chain: ContractChain,
    private readonly alert: Alerter,
    private readonly nowMs: () => number = Date.now,
    private readonly read: (path: string) => Promise<string> = (path) => readFile(path, 'utf8'),
    private readonly write: (path: string, body: string) => Promise<void> = async (path, body) => {
      await writeFile(`${path}.tmp`, body);
      await rename(`${path}.tmp`, path);
    },
  ) {}

  /**
   * Refuses to start on a configuration that cannot work: a publish interval the heartbeat does not comfortably cover,
   * a signer the feed does not accept, or a degraded confidence the engine would not penalise. Run once at startup.
   * A feed not yet attached to the engine is reported, not refused: the surface must be live before the cap opens.
   */
  async checkStartup(): Promise<void> {
    const heartbeat = await this.chain.read<bigint>(this.config.VOL_FEED, volFeedAbi, 'heartbeat');
    const intervalMs = this.config.VOL_PUBLISH_INTERVAL_MS + this.config.VOL_TICK_MS;
    if (BigInt(intervalMs) * 3n > heartbeat * 1000n) {
      throw new Error(`VOL_PUBLISH_INTERVAL_MS + VOL_TICK_MS (${intervalMs}ms) must be under a third of the feed's heartbeat (${heartbeat}s)`);
    }
    const accepted = await this.chain.read<boolean>(this.config.VOL_FEED, volFeedAbi, 'isSigner', [this.chain.signer.address]);
    if (!accepted) throw new Error(`the vol feed does not accept signer ${this.chain.signer.address}`);
    const [, optionThreshold] = await this.chain.read<readonly bigint[]>(this.config.ENGINE, engineAbi, 'oracleContingencyParams', [
      BigInt(this.config.MARKET_ID),
    ]);
    if (this.config.VOL_DEGRADED_CONFIDENCE >= optionThreshold) {
      throw new Error(
        `VOL_DEGRADED_CONFIDENCE (${this.config.VOL_DEGRADED_CONFIDENCE}) must be under the engine's option threshold (${optionThreshold}): degrading would cost nothing`,
      );
    }
    const [, , vol] = await this.chain.read<readonly Address[]>(this.config.ENGINE, engineAbi, 'getMarketFeeds', [BigInt(this.config.MARKET_ID)]);
    if (vol.toLowerCase() !== this.config.VOL_FEED.toLowerCase()) {
      await this.alert('vol-feed-not-attached', `market ${this.config.MARKET_ID} reads vol feed ${vol}, not ${this.config.VOL_FEED}: cngn-options-setup has not landed`);
    }
  }

  async mode(): Promise<VolMode> {
    let status: IndexStatus | null = null;
    let statusError: string | undefined;
    try {
      status = JSON.parse(await this.read(this.config.INDEX_STATUS_FILE)) as IndexStatus;
    } catch (error) {
      statusError = (error as Error).message.slice(0, 120);
    }
    let stepLog: string | null = null;
    try {
      stepLog = await this.read(this.config.INDEX_STEP_AUDIT_FILE);
    } catch {
      stepLog = null; // no step ever taken
    }
    const reasons = uncertaintyReasons({
      status,
      statusError,
      stepLog,
      indexOnChain: await this.chain.readIndex(this.config.INDEX_FEED),
      nowMs: this.nowMs(),
      maxAgeMs: this.config.INDEX_STATUS_MAX_AGE_MS,
      stepDegradeMs: this.config.VOL_STEP_DEGRADE_MS,
    });
    return reasons.length ? { mode: 'degraded', reasons } : { mode: 'normal' };
  }

  async tick(): Promise<VolOutcome> {
    const head = await this.chain.headTimestamp();
    const timestamp = head - BigInt(this.config.TIMESTAMP_SAFETY_SEC);
    if (timestamp >= this.config.EXPIRY) return 'expired';

    const mode = await this.mode();
    const changed = mode.mode !== this.lastMode;
    if (changed && mode.mode === 'degraded') {
      await this.alert('vol-degraded', `vol surface degraded: ${mode.reasons.join('; ')}`);
    } else if (changed && this.lastMode === 'degraded') {
      await this.alert('vol-recovered', 'vol surface back to the set level at full confidence');
    }
    if (!changed && this.nowMs() - this.lastPublishedMs < this.config.VOL_PUBLISH_INTERVAL_MS) return 'not-due';

    let fwd: bigint;
    try {
      [fwd] = await this.chain.read<readonly bigint[]>(this.config.FORWARD_FEED, forwardFeedAbi, 'getForwardPrice', [this.config.EXPIRY]);
    } catch (error) {
      await this.alert('vol-no-forward', `vol not published: the forward is unreadable (${(error as Error).message.slice(0, 160)})`);
      return 'no-forward';
    }

    const { atmVol, confidence } = levels(this.config, mode);
    const svi = buildSvi({
      expiry: this.config.EXPIRY,
      nowSec: timestamp,
      atmVol,
      shape: { bMult: this.config.VOL_B_MULT, rho: this.config.VOL_RHO, sigma: this.config.VOL_SIGMA },
      fwd,
      confidence,
    });
    const line = `ATM ${(Number(atmVol) / 1e16).toFixed(1)}% conf ${(Number(confidence) / 1e18).toFixed(2)} fwd ${fwd} (${mode.mode})`;

    if (this.config.DRY_RUN) {
      console.log(`[vol] DRY RUN: would publish ${line}`);
      this.noteMode(mode);
      await this.writeStatus(mode, svi, null);
      return 'dry-run';
    }

    let managerData;
    try {
      const update = await signFeedUpdate({
        signer: this.chain.signer,
        kind: 'LyraVolFeed',
        feed: this.config.VOL_FEED,
        chainId: this.chain.chainId,
        data: encodeVolData(svi),
        timestamp,
        deadline: timestamp + BigInt(this.config.DEADLINE_SEC),
      });
      managerData = encodeManagerData([update]);
    } catch (error) {
      await this.alert('vol-sign-failed', `vol not signed: ${(error as Error).message.slice(0, 300)}`);
      return 'sign-failed';
    }
    let tx;
    try {
      tx = await this.chain.submit(managerData);
    } catch (error) {
      await this.alert('vol-publish-failed', `vol not relayed: ${(error as Error).message.slice(0, 300)}`);
      return 'publish-failed';
    }
    this.lastPublishedMs = this.nowMs();
    this.noteMode(mode);
    await this.readBack(svi, atmVol);
    await this.writeStatus(mode, svi, tx);
    console.log(`[vol] published ${line} tx=${tx}`);
    return 'published';
  }

  private noteMode(mode: VolMode) {
    this.lastMode = mode.mode;
  }

  /** The deployed state, not what was sent: the ATM vol at the forward and the expiry's confidence. */
  private async readBack(svi: SviParams, atmVol: bigint): Promise<void> {
    try {
      const strike = (svi.fwd / 10n ** 10n) * 10n ** 10n; // the 1e-8 grid options are struck on
      const [vol] = await this.chain.read<readonly bigint[]>(this.config.VOL_FEED, volFeedAbi, 'getVol', [strike, this.config.EXPIRY]);
      const confidence = await this.chain.read<bigint>(this.config.VOL_FEED, volFeedAbi, 'getExpiryMinConfidence', [this.config.EXPIRY]);
      const expected = sviVol(svi, 0n);
      const off = vol > expected ? vol - expected : expected - vol;
      if (confidence !== svi.confidence || off * 200n > expected) {
        await this.alert(
          'vol-readback-mismatch',
          `the feed reads ATM ${vol} at confidence ${confidence}; published ${atmVol} at ${svi.confidence}`,
        );
      }
    } catch (error) {
      await this.alert('vol-readback-failed', `published, but the feed does not read back: ${(error as Error).message.slice(0, 200)}`);
    }
  }

  private async writeStatus(mode: VolMode, svi: SviParams, tx: string | null): Promise<void> {
    const status = {
      at: this.nowMs(),
      volFeed: this.config.VOL_FEED,
      expiry: Number(this.config.EXPIRY),
      mode: mode.mode,
      reasons: mode.mode === 'degraded' ? mode.reasons : [],
      atmVol: Number(sviVol(svi, 0n)) / 1e18,
      confidence: Number(svi.confidence) / 1e18,
      tx,
      dryRun: this.config.DRY_RUN,
    };
    try {
      await this.write(this.config.VOL_STATUS_FILE, JSON.stringify(status));
    } catch (error) {
      console.warn(`[vol] status not written: ${(error as Error).message}`);
    }
  }
}
