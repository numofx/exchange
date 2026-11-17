# OnchainBook run-sheet: the next EURC series keeps C0 test 3 passing (draft)

Drafted 2026-11-17. **Nothing here has been sent.** Each sending step is its own go-ahead.

EURC-30NOV26 stops trading on Mon 2026-11-30 at 14:30 UTC, and both makers' cutoff takes their quotes down at 13:30.
From then on, C0 test 3 (an outside contract reaches all the venue's liquidity in one transaction, with no off-chain
party) passes only if a listed series has our maker's size on a book. That takes a listed next series, a book market
on it, and the maker moved across, all before 30 Nov 13:30.

## Decided (owner, 2026-11-17: all three as recommended)

| | Decision | Why |
|---|---|---|
| **N1. Next series** | **EURC-31DEC26**: expiry Thu 2026-12-31 15:00 UTC (`1798729200`), last trade 14:30 (`1798727400`) | The same month-end pattern as 30NOV26. New Year's Eve is thin, but the fixing is the index's TWAP, not a traded price |
| **N2. Book code** | **The current v2 book, as market 2.** v3 (`onchain-book-v3-spec.md`) from the series after | Market 2 needs no deploy, no new indexer entry (the matcher maps any market on a book to its series through `markets(id)`) and no bot release. v3 changes the code that holds the maker's account: listing a series and changing the book in the same week puts two changes on the path that keeps test 3 passing |
| **N3. The overlap** | **One maker, moved from market 1 to market 2 on ~27 Nov.** 30NOV26 keeps the v1 book's 60-EURC canary (#56) until its cutoff | Two bots from the MM wallet would collide on nonces, and the bot quotes one market. OI on 30NOV26 is only ours (#40's 2-EURC short), so its last three days lose nothing |

*Correction to my earlier note:* I said shipping v3 with the next series "avoids migrating a live book". It doesn't.
With either code, a series gets a market of its own and no maker moves between books mid-series, so waiting for the
January series costs nothing.

## Critical path: the series must be listed first

The book's `createMarket` refuses an unlisted series. **Listing EURC-31DEC26 has its own run-sheet,
`eurc-31dec26-listing-runsheet.md` (L1–L8).** In short:

- **Vault:** `FutureAsset` v3 `setContract(1798729200, 1798727400, <initial mark>)`. It takes the fixing parameters
  in force now, permanently: re-read `seriesFixing` for 30NOV26 and confirm they are wanted before listing. The
  engine's position cap is per asset, not per series, and is already above 0.
- **Instruments registry:** the series with `taker_fee_bps` 5. The enable gate reads the fee from `/markets`.
- **Keeper:** a `numo-future-feeds-v3@eurc-31dec26` instance for marks, the fixing and close-out. Report posting is
  per adapter and already running: check that two instances don't both post, or accept the double cost until 30 Nov.
- **Matcher and app:** `FUTURE_SERIES` gains EURC-31DEC26 (a matcher redeploy, `with-matcher-mute.sh`). The
  settlement canary and `report-age` need no change, because the adapter is shared.

**Target:** listed by Tue 24 Nov, so the book steps run 25–27 Nov with a working day to spare.

## Steps (N2 = market 2 on the v2 book)

| # | Step | Sends | Done when |
|---|---|---|---|
| 0 | Series listed (separate run-sheet) | vault | `futureContracts(subId)` listed, unsettled; `/markets` lists it with 5 bps |
| 1 | **Tooling.** `propose_onchain_book_batch.py` takes `--market N` (today `BOOK_MARKET = 1` is a constant), with a `book-add-market` batch: `createMarket(future, subId, engine v2, adapter, 1e12, 1e15)`, `setMarketParams(N, 5 bps, takeMaxAge, maxTtl, 10, false)`, `setSelfPricedTtlCap(N, 60)`. Gates as for setup, on market N. Self-tested, plus an anvil rehearsal against the live book | nothing | Committed; the rehearsal opens market 2 and a fork take fills against it |
| 2 | **Add the market** (`book-add-market --market 2 --propose`) | vault | `nextMarketId` = 3; market 2 on subId `1798729200`, disabled; ttl cap 60 |
| 3 | **Register #58 on market 2** (`registerMaker(2, 58)` from the MM wallet). Allowances are per book, not per market, so #58's existing ones cover it | MM wallet | `makers(2) = [58]` |
| 4 | **Enable** (`book-enable --market 2 --propose`) | vault | `markets(2).enabled`; the index and fee gates pass |
| 5 | **Move the maker** (N3): `MM_BOOK_MARKET_ID` 2 and `MM_BOOK_REFERENCE_MARKET_ID` to 31DEC26's forward market in `market-maker-book-v2.tf`; apply; `wait-for-rollout.sh`. The old task's SIGTERM cancels market 1's spline | ECS | `preflight ok` on market 2; `splines(2,58)` live; `splines(1,58)` inactive |
| 6 | **Canary on market 2:** #57 takes 5 and back with no reports, directly and through the router | taker | Fills on the tape as `source: book`, with 31DEC26's symbol |
| 7 | **Check C0 test 3:** `quote` with no account reaches 3,012 a side on market 2 | nothing | As on 17 Nov |
| 8 | **Write back** the same day: `OPS_BOX_CHANGES.md`, this sheet, the expiry run-sheet's "After" | — | — |

- **Before step 5:** confirm the bot's preflight accepts a market other than 1, and that the park curve's band check
  reads market 2's expiry. Both are read from `MM_BOOK_MARKET_ID`; rehearse on anvil.
- **Gas:** unchanged, because one bot sends from one wallet. At 0.002 ETH/day the MM wallet's 0.0296 lasts to ~2 Dec:
  **fund ~0.03 ETH before 30 Nov.**

## If N2 is v3 instead

Steps 2–4 become a deploy plus setup and enable, as in `onchain-book-v2-runsheet.md`. Three further pieces of work
come first:
- the v3 code and its review;
- a `ONCHAIN_BOOK_V3` env name in the matcher's indexer (`services/markets/internal/config/config.go`
  `onchainBookEnvNames`), deployed through `with-matcher-mute.sh`;
- a market-maker release that encodes v3's `SplineUpdate`.

Realistically that is 4–6 working days before step 2, so on this timeline it would likely miss 30 Nov.
