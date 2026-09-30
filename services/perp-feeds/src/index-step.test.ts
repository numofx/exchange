import assert from 'node:assert/strict';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, it } from 'node:test';

import { keccak256, toHex, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { Chain } from './chain.js';
import { loadConfig } from './config.js';
import { encodeSpotData } from './feed-data.js';
import { toUsdPerNgn } from './index-aggregation.js';
import { acceptIndexStep, checkKeeperHealth, parseStepArgs, planIndexStep, type KeeperHealth } from './index-step.js';

const HEAD = 1_800_000_000n;
const nowMs = Number(HEAD) * 1000;
const MINUTE = 60_000;
const key = (label: string) => keccak256(toHex(label));
const OLD = toUsdPerNgn(1374);

const rules = { windowMs: 15 * MINUTE, minSamples: 10, maxNewestAgeMs: 3 * MINUTE, maxJumpBps: 300, matchBps: 100, maxStepBps: 5_000 };
/** Twelve agreeing samples at `price`, the newest 30s old. */
const samplesAt = (price: number) => Array.from({ length: 12 }, (_, i) => ({ price, at: nowMs - (12 - i) * MINUTE + 30_000 }));
const approved = { levelNgnPerUsd: 2290, approvedBy: 'ops-lead', reason: 'CBN devaluation confirmed on 3 venues' };
const healthy: KeeperHealth = { lastPassAt: Number(HEAD) - 10, lastPassOk: true, dryRun: false, pollIntervalMs: 15_000, keeperAccount: '23' };

describe('planIndexStep', () => {
  it('plans a 40% step the sources and the operator agree on', () => {
    const plan = planIndexStep({ samples: samplesAt(2290), nowMs, onChain: OLD, request: approved, rules });
    assert.ok(plan.ok);
    assert.equal(plan.ok && plan.next, toUsdPerNgn(2290));
    assert.ok(plan.ok && plan.stepBps < -3_900 && plan.stepBps > -4_100);
  });

  it('refuses when the sources disagree with the confirmed level', () => {
    const plan = planIndexStep({ samples: samplesAt(2290), nowMs, onChain: OLD, request: { ...approved, levelNgnPerUsd: 2100 }, rules });
    assert.match(!plan.ok ? plan.reason : '', /bps from the confirmed 2100/);
  });

  it('refuses without an approver or a reason', () => {
    assert.equal(planIndexStep({ samples: samplesAt(2290), nowMs, onChain: OLD, request: { ...approved, approvedBy: ' ' }, rules }).ok, false);
    assert.equal(planIndexStep({ samples: samplesAt(2290), nowMs, onChain: OLD, request: { ...approved, reason: '' }, rules }).ok, false);
  });

  it('refuses a move the normal guard would publish anyway, and one past the step bound', () => {
    const small = planIndexStep({ samples: samplesAt(1400), nowMs, onChain: OLD, request: { ...approved, levelNgnPerUsd: 1400 }, rules });
    assert.match(!small.ok ? small.reason : '', /no override needed/);
    const huge = planIndexStep({ samples: samplesAt(4000), nowMs, onChain: OLD, request: { ...approved, levelNgnPerUsd: 4000 }, rules });
    assert.match(!huge.ok ? huge.reason : '', /INDEX_STEP_MAX_BPS/);
  });

  it('keeps every sample guard: stale sources refuse even a confirmed level', () => {
    const stale = samplesAt(2290).map((sample) => ({ ...sample, at: sample.at - 5 * MINUTE }));
    const plan = planIndexStep({ samples: stale, nowMs, onChain: OLD, request: approved, rules });
    assert.match(!plan.ok ? plan.reason : '', /newest accepted sample/);
  });
});

describe('checkKeeperHealth', () => {
  const nowSec = Number(HEAD);
  it('passes a live keeper', () => assert.ok(checkKeeperHealth(healthy, nowSec).ok));
  it('refuses unreachable, dry-run, failing or stale', () => {
    assert.equal(checkKeeperHealth(null, nowSec).ok, false);
    assert.equal(checkKeeperHealth({ ...healthy, dryRun: true }, nowSec).ok, false);
    assert.equal(checkKeeperHealth({ ...healthy, lastPassOk: false }, nowSec).ok, false);
    assert.equal(checkKeeperHealth({ ...healthy, lastPassAt: nowSec - 120 }, nowSec).ok, false);
  });
});

describe('acceptIndexStep', () => {
  function setup(health: KeeperHealth | null, onChain: bigint | null = OLD) {
    const submitted: Hex[] = [];
    const audit: Record<string, unknown>[] = [];
    const chain: Chain = {
      signer: privateKeyToAccount(key('index-step-signer')),
      relayer: privateKeyToAccount(key('index-step-relayer')),
      chainId: 31337,
      headTimestamp: async () => HEAD,
      readIndex: async () => onChain,
      readDiffFeed: async () => null,
      submit: async (data) => {
        submitted.push(data);
        return '0xabc';
      },
    };
    const config = loadConfig({
      RPC_URL: 'http://127.0.0.1:1',
      CHAIN_ID: '31337',
      FEED_SIGNER_KEY: key('index-step-signer'),
      RELAYER_KEY: key('index-step-relayer'),
      DATA_SUBMITTER: '0x00000000000000000000000000000000000000b1',
      PERP_ASSET: '0x00000000000000000000000000000000000000b2',
      INDEX_FEED: '0x00000000000000000000000000000000000000a1',
      MARK_FEED: '0x00000000000000000000000000000000000000a2',
      IMPACT_ASK_FEED: '0x00000000000000000000000000000000000000a3',
      IMPACT_BID_FEED: '0x00000000000000000000000000000000000000a4',
      INDEX_STATE_FILE: join(mkdtempSync(join(tmpdir(), 'index-step-')), 'state.json'),
      INDEX_STATUS_FILE: join(mkdtempSync(join(tmpdir(), 'perp-feeds-status-')), 'status.json'),
    });
    const run = () =>
      acceptIndexStep({
        config,
        chain,
        alert: async () => {},
        samples: samplesAt(2290),
        lastPublished: OLD,
        request: approved,
        readKeeperHealth: async () => health,
        now: () => nowMs,
        audit: async (record) => void audit.push(record as Record<string, unknown>),
      });
    return { run, submitted, audit };
  }

  it("publishes the sources' TWAP once and records who approved it, before and after", async () => {
    const { run, submitted, audit } = setup(healthy);
    const { tx } = await run();
    assert.equal(tx, '0xabc');
    assert.equal(submitted.length, 1);
    assert.ok(submitted[0]!.includes(encodeSpotData(toUsdPerNgn(2290)).slice(2)));
    assert.deepEqual(audit.map((record) => record.status), ['approved', 'published']);
    assert.equal(audit[0]!.approvedBy, 'ops-lead');
    assert.equal(audit[1]!.tx, '0xabc');
  });

  it('steps from its own last publish when the halted index has gone stale on chain', async () => {
    const { run, submitted } = setup(healthy, null);
    const { plan } = await run();
    assert.equal(plan.previous, OLD);
    assert.equal(submitted.length, 1);
  });

  it('refuses before signing anything when the keeper is not live', async () => {
    const { run, submitted, audit } = setup({ ...healthy, dryRun: true });
    await assert.rejects(run(), /DRY_RUN/);
    assert.equal(submitted.length, 0);
    assert.equal(audit.length, 0);
  });
});

describe('parseStepArgs', () => {
  it('reads the flag and its fields', () => {
    assert.deepEqual(parseStepArgs(['--accept-index-step', '--level=2290', '--approved-by=ops-lead', '--reason=devaluation']), {
      levelNgnPerUsd: 2290,
      approvedBy: 'ops-lead',
      reason: 'devaluation',
    });
    assert.equal(parseStepArgs(['--once']), null);
  });
});
