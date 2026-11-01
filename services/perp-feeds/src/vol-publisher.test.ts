import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { decodeAbiParameters, keccak256, toHex, type Address, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

import type { ContractChain } from './chain.js';
import { loadVolConfig } from './vol-config.js';
import { levels, uncertaintyReasons, VolPublisher } from './vol-publisher.js';
import { buildSvi, ONE, sviVol } from './vol-surface.js';

const VOL_FEED = '0x00000000000000000000000000000000000000B1' as Address;
const EXPIRY = 1_796_047_200n;
const NOW_SEC = EXPIRY - 29n * 86_400n;
const FWD = 721_748_919_677_396n;
const STATUS = '/status.json';
const STEPS = '/steps.jsonl';

const ENV = {
  RPC_URL: 'http://127.0.0.1:8545',
  CHAIN_ID: '84532',
  RELAYER_KEY: keccak256(toHex('relayer')),
  VOL_SIGNER_KEY: keccak256(toHex('vol-signer')),
  DATA_SUBMITTER: '0x00000000000000000000000000000000000000A0',
  VOL_FEED,
  FORWARD_FEED: '0x00000000000000000000000000000000000000A2',
  INDEX_FEED: '0x00000000000000000000000000000000000000A3',
  ENGINE: '0x00000000000000000000000000000000000000E2',
  EXPIRY: String(EXPIRY),
  VOL_ATM: '400000000000000000',
  VOL_DEGRADED_ATM_FLOOR: '800000000000000000',
  INDEX_STATUS_FILE: STATUS,
  INDEX_STEP_AUDIT_FILE: STEPS,
};
const config = loadVolConfig(ENV);

type State = {
  headSec: bigint;
  nowMs: number;
  files: Record<string, string>;
  index: bigint | null;
  forward: bigint | null;
  heartbeat?: bigint;
  signerAccepted?: boolean;
  optionThreshold?: bigint;
  engineVol?: Address;
  /** what the feed reads back; by default exactly what was last submitted */
  readBack?: { vol: bigint; confidence: bigint };
  submitFails?: boolean;
};

function harness(state: State) {
  const submitted: Hex[] = [];
  const alerts: string[] = [];
  let lastSvi: ReturnType<typeof decodeSvi> | null = null;
  const chain: ContractChain = {
    signer: privateKeyToAccount(keccak256(toHex('vol-signer'))),
    relayer: privateKeyToAccount(keccak256(toHex('relayer'))),
    chainId: 84532,
    headTimestamp: async () => state.headSec,
    readIndex: async () => state.index,
    readDiffFeed: async () => null,
    submit: async (data) => {
      if (state.submitFails) throw new Error('nonce too low');
      submitted.push(data);
      lastSvi = decodeSvi(data);
      return '0xaa';
    },
    write: async () => '0xbb',
    read: async <T,>(_address: Address, _abi: unknown, functionName: string): Promise<T> => {
      switch (functionName) {
        case 'heartbeat':
          return (state.heartbeat ?? 1_800n) as T;
        case 'isSigner':
          return (state.signerAccepted ?? true) as T;
        case 'oracleContingencyParams':
          return [55n * 10n ** 16n, state.optionThreshold ?? 8n * 10n ** 17n, 55n * 10n ** 16n, ONE] as T;
        case 'getMarketFeeds':
          return ['0x01', '0x02', state.engineVol ?? VOL_FEED] as T;
        case 'getForwardPrice':
          if (state.forward === null) throw new Error('SRM_NoForwardPrice');
          return [state.forward, ONE] as T;
        case 'getVol': {
          if (state.readBack) return [state.readBack.vol, state.readBack.confidence] as T;
          const s = lastSvi!;
          return [sviVol(s, 0n), s.confidence] as T;
        }
        case 'getExpiryMinConfidence':
          return (state.readBack?.confidence ?? lastSvi!.confidence) as T;
        default:
          throw new Error(`unexpected read ${functionName}`);
      }
    },
  };
  const written: Record<string, string> = {};
  const publisher = new VolPublisher(
    config,
    chain,
    async (key) => {
      alerts.push(key);
    },
    () => state.nowMs,
    async (path) => {
      if (!(path in state.files)) throw new Error(`ENOENT ${path}`);
      return state.files[path];
    },
    async (path, body) => {
      written[path] = body;
    },
  );
  return { publisher, submitted, alerts, written, last: () => lastSvi };
}

/** The SVI inside an OracleDataSubmitter batch, as the chain would decode it. */
function decodeSvi(managerData: Hex) {
  const [updates] = decodeAbiParameters(
    [{ type: 'tuple[]', components: [{ name: 'receiver', type: 'address' }, { name: 'data', type: 'bytes' }] }],
    managerData,
  );
  const [feedData] = decodeAbiParameters(
    [
      {
        type: 'tuple',
        components: [
          { name: 'data', type: 'bytes' },
          { name: 'deadline', type: 'uint256' },
          { name: 'timestamp', type: 'uint64' },
          { name: 'signers', type: 'address[]' },
          { name: 'signatures', type: 'bytes[]' },
        ],
      },
    ],
    updates[0].data,
  );
  const [expiry, a, b, rho, m, sigma, fwd, refTau, confidence] = decodeAbiParameters(
    [
      { type: 'uint64' },
      { type: 'int256' },
      { type: 'uint256' },
      { type: 'int256' },
      { type: 'int256' },
      { type: 'uint256' },
      { type: 'uint256' },
      { type: 'uint64' },
      { type: 'uint64' },
    ],
    feedData.data,
  );
  return { receiver: updates[0].receiver, expiry, a, b, rho, m, sigma, fwd, refTau, confidence };
}

const NOW_MS = Number(NOW_SEC) * 1000;
const healthy = () => JSON.stringify({ at: NOW_MS - 30_000, pegGuardTripped: false, sample: { ok: true } });

function state(overrides: Partial<State> = {}): State {
  return { headSec: NOW_SEC, nowMs: NOW_MS, files: { [STATUS]: healthy() }, index: FWD, forward: FWD, ...overrides };
}

describe('vol uncertainty', () => {
  const base = { stepLog: null, indexOnChain: FWD, nowMs: NOW_MS, maxAgeMs: 300_000, stepDegradeMs: 86_400_000 };

  it('is certain on a fresh, clean status and a readable index', () => {
    assert.deepEqual(uncertaintyReasons({ ...base, status: JSON.parse(healthy()) }), []);
  });

  it('degrades on each signal', () => {
    const cases: [Parameters<typeof uncertaintyReasons>[0], RegExp][] = [
      [{ ...base, status: null, statusError: 'ENOENT' }, /unreadable/],
      [{ ...base, status: { at: NOW_MS - 600_000, pegGuardTripped: false, sample: { ok: true } } }, /silent/],
      [{ ...base, status: { at: NOW_MS, pegGuardTripped: true, sample: { ok: true } } }, /peg tripwire/],
      [{ ...base, status: { at: NOW_MS, pegGuardTripped: false, sample: { ok: false, reason: 'sources disagree' } } }, /sources disagree/],
      [{ ...base, status: JSON.parse(healthy()), indexOnChain: null }, /chain index/],
      [
        {
          ...base,
          status: JSON.parse(healthy()),
          stepLog: `${JSON.stringify({ event: 'index-step', status: 'approved', at: new Date(NOW_MS - 60_000).toISOString() })}\n` +
            `${JSON.stringify({ event: 'index-step', status: 'published', at: new Date(NOW_MS - 60_000).toISOString() })}\n`,
        },
        /index step published 1 min ago/,
      ],
    ];
    for (const [args, reason] of cases) {
      const reasons = uncertaintyReasons(args);
      assert.equal(reasons.length, 1, JSON.stringify(reasons));
      assert.match(reasons[0], reason);
    }
  });

  it('forgets an index step after the window, and ignores approvals and a torn line', () => {
    const old = JSON.stringify({ event: 'index-step', status: 'published', at: new Date(NOW_MS - 2 * 86_400_000).toISOString() });
    const approved = JSON.stringify({ event: 'index-step', status: 'approved', at: new Date(NOW_MS).toISOString() });
    assert.deepEqual(uncertaintyReasons({ ...base, status: JSON.parse(healthy()), stepLog: `${old}\n${approved}\n{"event":"ind` }), []);
  });

  it('never publishes cheaper when degraded', () => {
    assert.deepEqual(levels(config, { mode: 'normal' }), { atmVol: 4n * 10n ** 17n, confidence: ONE });
    assert.deepEqual(levels(config, { mode: 'degraded', reasons: ['x'] }), { atmVol: 8n * 10n ** 17n, confidence: 5n * 10n ** 17n });
  });
});

describe('vol publisher', () => {
  it('publishes the set surface at full confidence, signed for the vol feed, and reads it back', async () => {
    const h = harness(state());
    assert.equal(await h.publisher.tick(), 'published');
    const svi = h.last()!;
    assert.equal(svi.receiver, VOL_FEED);
    assert.equal(svi.expiry, EXPIRY);
    assert.equal(svi.confidence, ONE);
    assert.equal(svi.fwd, FWD);
    const expected = buildSvi({
      expiry: EXPIRY,
      nowSec: NOW_SEC - 15n,
      atmVol: 4n * 10n ** 17n,
      shape: { bMult: 2n * ONE, rho: -5n * 10n ** 17n, sigma: 10n ** 17n },
      fwd: FWD,
      confidence: ONE,
    });
    assert.deepEqual([svi.a, svi.b, svi.rho, svi.m, svi.sigma, svi.refTau], [expected.a, expected.b, expected.rho, expected.m, expected.sigma, expected.refTau]);
    assert.deepEqual(h.alerts, []);
    assert.equal(JSON.parse(h.written['./vol-status.json']).mode, 'normal');
  });

  it('waits for the interval, but publishes at once when the mode changes, and alerts each way', async () => {
    const s = state();
    const h = harness(s);
    await h.publisher.tick();
    s.nowMs += 60_000;
    assert.equal(await h.publisher.tick(), 'not-due');

    s.files[STATUS] = JSON.stringify({ at: s.nowMs, pegGuardTripped: true, sample: { ok: true } });
    assert.equal(await h.publisher.tick(), 'published', 'degraded at once');
    assert.equal(h.last()!.confidence, 5n * 10n ** 17n);
    assert.ok(sviVol(h.last()!, 0n) > 79n * 10n ** 16n, 'at the floor');
    assert.deepEqual(h.alerts, ['vol-degraded']);

    s.nowMs += 60_000;
    s.files[STATUS] = JSON.stringify({ at: s.nowMs, pegGuardTripped: false, sample: { ok: true } });
    assert.equal(await h.publisher.tick(), 'published', 'recovered at once');
    assert.equal(h.last()!.confidence, ONE);
    assert.deepEqual(h.alerts, ['vol-degraded', 'vol-recovered']);
  });

  it('degrades, and still publishes, when the index publisher is silent', async () => {
    const h = harness(state({ files: {} }));
    assert.equal(await h.publisher.tick(), 'published');
    assert.equal(h.last()!.confidence, 5n * 10n ** 17n);
  });

  it('fails closed, alerting, when it cannot publish: no forward, or a failed relay', async () => {
    const noFwd = harness(state({ forward: null }));
    assert.equal(await noFwd.publisher.tick(), 'no-forward');
    assert.deepEqual(noFwd.alerts, ['vol-no-forward']);
    assert.equal(noFwd.submitted.length, 0);

    const relay = harness(state({ submitFails: true }));
    assert.equal(await relay.publisher.tick(), 'publish-failed');
    assert.deepEqual(relay.alerts, ['vol-publish-failed']);
    // and it tries again next tick: a failed publish is not counted as one
    assert.equal(await relay.publisher.tick(), 'publish-failed');
  });

  it('alerts when the feed does not read back what was published', async () => {
    const h = harness(state({ readBack: { vol: 2n * 10n ** 17n, confidence: ONE } }));
    assert.equal(await h.publisher.tick(), 'published');
    assert.deepEqual(h.alerts, ['vol-readback-mismatch']);
  });

  it('stops at expiry: the feed refuses data stamped after it', async () => {
    const h = harness(state({ headSec: EXPIRY + 15n }));
    assert.equal(await h.publisher.tick(), 'expired');
    assert.equal(h.submitted.length, 0);
  });

  it('signs nothing on a dry run', async () => {
    const h = harness(state());
    const dry = new VolPublisher(loadVolConfig({ ...ENV, DRY_RUN: 'true' }), (h.publisher as unknown as { chain: ContractChain }).chain,
      async () => {}, () => NOW_MS, async () => healthy(), async () => {});
    assert.equal(await dry.tick(), 'dry-run');
    assert.equal(h.submitted.length, 0);
  });

  it('refuses to start on a configuration that cannot work', async () => {
    await harness(state()).publisher.checkStartup();
    await assert.rejects(harness(state({ heartbeat: 600n })).publisher.checkStartup(), /third of the feed's heartbeat/);
    await assert.rejects(harness(state({ signerAccepted: false })).publisher.checkStartup(), /does not accept signer/);
    await assert.rejects(harness(state({ optionThreshold: 5n * 10n ** 17n })).publisher.checkStartup(), /degrading would cost nothing/);
    const unattached = harness(state({ engineVol: '0x00000000000000000000000000000000000000C9' }));
    await unattached.publisher.checkStartup();
    assert.deepEqual(unattached.alerts, ['vol-feed-not-attached']);
  });
});

describe('vol config', () => {
  it('refuses a raw signer on mainnet, a slipped unit, a floor under the level, and a non-surface', () => {
    assert.throws(() => loadVolConfig({ ...ENV, CHAIN_ID: '8453' }), /must be a KMS key/);
    assert.throws(() => loadVolConfig({ ...ENV, VOL_ATM: '40' }), /VOL_ATM/);
    assert.throws(() => loadVolConfig({ ...ENV, VOL_DEGRADED_ATM_FLOOR: '300000000000000000' }), /never cheapens/);
    assert.throws(() => loadVolConfig({ ...ENV, VOL_DEGRADED_CONFIDENCE: '1000000000000000000' }), /inside \(0, 1\)/);
    assert.throws(() => loadVolConfig({ ...ENV, VOL_RHO: '-1000000000000000000' }), /RHO/);
    assert.throws(() => loadVolConfig({ ...ENV, VOL_SIGNER_KMS_KEY_ID: 'arn:x' }), /exactly one/);
  });
});
