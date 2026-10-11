# perp-feeds

Price publishers for `USDCcNGN-PERP` (`dist/main.js`: one process, one feed signer, one relayer),
and, as a separate process, the forward publisher for the cNGN future (`dist/forward-main.js`,
[below](#forward-publisher-cngn-future)). The perp publishers:

- **Index.** Every minute, three fiat USDT/NGN providers from
  [`cngn-rate-picker`](https://github.com/wrappedcbdc/cngn-rate-picker) (Quidax `usdtngn`, Textile,
  Bybit P2P) are queried. A sample is the **median**, and is
  refused if fewer than 3 sources answer or any source sits more than 150 bps from the median. Every
  minute the 5-minute **time-weighted average** of accepted samples is inverted to USDC per cNGN,
  refused if it would move the on-chain index more than 150 bps, then signed and pushed (15 min /
  5 min / 300 bps until 2026-10-03; tightened by the leverage study so a step is in the index within
  5 minutes and the keeper sees several publishes between maintenance margin and zero equity).
  Every spot sample is also reported to markets-service (`INDEX_STATUS_PUSH_URL`,
  `INDEX_STATUS_TOKEN` from SSM `/numo/feeds/index_status_token`), whose index-lag gate refuses new
  perp orders while spot sits more than 100 bps from the on-chain index, or while no fresh sample
  has arrived.
- **Mark and impacts.** Every minute, the perp book from markets-service gives the mark (book mid)
  and impact prices (average fill for $1,000 each side), each clamped to the index ± 200 bps. A side
  without that depth reads as the index, so a thin book creates no funding premium. Published on a
  10 bps move or before 7 minutes have passed, whichever comes first.

**What the index measures: fiat NGN, at cNGN's redemption parity.** cNGN is held at 1 NGN by
redemption, not by trading, so each source's fiat NGN per USDT is used as cNGN per USDT unconverted
(`src/index-sources.ts`). There are exactly 3 sources and no spare.

**The peg tripwire** (`src/peg.ts`) is not a source: a 15-min TWAP of Quidax `cngnngn` book mids.
Past 100 bps from parity it refuses every sample and the status file (`INDEX_STATUS_FILE`) records
`pegGuardTripped` for the pager. With no peg sample in 15 minutes it is blind: the index carries on
at parity and a `peg-blind` alert fires. USDT is taken as USDC. The full section is in
`contracts/risk-core/docs/cngn-perp-go-live.md`.

The picker's own multi-source mode is not used: with `threshold > 1` it averages the first N
successes weighted by fetch-time gaps and never compares them, which is neither a median nor a
disagreement check. `src/index-aggregation.ts` says more.

## Failing closed

A publisher that refuses leaves the feed to go stale. A stale index makes `getSpot` revert, which
halts the perp's trading **and its liquidations** until a fresh value lands (heartbeat 20 minutes).
That is the design: an index nobody is sure of liquidates solvent traders; no index stops the market.
Every refusal alerts through `ALERT_WEBHOOK_URL`.

A real devaluation will trip the 150 bps jump guard too. Reopening is the index-step procedure in
`contracts/risk-core/docs/cngn-perp-go-live.md`: `--accept-index-step --level=… --approved-by=…
--reason=…` publishes the sources' TWAP once. It refuses without a live keeper, or if the sources
disagree with the confirmed level, and it writes an audit record. There is no env override.

`--probe-sources` asks each provider once and reports which answered. It signs nothing. Run it on
the publisher's host before launch: the index needs 3.

A refresh is a recompute, never a re-sign. When a feed is republished because it is getting old,
the mark and impacts are rebuilt from the current index and book and clamped again, and the index
is a fresh TWAP through the jump guard. The index also refuses when its newest accepted sample is
older than `INDEX_MAX_SAMPLE_AGE_MS` (3 minutes): a window still "full" of older samples after the
sources stopped agreeing is not republished. `src/publishers.test.ts` pins both.

## Local only: `--local-fixed-price`

`node dist/main.js --local-fixed-price=1374` publishes a constant index (1374 cNGN per USDC) with zero
mark and impact diffs, every `MARK_INTERVAL_MS`, and nothing else. It skips every guard above, so it
asks the RPC for its chain id and refuses unless both that and `CHAIN_ID` are 31337; Base (8453) and
Base Sepolia (84532) are refused by name. It exists for `scripts/local-venue`.

## Running

Secrets come from SSM through `run-with-ssm.sh` (`RPC_URL`, `FEED_SIGNER_KEY`, `RELAYER_KEY`,
`ALERT_WEBHOOK_URL` from `/numo/feeds/*`) — the revived cNGN signer `0xdA1976…918f`, relayed by
`0xC9F1…0FDc`. The relayer ran dry on 2026-09-11; fund it before starting. `check_signer_balance.py`
already watches it.

Put the addresses from `risk-core/deployments/8453/CNGN_PERP_STACK.json` in `/etc/numo/perp-feeds.env`:

```bash
DATA_SUBMITTER=0xe0C06DD245f1e8C8bC516c66C66e64648987F912   # core.json dataSubmitter
PERP_ASSET=<perp>
INDEX_FEED=<indexFeed>
MARK_FEED=<markFeed>
IMPACT_ASK_FEED=<impactAskFeed>
IMPACT_BID_FEED=<impactBidFeed>
INDEX_STATE_FILE=/var/lib/numo/perp-index-state.json
```

Then install `contracts/risk-core/scripts/ops/numo-perp-feeds-ssm.service`. Dry run first:

```bash
DRY_RUN=true node dist/main.js --once
```

The index needs `INDEX_MIN_WINDOW_SAMPLES` (5) accepted samples before its first publish, so the
first index lands ~5 minutes after a cold start. Samples persist in `INDEX_STATE_FILE`, so a
restart does not wait again.

## Tests

```bash
pnpm test                                        # decisions: refusals, median, TWAP, clamps
anvil --port 8599 &
(cd ../../contracts/risk-core && forge build)
ANVIL_RPC_URL=http://127.0.0.1:8599 pnpm test    # + the real feed contracts accept what we sign
```

## Forward publisher (cNGN future)

`dist/forward-main.js` marks a USDC/cNGN `FutureAsset`. Each tick, once the contract's
`minMarkInterval` (an hour) has passed and until last trade, it:

1. works out the forward in cNGN per USDC (`src/forward-targets.ts`): the futures book's mid if it is
   two-sided, else the carry forward `index × (1 + CARRY × τ)`, then clamps it to the carry forward
   ± `FORWARD_MAX_BASIS_BPS`, inside the contract's current index band, and inside its per-mark move
   limit (both less `FORWARD_SAFETY_BPS`). If the band and the move limit cannot both be met, it
   publishes nothing and alerts `forward-unreachable`;
2. signs `forward − index` (USDC per cNGN) into the future's `LyraForwardFeed` and relays it;
3. calls `FutureAsset.pullMark`, which reads it back, checks it again, and accrues VM.

**Its own process, signer and relayer.** The forward key must not sign the index: the contract
bands every mark against the index, which only bounds a bad forward if someone else signs it (the
deploy script refuses one key for both). The signer is a **KMS key** (`FORWARD_SIGNER_KMS_KEY_ID`,
`aws_kms_key.forward_signer`), so its private key never reaches the box; a raw `FORWARD_SIGNER_KEY`
is refused on Base mainnet. The relayer is its own too (`/numo/feeds/forward_relayer_key`): one
relayer shared by two processes races for nonces.

**Expiry** (`src/expiry-keeper.ts`, the same process, every tick after the publisher), with nothing
but permissionless calls, each reading its state back from the chain first so a restart resumes:

1. in the contract's `fixingWindow` (1 h) it records an index sample every `FIXING_SAMPLE_INTERVAL_MS`
   (5 min), at most half the contract's `maxSampleGap` so one failed sample cannot break the fixing
   (it refuses to start otherwise; a failed sample alerts `fixing-sample-failed`);
2. after expiry it calls `fixSettlementFromIndex`. If the fixing is incomplete it alerts
   `fixing-incomplete`, then `fixing-fallback-due` once the vault's bounded fallback opens;
3. once settled it calls `FutureManager.closeOutExpired` on every account still holding the series
   (it walks `SubAccounts.lastAccountId`; Base has a few dozen), `CLOSE_OUT_BATCH` per tick. Close-out
   reads no feed, so it works with the index down.

It alerts `forward-mark-late` when the contract's last mark is older than `FORWARD_MARK_LATE_MS`
(2 h) while trading is open, and on every refusal. Config: `src/forward-config.ts`. Unit:
`numo-future-feeds.service`, secrets through `run-with-ssm-forward.sh`, non-secret config in
`/etc/numo/future-feeds.env` (template `contracts/risk-core/scripts/ops/future-feeds.env`). Not
installed: nothing it marks is deployed yet.

`src/forward.anvil.e2e.test.ts` runs it against the real `LyraSpotFeed`, `LyraForwardFeed`,
`FutureAsset` and `OracleDataSubmitter` on anvil, and `src/expiry.anvil.e2e.test.ts` runs a real fixing
on `FutureAsset`. The anvil suites share one chain clock, so `pnpm test` runs test files one at a time
(`--test-concurrency=1`): concurrently, one suite's `evm_increaseTime` expires another's signatures or
skips its fixing window.
