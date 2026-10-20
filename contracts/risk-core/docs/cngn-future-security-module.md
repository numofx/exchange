# cNGN future: SecurityModule sizing

**Decided 2026-10-20:** the SecurityModule is sized for the USDC-cNGN future alone, against a **15% move**
(`SM_MOVE` in `scripts/ops/check_perp_pager.py`, the one place it is set; it was 25%, the perp's rule). The perp is
wound down and no longer counted. Two values were tried first the same day: 10% requires nothing at all, and 14% sat
on the edge where it would too (below). This page records the rule, what the fork measured, what 15% does and does
not cover, and the circuit breaker it depends on.

## The rule

What the SecurityModule pays if one whole side of the future, left at maintenance margin, is liquidated after the
naira loses `s` of its USD value, with the losers settled at every mark and the auction run to its end:

    loss     = one-side notional x premium x ln(1 / (1 - s))        premium = mark / index
    required = loss   if loss > one-side notional x MM
               0      otherwise

- `check_perp_pager.sm_required_usd`: the one implementation.
- The proposer's `sm` gate (`propose_margin_engine_batch.py`, `enable` and `cap`) reads it **at the cap** being
  opened, at the live MM and premium.
- The pager's `sm-coverage` reads it **at actual open interest**: Slack past coverage, page at 1.2x.

## What the fork measured

`MarginEngineDeployFork.testSecurityModuleCoverageAgainstTheFork`: a $15,000 side (15 contracts, the launch cap's
one side) opened at IM + $1, walked to 5 bps above maintenance, then stepped, against the real auction and the perp
stack's real SecurityModule (funded so its balance never caps the payout). Premium 1.0225, MM 15%.

| Move | Insolvent | SM paid, auction to its end | SM paid, keeper's bid | Fit | Rule it replaced, `s x (1 - IM)` |
|---|---|---|---|---|---|
| 10% | no | $0 | $0 | $0 | $1,125 |
| 12.5% | no | $0 | $0 | $0 | $1,406 |
| 14% | yes, by $15 | $2,265 | $52 | $2,313 (+2.1%) | $1,575 |
| **15%** | yes | $2,441 | $227 | $2,493 (+2.1%) | $1,688 |
| 16% | yes | $2,616 | $402 | $2,674 (+2.2%) | $1,800 |
| 17.5% | yes | $2,889 | $676 | $2,951 (+2.1%) | $1,969 |
| 20% | yes | $3,349 | $1,135 | $3,423 (+2.2%) | $2,250 |
| 25% | yes | $4,320 | $2,144 | $4,412 (+2.1%) | $2,813 (**-35%**) |
| 30% | yes | $5,355 | $3,178 | $5,471 (+2.2%) | $3,375 |

Three things the old rule got wrong for the future:

- **It is a cliff, not a slope.** An insolvent auction ends at the account's maintenance margin
  (`DutchAuction._getInsolventAuctionBidPrice`), so the module pays `MM requirement - equity`, which for an account
  that started at maintenance is the step's whole loss. Before the account is insolvent it pays nothing. The perp's
  `s x (1 - IM)` was fitted on the perp, whose maintenance requirement moves with the price; the future's is a fixed
  number of dollars a contract (`FutureVMLib.marketMargin`).
- **It understated the future past the cliff**, by 35% at a 25% move. At the launch cap the fit asks $4,361 for a 25%
  move, against the $3,250 the module holds; the old gate passed it at $2,812.
- **Unsettled VM flatters an account.** A short's unsettled VM is a debt in cNGN, and the naira's fall shrinks its
  dollar value: left unsettled through a 10% step, a $1,500 debt reads as $1,350. The keepers settle losers at every
  mark in production, so the test does too; without that the fork read 10% low.

## What 15% means

With MM 15% and today's premium (1.0106) the cliff is at a **13.8%** move (`1 - exp(-MM / premium)`): any assumed
move under it requires **nothing**, which is why 10% was dropped. 15% is past the cliff, so it asks for the whole loss
of a 15% move:

| Cap (both sides) | One side | 10% | 14% | 15% | 20% | 25% |
|---|---|---|---|---|---|---|
| 30 | $15,000 | $0 | $2,286 | $2,464 | $3,383 | $4,361 |
| 400 | $200,000 | $0 | $30,486 | $32,850 | $45,104 | $58,149 |
| 1,000 | $500,000 | $0 | $76,214 | $82,124 | $112,759 | $145,371 |
| 1,200 | $600,000 | $0 | $91,457 | $98,549 | $135,311 | $174,446 |

(2026-10-20, live premium 1.0106, MM 15%. The keeper gate, unchanged, still needs cap / 2 x 1,000 x 25%: $150,000 at
1,200.) Today's $3,250 opens a cap of up to 38 contracts at 15%; 40 needs $3,286.

**Why 15% and not 14%.** The cliff moves with the premium. 14% cleared it only while the future traded no more than
0.55% under the index (premium 0.9945): any lower, and a side at maintenance survived a 14% move, so the requirement
fell back to 0 at any cap. 15% falls to 0 only with the future 7.7% under the index (premium 0.923), near the edge of
the 10% index band. The pager's self-test pins both edges.

15% covers a single step of 15%. It is still well short of the moves the naira has made, so it holds only while all of
these do:

1. **No mark moves more than 5%.** `maxMarkDeviation` is 5% and marks are at least an hour apart
   (`FutureAsset._checkDeviation`, `minMarkInterval`). An account at maintenance survives a 5% step, so as long as
   the keepers liquidate between marks, no single step reaches the cliff. **Never widen `maxMarkDeviation` to catch
   the mark up in a crisis**: that turns a staged move into one step, which is exactly the case the 25% rule sized.
2. **The marks do not freeze.** A mark must also sit within 10% of the index (`_observeIndexAndCheckBand`). If the
   index gaps more than about 15% past the mark, every mark reverts and nothing is marked or liquidated. The
   catch-up is to widen the **index band** (`setIndexParams`, vault) and step the mark 5% an hour with liquidations
   between, never to widen the deviation limit.
3. **The keepers keep up.** A whole side has to be liquidated between two marks. That needs a live keeper with the
   cash to take the accounts (the `keeper` gate).
4. **The circuit breaker stops open interest growing into a move** (below).

For scale: Nigeria's official-rate unifications in June 2023 and January 2024 each moved the rate roughly 40% within
about a day. Under this sizing, a move like that is absorbed only by (1)-(4) holding; the SecurityModule covers one
15% step of it. If
they fail, a shortfall past the module's cash is socialized across every USDC balance on the venue
(`CashAsset.socializeLoss`).

## The perp's wind-down (as of 2026-10-20)

| | State |
|---|---|
| Open interest | 0 under the perp SRM, 0 under the engine |
| Venue | close-only (`CNGN_PERP_CLOSE_ONLY`; leaving it needs `CNGN_PERP_REOPEN_ACK`, #230); empty book |
| Market maker | `desired_count_market_maker_perp = 0` |
| On-chain cap | **still 50M cNGN under the perp SRM**, 0 under the engine |
| SecurityModule | no per-product allocation; its account (21) **sits under the perp SRM** |

Removed from sizing: the perp's term in `sm_required_usd`, the pager's `sm-coverage` and the proposer's `sm` gate.
In its place the pager pages `perp-oi` if the perp ever holds open interest again, since nothing covers it.

Still depending on the perp stack:

- **The SecurityModule's account is under the perp SRM.** Pausing that SRM stops every engine liquidation and every
  insolvency payout (`MarginEngineDeployFork.testPausingTheOldSrmStopsEngineLiquidations`,
  `testPausingTheOldSrmStopsInsolvencyPayouts`). The SRM must stay deployed and unpaused.
- **The perp SRM's cap is 50M cNGN.** The venue's close-only is what stops new perp positions; set the SRM's perp cap
  to 0 (vault) to close it on chain too.
- The rest of `check_perp_pager.py` (feed, keeper, gas and peg pages) and the perp keeper's units on the ops box are
  the perp's, and are left as they are here.

## Circuit breaker (proposed, not built)

**Trip:** the index moves more than **5% within 24 hours** (Slack at 3%), or the mark and index are more than 7.5%
apart (the marks stop at 10%). **Clear:** the 24-hour move is under 2.5% for an hour, and the mark is back within 5%
of the index.

**While tripped:** block position-increasing trades on the future. Do not raise maintenance margin: that liquidates
every thin account at once into a thin market. Raising initial margin only would do the same as blocking increases,
less exactly.

5% sits well inside the 15% the module is sized for and above the naira's ordinary day. A move that big means the regime has changed,
and the point is to stop open interest growing at the top of it, not to time the move.

Where it would live, in order of how quickly each can be built:

1. **markets-service (no contract change).** The index is already read for the fill band (`internal/futures/band.go`).
   Keep 24 hours of samples in Postgres, so a restart does not reset the window. While tripped, take every future
   order as reduce-only, as `perpCloseOnlyOrder` does for the perp (`internal/api/orders.go`), and hold every future
   leg to reducing in the matching engine (`internal/matching/engine.go`, beside `perpCloseOnly`). Show it on
   `/v1/markets` and page `future-breaker` from the pager.
2. **On chain, by the vault.** On the page, set the cap to open interest:
   `propose_margin_engine_batch.py cap --contracts <open interest>`. This stops increases whatever the venue does. It
   needs an MPCVault approval, so it is the backstop, not the breaker.
3. **In the contracts (a future deployment).** A check in `MarginEngine.handleAdjustment` that refuses a trade that
   raises the future's open interest while the index has moved more than X in 24 hours. `FutureAsset` keeps only the
   last index (`lastIndexPrice`), so it needs a 24-hour reference first. The engine is deployed directly with no
   upgrade path, so this is a new engine and a review, not a parameter.

## Changing the move

Edit `SM_MOVE`, then:

```bash
python3 scripts/ops/check_perp_pager.py --self-test
python3 scripts/ops/propose_margin_engine_batch.py --self-test
BASE_RPC_URL=… forge test --match-contract MarginEngineDeployFork --match-test testSecurityModuleCoverageAgainstTheFork -vv
```

The pager's self-test pins the fit against the fork's numbers above; re-run the fork test if the margin
requirements, the auction or the settlement path change, and update those numbers from its log.
