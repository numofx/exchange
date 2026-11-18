# EURC-31DEC26 listing run-sheet (draft)

Drafted 2026-11-17. **Nothing here has been sent.** Each sending step is its own go-ahead. This sheet lists the series;
`onchain-book-next-series-runsheet.md` then puts our maker's size on it. **Target: listed by Tue 24 Nov.**

## Decided (owner, 2026-11-17)

- **Series:** EURC-31DEC26 on the existing `FutureAsset` v3 `0xC350…B227`.
  - expiry Thu 2026-12-31 15:00 UTC, `1798729200` (also the subId);
  - last trade 14:30, `1798727400`.
- **Book:** market 2 on the v2 OnchainBook. v3 starts with the series after this one.
- **Overlap:** one maker, moved from 30NOV26 to 31DEC26 around 27 Nov. 30NOV26 keeps the v1 book's 60-EURC canary until
  its cutoff.

Carried over from D4 A: **no Matching maker** on 31DEC26. The size is on the book only. The series is listed on
Matching (the indexer needs the registry entry) but its Matching book stays empty unless users rest orders.

## Why listing is mostly config

The future's position cap and its place on the TradeModule are per asset, and are already open for 30NOV26. The engine
holds one future per market, but that future carries any number of series: the v3 canary (subId `1794776400`) ran beside
30NOV26 on 15 Nov. So on chain, listing is a single vault call. The other work is config, the keeper and
markets-service.

**Checked on chain on 2026-11-17:**
- the future's fixing parameters are window 1800 s, max sample gap 120 s and recovery delay 3600 s; `setContract`
  keeps the values in force at listing for good, and these are the production values;
- the future and its forward feed are owned by the vault;
- the forward feed (`0x401D…d8e4`) keys data by expiry, and its `maxExpiry` is 365 days.

## Steps

| # | Step | Sends | Done when |
|---|---|---|---|
| L1 | **Tooling** (**done 2026-11-17**, rehearsed below). An `eurc-v3-list` batch in `propose_eurc_future_v3_batch.py` with `--expiry` (and `--initial-mark` to pin the dry run's). It runs one action, `setContract(expiry, expiry − 1800, initialMark)`; the initial mark is index × (1 + 0.015 × time to expiry / 365 d), the keeper's carry. **Gates:** the vault owns the future; the expiry is unlisted, and no other future on the engine has it; fixing parameters are 1800/120/3600; last trade is more than 7 days away; the initial mark is inside `markIndexBand(expiry)` and within 1% of the carry forward; the index answers. Self-tested, plus a fork rehearsal: prank the vault, list, then `pullMark` from a stand-in-signed forward, take on a market 2 of the v2 book | nothing | Committed; the fork lists, marks and fills |
| L2 | **Keeper config** (**done 2026-11-17**, `DRY_RUN=true` in the file). `future-feeds-v3-eurc-31dec26.env`, a copy of 30NOV26's with `FUTURE_SUB_ID=1798729200`, and `FORWARD_RELAYER_SSM_NAME=forward_relayer_key_v3_eurc_canary`. That relayer, `0x35ee…bDD5`, is idle since the canary settled and holds 0.00002 ETH. Two relayers, because two instances on one key collide on nonces | nothing | Committed |
| L3 | **Fund the relayer:** ~0.02 ETH to `0x35eeBd8E94F9c4a6b13EBa9fD676f7d0fDa8bDD5` (owner). Add it to `check_signer_balance.py` at 0.0035, the v3 relayer's measured rate | owner | Read back; balance check `ok` |
| L4 | **List** (`eurc-v3-list --expiry 1798729200 --propose`, from the box) | vault | `futureContracts(1798729200)`: listed, unsettled, last trade `1798727400` |
| L5 | **Keeper:** install the env with `DRY_RUN=true`, then `systemctl enable --now numo-future-feeds-v3@eurc-31dec26`. Read its first forward mark in the log (`basis carry`, since Matching is empty), then set `DRY_RUN=false` and restart | box | `futureContracts(…).markPrice` updated by `pullMark`; `lastMarkTime` within `maxMarkDelay` |
| L6 | **markets-service:** add a `future_series` entry (`variables.tf`): asset `0xC350…B227`, expiry `1798729200`, engine v2, linear, EURC, contract size 1000, amount scale 1e15, **`taker_fee_bps` 5**. Merge `main` first, read the plan's env deltas, then apply through `with-matcher-mute.sh` (~70 s of matcher gap) | ECS | `/markets` lists `EURC-31DEC26` at 5 bps; the matcher starts (it checks contract size against the chain) |
| L7 | **Book:** `onchain-book-next-series-runsheet.md` steps 1–8 | — | — |
| L8 | **Write back** the same day; draft `eurc-31dec26-expiry-runsheet.md` from 30NOV26's | — | — |

Two report posters while both series run: from L5 until 30NOV26's keeper is disabled (~1 Dec), both instances post
Data Streams reports to the shared adapter. That's harmless, at about twice the adapter's gas for a week, and it is how
the canary ran. After 30NOV26's close-out:
- move 31DEC26's instance to the main relayer (`forward_relayer_key_v3_eurc`, 0.0407 ETH), restart it, and sweep the
  canary relayer;
- or keep the canary relayer and fund it to 31 Dec, about 0.1 ETH at 0.0029/day.

## What stays as it is

- **`report-age`:** it watches the shared adapter.
- **The settlement canary and settlement verifier:** keyed by accounts and fills, not by series.
- **The liquidation keeper:** it reads the engine's futures per asset.
- **The perp pager:** removed on 2026-11-17.

## Undo

- **Before L4:** nothing is on chain.
- **After L4:** a listed series can't be unlisted. With no trades it costs nothing; settlement runs on 31 Dec with no
  positions to close out.
- **After L6:** remove the `future_series` entry and redeploy, which delists it on Matching and in the app.

## Rehearsed, 2026-11-17

- **Mainnet dry run** (`eurc-v3-list --expiry 1798729200`): every gate passed.
  - custody;
  - schedule: 43.4 days to last trade, fixing (1800, 120, 3600);
  - series;
  - forward: expiries taken to `1826509675`;
  - index 1.099112;
  - mark 1.101078, the carry forward, inside 3% of the index;
  - parity: 43 settings.

  Digest `0x157c5459…71af`. The mark moves with the index, so **propose with the `--initial-mark` that the same day's
  dry run printed.**
- **anvil fork at head:**
  - The vault, impersonated, sent the proposer's exact calldata: `setContract` 132,549 gas.
  - Read back: listed, expiry and last trade as intended, mark 1.101078, and `seriesFixing` (1800, 120, 3600). The
    proposer then read it as landed.
  - Then market 2 on the v2 book as in `onchain-book-next-series-runsheet.md`. #57 **bought 5 EURC of EURC-31DEC26
    from #58 with no reports** (1,031,582 gas): +5 / −5 on the new subId, 30NOV26 untouched, and both accounts' margin
    positive. Sold back (770,753 gas): flat.
- **The keeper itself isn't rehearsed:** it needs the Data Streams credentials and the KMS forward signer. The canary
  ran a second instance on this future from 15 Nov, which is the precedent. L5's dry run is the check.
- **Self-test:** the carry forward matches perp-feeds' `discountForward` to the unit (vectors from node BigInt).
  Python's `//` floors where JavaScript truncates, which is caught by a test. The calldata matches `cast calldata`.
  Nine mutants of the new guards were all caught; the band check needed a second case.
