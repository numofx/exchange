# 30NOV26 roll checklist (draft, 2026-11-21)

Both live futures stop on Mon 2026-11-30: **cNGN-30NOV26 expires 14:00 UTC (last trade 13:00: its future's fixing window
is 3,600 s), EURC-30NOV26 15:00 UTC (last trade 14:30)**; each book maker's cutoff takes its quotes down an hour before
its last trade. The app now trades futures only
through the OnchainBooks (BookTakeModule and BookCustodian), so after expiry it has nothing to trade unless each
next series has a **book market with the maker's size on it**.

**Nothing in this checklist has been sent.** Each sending step is its own go-ahead.

## What needs no change (checked 2026-11-21)

- **BookCustodian and BookTakeModule** allow by **book**, not by market. A take names `(book, marketId)` and the
  custodian reads the series from `book.markets(marketId)`, so market 2 on an already-allowed book is covered.
- **The app** finds each series' book and market on `GET /book-depth` (`market_id`): a later series is a later market,
  with no app change. It lists whatever `/markets` lists.
- **The matcher** indexes any market on an indexed book to its series (`markets(id)`).
- **Gas:** cNGN maker wallet 0x7b96…bE4d burns ~0.00007 ETH/day (0.0067 left); MM wallet 0x3448…B47B ~0.00016/day
  (0.023 left). Both last well past December since the makers moved to SolidRPC. The old "fund 0.03 ETH" note is
  superseded.

## EURC: 30NOV26 → 31DEC26 (planned; listing done)

Run-sheets: `eurc-31dec26-listing-runsheet.md`, `onchain-book-next-series-runsheet.md`, `eurc-30nov26-expiry-runsheet.md`.

| # | Step | State | Sends |
|---|---|---|---|
| E1 | List EURC-31DEC26 on the v3 future (L4) | **done 2026-11-18** (mark 1.099240) | vault |
| E2 | Keeper `future-feeds-v3@eurc-31dec26` (L5) | **live 2026-11-19** | box |
| E3 | `/markets` entry, 5 bps (L6) | **done** (on `/markets` now) | infra |
| E4 | `book-add-market --market 2 --expiry 1798729200` on the v2 book | not sent | vault |
| E5 | `registerMaker(2, 58)` | not sent | MM wallet |
| E6 | `book-enable --market 2` | not sent | vault |
| E7 | Move #58 to market 2 (`MM_BOOK_MARKET_ID` 2, reference market → 31DEC26's) ~27 Nov; rehearse the preflight on anvil first | not sent | ECS apply |
| E8 | Canary take on market 2 (direct and through custody), C0 test 3 `quote` | — | taker |
| E9 | 30 Nov: expiry run-sheet (fixing window 14:30–15:00, close-out) | — | keeper |

**Changed since the run-sheet:** the v1 book maker (#56) was retired 2026-11-21, so 30NOV26 has no canary quote on the
v1 book; #58 is its only maker. Moving #58 on ~27 Nov therefore leaves 30NOV26 with no quotes for its last ~3 days
(our own position is the only OI). **Decided (owner, 2026-11-21): move at 30NOV26's cutoff** (30 Nov ~12:00 UTC for
#60, ~13:30 for #58: right after each bot's cutoff, an hour before its series' last trade, takes its quotes down), so 30NOV26 stays quoted to the end and
31DEC26 is quoted from expiry day. Both new markets must be enabled and canaried before then.

## cNGN: 30NOV26 → next series (no run-sheet yet: decisions first)

cNGN-30NOV26 is on MarginEngine v2's FutureAsset `0xcacee66a…9aa75` (contract size 1,000,000 cNGN, forward feed
`0x2447…`), quoted only on the adapter-less cNGN book `0x5a35…8Bd4` (market 1) by #60. Fee 15 bps.

**Decided (owner, 2026-11-21: as recommended):** cNGN-31DEC26 at 14:00 UTC, 15 bps; both makers move at their
30NOV26 cutoff (below).

| | Question | Decision |
|---|---|---|
| C-a | Roll cNGN at all? | Yes: it is the venue's own market and custody trading now depends on it |
| C-b | Next expiry | **cNGN-31DEC26, Thu 2026-12-31 14:00 UTC** (`1798725600`), last trade 13:00 (expiry − the future's 3,600 s fixing window): the 30NOV26 pattern, an hour before EURC's. It must differ from EURC's `1798729200`: the engine holds close-out until every market listing an expiry has fixed (the `series` gate) |
| C-c | Fee | 15 bps, as now |
| C-d | When #60 moves | **At 30NOV26's cutoff**, as E7 |

**Then (sketch, to become `cngn-31dec26-listing-runsheet.md`):**

| # | Step | Sends |
|---|---|---|
| C1 | **Done 2026-11-21.** `propose_margin_engine_v2_batch.py list --expiry 1798725600`: `setContract(E, E − 3600, M)` on FutureAssetV2 (no per-series fixing parameters in this version: they are the future's). Gates: custody, schedule (≥ 7 days), series (no other market at E), forward (maxExpiry), mark (inside `markIndexBand(E)`, within 1% of the carry forward). Self-tested (calldata pinned to `cast calldata`; the series gate broken goes red); live dry run all PASS at M = 0.000685579; anvil fork: the vault's call lands (73,771 gas), reads back listed with last trade `1798722000`, 30NOV26 untouched, a second send reverts `FA_InvalidSchedule` | nothing |
| C2 | Keeper env `future-feeds-v2-cngn-31dec26.env` (copy of 30NOV26's, new `FUTURE_SUB_ID`), `DRY_RUN=true` | nothing |
| C3 | List | vault |
| C4 | Keeper live on the box; first forward mark read back; `DRY_RUN=false` | box |
| C5 | `future_series` entry in `variables.tf` (15 bps); markets deploy (merge main, read env deltas) | infra |
| C6 | `propose_onchain_book_batch.py --book cngn book-add-market --market 2 --expiry E`: confirm `--market` works with `--book cngn` (today it is exercised only on the EURC v2 book) | vault |
| C7 | `registerMaker(2, 60)` from 0x7b96…bE4d; `book-enable --book cngn --market 2` | maker wallet, vault |
| C8 | Move #60 (`MM_BOOK_MARKET_ID` 2 in `market-maker-book-cngn.tf`) | ECS apply |
| C9 | Canary take through custody; tape shows the new symbol | taker |
| C10 | `cngn-30nov26-expiry-runsheet.md` (none exists): fixing on the cNGN index, close-out, settlement in USDC | — |

## Timeline (target)

| Day | |
|---|---|
| Sat 21 – Mon 23 Nov | Owner decides C-a…C-d and the E7 timing; C1–C2 built and rehearsed |
| Tue 24 Nov | C3 list cNGN-31DEC26; E4–E6 on the EURC v2 book |
| Wed 25 Nov | C4–C7; E8 canary on EURC market 2 |
| Thu 26 – Fri 27 Nov | Anvil rehearsal of the maker move (preflight on market 2); C9; both expiry run-sheets final |
| Mon 30 Nov | ~12:00 move #60 (C8, at its cutoff), ~13:30 move #58 (E7, at its cutoff); expiry: cNGN 14:00, EURC 15:00 |

## Related open item

markets-service `custodian_index_failed` ("block range extends beyond current head block", ~5/hour): index to head − 2.
Harmless retries, but worth shipping in C5's markets deploy rather than a deploy of its own.
