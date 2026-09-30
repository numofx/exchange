# perp-feeds

Price publishers for `USDCcNGN-PERP`. One process, one feed signer, one relayer:

- **Index.** Every minute, each USDT/NGN provider from
  [`cngn-rate-picker`](https://github.com/wrappedcbdc/cngn-rate-picker) (Quidax, Textile, Bybit P2P,
  and Blockradar when `BLOCKRADAR_API_KEY` is set) is queried. A sample is the **median**, and is
  refused if fewer than 3 sources answer or any source sits more than 150 bps from the median. Every
  5 minutes the 15-minute **time-weighted average** of accepted samples is inverted to USDC per cNGN,
  refused if it would move the on-chain index more than 300 bps, then signed and pushed.
- **Mark and impacts.** Every minute, the perp book from markets-service gives the mark (book mid)
  and impact prices (average fill for $1,000 each side), each clamped to the index ± 200 bps. A side
  without that depth reads as the index, so a thin book creates no funding premium. Published on a
  10 bps move or before 7 minutes have passed, whichever comes first.

**What the index measures.** No source quotes cNGN/USDC. Checked against the providers' code and
the venues' APIs on 2026-09-30:

| Source | Market | Quotes | Liquidity |
| --- | --- | --- | --- |
| Quidax (provider default) | `usdtcngn` | **cNGN** per USDT | thin: ~30 USDT a day |
| Blockradar | cNGN/USDT benchmark | **cNGN** per USDT | needs `BLOCKRADAR_API_KEY` |
| Textile | `USDT_NGN` | **fiat NGN** per USDT (Textile lists cNGN separately) | live |
| Bybit P2P | USDT ads in NGN | **fiat NGN** per USDT | blocked from some hosts |

The index therefore blends cNGN and fiat NGN per USDT, published as cNGN per USDC. That assumes
**cNGN ≈ NGN** and **USDT ≈ USDC**. A cNGN depeg from NGN, or a USDT/USDC spread, moves the real
market away from the index without moving the index, and funding and liquidations follow the index.
(Quidax's `cngnngn` market, cNGN per NGN, trades at ~0.9999: the peg is observable, not just assumed.)

The picker's own multi-source mode is not used: with `threshold > 1` it averages the first N
successes weighted by fetch-time gaps and never compares them, which is neither a median nor a
disagreement check. `src/index-aggregation.ts` says more.

## Failing closed

A publisher that refuses leaves the feed to go stale. A stale index makes `getSpot` revert, which
halts the perp's trading **and its liquidations** until a fresh value lands (heartbeat 20 minutes).
That is the design: an index nobody is sure of liquidates solvent traders; no index stops the market.
Every refusal alerts through `ALERT_WEBHOOK_URL`.

A real devaluation will trip the 300 bps jump guard too. Reopening is the index-step procedure in
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
# BLOCKRADAR_API_KEY=...   # a fourth source; needed if Bybit P2P is unreachable from the host
```

Then install `contracts/risk-core/scripts/ops/numo-perp-feeds-ssm.service`. Dry run first:

```bash
DRY_RUN=true node dist/main.js --once
```

The index needs `INDEX_MIN_WINDOW_SAMPLES` (10) accepted samples before its first publish, so the
first index lands ~10 minutes after a cold start. Samples persist in `INDEX_STATE_FILE`, so a
restart does not wait again.

## Tests

```bash
pnpm test                                        # decisions: refusals, median, TWAP, clamps
anvil --port 8599 &
(cd ../../contracts/risk-core && forge build)
ANVIL_RPC_URL=http://127.0.0.1:8599 pnpm test    # + the real feed contracts accept what we sign
```
