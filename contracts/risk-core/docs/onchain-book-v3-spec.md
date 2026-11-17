# OnchainBook v3: spec (draft, not implemented)

Drafted 2026-11-17 from three sources: a comparison with Phoenix's spline model
(docs.phoenix.trade, spline liquidity and matching engine) and the gas measured on 2026-11-17. Four changes, all
inside the book. The margin engine, `SubAccounts`, the assets and the taker interface (`IOnchainBook`) are unchanged.

## Measured baseline (v2)

- **Mainnet canary takes against #58:**
  - buy 5 EURC: 1,026,383 gas;
  - sell 5 EURC: 812,989 gas.
- **Fork `testGasPerTake`:** 1 maker 1,135,791; 10 makers 6,625,717. Each further maker costs ~610k.
- **The second maker's settlement, traced on the fork:**

| Part | Gas |
|---|---|
| The maker's margin check | 144,732 |
| **The taker's margin check, repeated in every maker's batch** | 141,406 |
| `SubAccounts` bookkeeping | ~156,400 |
| The future's hooks | 74,606 |
| **The fee leg, repeated per maker** (cash hooks 15k, the fee account #22's SRM 20k) | 34,534 |
| The book's own code | ~58,000 |

Traces: the two mainnet canary takes (`0xaae723ff…`, `0x5835bba9…`) with `debug_traceTransaction`.

## V3-1. One settlement batch, with fallback

**Today.** `_settleAll` sends one `submitTransfers` per maker: the position, then that maker's fee. Each batch is
wrapped in `try/catch`, so a failing maker is skipped (B5a). The taker sits in every batch, and `SubAccounts` calls
each account's manager once per batch, so the taker's margin is checked once per maker.

**v3 behaviour:**

- **One batch.** Build a single batch holding every filled maker's position transfer, plus **one** fee transfer from
  the taker to `feeRecipient` for the summed fee.
  - Per-maker fees are computed and rounded up exactly as now, then summed. Totals and every `Fill` event's `fee`
    stay identical to v2.
- **Gas floor.** Require `gasleft() >= gasFloor * filledMakers` before the batch.
- **On success:** write every maker's cursor, then emit the `Fill`s in maker order and `TakeExecuted`.
- **On revert:** apply the same out-of-gas rule as now (`OB_BatchOutOfGas`). Otherwise run v2's per-maker loop
  unchanged, so B5a's guarantee holds: one maker cannot freeze the side.
- **Cost of a failure.** A failing maker makes each take pay for the failed batch as well as the loop. Makers are
  allowlisted, and `poke`/`removeMaker` remove one that keeps failing. Emit `BatchFallback(marketId)` so the
  indexer and monitoring can count fallbacks.

**Expected saving:** ~141k plus the fee leg (~35k, plus its `SubAccounts` writes) for each maker after the first. My
estimate, not measured: each further maker costs ~400k instead of ~610k.

**Acceptance:**
- `testGasPerTake` logs a 10-maker take at **≤ 4.8M** gas.
- A test with one maker under initial margin among three makers:
  - the take fills the other two;
  - the fallback is emitted;
  - the fee totals equal v2's.

## V3-2. `refresh` flag on spline updates (Phoenix `refresh_regions`)

**Today.** Every `updateSplines` clears both cursors, so the full curve is available again after each update. At a
22 s refresh, a taker can take 3,012 EURC a side every ~25 s. The size applies per update, not in total.

**v3 behaviour:**

- **`SplineUpdate` gains `bool refresh`.**
  - `true`: the cursors are cleared, as today.
  - `false`: the cursors are kept. Consumed lots carry to the new mid and the new curve, counted from the top, and
    refill at `refillLotsPerSecond` as now.
- **Bot policy.**
  - Send `refresh = false` for refreshes and reprices.
  - Set `refillLotsPerSecond` so the whole curve takes a chosen time to refill (for example 3,012 lots in 5 min ≈
    10/s). This becomes the actual limit on how fast the maker's size can be taken.
  - Send `refresh = true` only after a deliberate change of the curve.

**ABI.** `SplineUpdate` changes shape, so `updateSplines`' selector changes. The bot already detects v1 and v2 by
selector, and adds v3. `IOnchainBook`, the router and the kit don't call `updateSplines`.

**Acceptance:** with `refresh = false`, two takes of a full side split across an update fill only what has refilled
between them.

## V3-3. On-chain long and short limits (Phoenix `max_position_size`)

**Today.** The cap lives in the bot: it switches to a park curve once a full fill would pass 5,000 lots. The cap
depends on the bot being alive and reading correctly. On chain, only margin stops a maker.

**v3 behaviour:**

- **Storage.** A `Limits { uint32 maxLongLots; uint32 maxShortLots; bool set; }` per market and account, set by the
  maker through `setLimits(marketId, accountId, long, short)`, which goes through `_authorize`.
  - It lives outside `Spline`, so the `splines()` getter, which the indexer and bot decode, keeps v1's layout.
  - A new `limits(marketId, accountId)` view reads it.
- **In `_loadMaker`,** with `pos` the position at the start of the take, as skew already uses:
  - bid capacity is `max(0, maxLong − pos)`;
  - ask capacity is `max(0, maxShort + pos)`;
  - `curveLotsLeft` is capped at that capacity, and the walk stops the side once it is used.
  - `quote`'s re-plan already counts pending lots in `pos`.
- **`0/0` means reduce-only,** as in Phoenix. **Unset** means no limit (v2's behaviour). `registerMaker` doesn't
  require limits: a maker sets them before its first update if it wants them.
- The bot sets the limits from `MM_BOOK_MAX_POSITION_LOTS` at preflight and keeps the park curve as a second guard
  for one release, then drops it.

**Acceptance:**
- At position 4,990 with a 5,000 long limit, a sell into the bid fills exactly 10 lots, in the same take and in
  `quote`.
- At 0/0 the maker only reduces.

## V3-4. Pro-rata between makers at the same price (Phoenix's split at a spline price)

**Today.** `_best` gives a tie to the maker registered first. That makes no difference with one maker, but it
always favours the incumbent once a second maker joins.

**v3 behaviour:**

- At the best price, collect every maker quoting it (at most `maxMakers`, 10).
- Give each `floor(levelLots_i × fillLots / totalLots)`. The leftover lots go one at a time in registration order.
- **`maxLevels`:** one price level counts as one, however many makers share it (Phoenix's `match_limit`).
- **Self-trade at a shared level:**
  - `Abort` reverts, as now;
  - `DecrementTake` excludes that maker and re-splits the level among the others.

**Acceptance:** two makers at the same price with 100 and 300 lots, take 200: they fill 50 and 150; take 3 lots
against two 1-lot makers and one 2-lot maker: the split is deterministic, and the result is identical in `quote`.

## Not in v3

- **Reserving margin for quotes in the engine,** Phoenix's model, which would skip the maker's ~145k check. That's a
  `MarginEngine` change and needs its own review.
- **An on-chain FIFO book.** Use Perpl's bitmap trees and slot reuse as the reference when it's wanted.
- **Hidden take size.** It only matters with a FIFO book to uncross against.
- **Regions as `[start, end)` × density.** This could be priced in O(1), but the curve's 10 discrete levels are
  enough for one maker.

## Compatibility and rollout

| Surface | Change |
|---|---|
| `IOnchainBook` (takers, the router, the kit) | None: `take`, `quote`, `markets`, `splines`, events and errors are unchanged. `BatchFallback` and `setLimits`/`limits` are additions |
| The matcher's indexer | A new `ONCHAIN_BOOK_V3` env name. `Fill` and `TakeExecuted` are unchanged, so decoding is unchanged |
| market-maker | v3 detection, `refresh`, `setLimits` at preflight, the refill rate |
| Deploy and proposer | `ARTIFACT_NAME` `ONCHAIN_BOOK_V3`; `--version 3`; the parity gates add the new settings |

**Rollout:** a new book per series, starting with the first series after the one `onchain-book-next-series-runsheet.md`
lists. No live book is migrated.

**Tests:**
- Each change gets the acceptance tests above.
- The fork gas test runs on v2 and v3.
- The v2 suite runs unchanged against v3 where the behaviour is meant to be the same.
- Mutation-test the guards as for v2.
