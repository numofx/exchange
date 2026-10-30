# MarginEngine v2: the cNGN future in American terms

Decided 2026-10-21: FX pairs quote in American terms, USDC per foreign unit. Spot already does (`cNGN-USDC`,
`EURC-USDC`). The future did not: v1's `USDC-cNGN-<expiry>` is cNGN per USDC on chain, with a USDC contract and VM in
cNGN, and the v1 engine (0xA19E…0758) and its linked FutureVMLib are immutable and built around exactly that. So v2 is
a new engine, and the first v2 series lists as `cNGN-<expiry>` at the 30NOV26 roll. v1 runs its series out unchanged.

## What changes

| | v1 (`src/legacy/v1`, deployed) | v2 (`src/`) |
|---|---|---|
| symbol | `USDC-cNGN-30NOV26` | `cNGN-30NOV26` (deployed 2026-10-27, `DEPLOYED_ADDRESSES.md`) |
| price | cNGN per USDC (`1e36 / feed`) | USDC per cNGN (the feed as is) |
| contract | 1,000 USDC | 1,000,000 cNGN (~743 USDC at 0.000743) |
| long gains when | cNGN weakens | cNGN strengthens |
| VM | cNGN, paid as base first through pool 31, USDC shortfall at spot | USDC cash through the pool, nothing converted |
| VM in the price | inverse | linear: Δmark × size |
| notional for margin | fixed 1,000 USDC | \|pos\| × size × mark, moves with the price |
| pending VM in margin | gain at the base factor, loss from held base | at par, as a perp's unrealised PnL |
| close-out | converts at the settlement price | reads no feed, converts nothing |
| forward feed | published USDC per cNGN, inverted by `pullMark` | read as is; the diff is negative (cNGN at a forward discount) |
| fair forward at deploy | index × (1 + carry τ) | index / (1 + carry τ) |
| markets | NGN (spot, perp, future), EUR | NGN (spot, future), EUR; no perp |

Unchanged: every external signature the ops scripts call (`settleAccountVM`, `getPendingVM`, `pullMark`,
`recordFixingSample`, `fixSettlementFromIndex`, `closeOutExpired`, `settleAccount`, …), the mark bounds, the index band
(10% narrowing to 1% over 14 days), the fixing (1h window, 15m gap, 24h fallback within 2%), IM 25% / MM 15%.

## SecurityModule sizing: what moves

The v1 sizing ([`cngn-future-security-module.md`](cngn-future-security-module.md), from #245) rests on the inverse payoff
and a fixed-USD maintenance margin. Both go:

- **Loss on a step.** v1's `notional × premium × ln(1/(1−s))` came from inverse VM. v2's VM is linear, so a step `s`
  against a side costs `notional × s`.
- **The cliff.** v1's MM was a fixed number of dollars a contract, giving a cliff at `1 − exp(−MM/premium)` = 13.8%.
  v2's MM is a share of a notional that moves with the price. An account opened at exactly IM falls below MM at
  `s = (IM − MM) / (1 + MM)` = 8.7% for a short (cNGN rallies) and `(IM − MM) / (1 − MM)` = 11.8% for a long
  (cNGN falls), and is bankrupt at `s = IM` = 25% either way. The 15% step the v1 doc sizes to therefore liquidates
  without bankrupting an IM-margined account; the SecurityModule covers accounts that were already under IM.
- **Unsettled VM no longer flatters an account.** It is cash at par, not cNGN whose USD value moves.
- **The pool's cNGN reserve is gone.** The pool only ever holds cash, fronts winners and is repaid by losers; the
  pager's reserve check and `withdrawFromPool` rebalancing are v1-only.
- **Caps.** 30 contracts over both sides is ~$22k at 0.000743, against v1's $30k. Sized below.

### Cap against an overnight devaluation gap

Inputs, read 2026-10-21 at Base block 52,912,673: SecurityModule capacity **$3,250** (account 21's USDC cash; #245
changes the sizing formula, not the capacity, so the same figure holds on `main` and on #245). One contract is
1,000,000 cNGN × 0.000743 = **$743**. Every capped contract is taken to be a long opened at exactly IM (25%), which a
devaluation gap bankrupts at 25%; conservative, since a cap counts both sides and so admits at most half as many longs.

| Gap | Bad debt per contract, $743 × (gap − 25%) | Max cap | If the module pays the whole step, $743 × gap | Max cap |
|---|---|---|---|---|
| 30% | $37.15 | **87** | $222.90 | 14 |
| 40% | $111.45 | **29** | $297.20 | 10 |
| 50% | $185.75 | **17** | $371.50 | 8 |

**40 contracts does not pass at 40%:** $4,458 of bad debt against $3,250, short by $1,208. 29 is the most that does.

The right-hand columns are an upper bound, not the sizing rule. #245's fork run on v1 found that an insolvent auction
ends at the account's maintenance margin, so the module paid close to the step's whole loss once a side was insolvent,
not just the part past bankruptcy. Whether v2's linear payoff does the same is unmeasured: #245's
`testSecurityModuleCoverageAgainstTheFork`, run against v2, settles which column the cap should come from.

What `propose_margin_engine_v2_batch.py` enforces at `enable` and `cap`, re-read at the cap being opened and today's mark:

- **`sm`** (refuses): the SecurityModule covers the whole of a 15% step (`SM_MOVE`, the pager's) on one side,
  `check_perp_pager.sm_required_usd_linear`. v1's rule pays nothing until a side at MM is insolvent; a linear side at
  MM 15% is insolvent at exactly 15%, so that rule would read nothing at all and the whole step is the safe reading
  until the fork measures v2. $3,250 covers 58 contracts at 0.000743.
- **`gaps`** (informational, never refuses): this table at today's mark and cash, naming each gap the cap is not
  covered at. The cap itself is a decision; the deploy default of 30 is not covered at a 40% gap at 0.000743.

## Migration

There is no `changeManager` in SubAccounts. Holders move by opening a v2 account and withdrawing and re-depositing.
`test/fork/MarginEngineV2DeployFork.t.sol` proves a v1 account and a v2 account trade spot cNGN against USDC directly,
each held to its own engine, so `cNGN-USDC` and `EURC-USDC` keep one book through the move.

Order (`scripts/ops/propose_margin_engine_v2_batch.py` proposes every vault step; each is gated and re-read):

1. Deploy v2 (`scripts/deploy-margin-engine-v2.s.sol`): closed, nothing reused wired. **Not before EURC-USDC is listed
   on v1** (`DEPLOYED_ADDRESSES.md`, EURC steps 1–2): v2 copies only the markets v1 lists, so a v2 deployed first has no
   EUR market, and the EURC batch is written for v1. Enforced: the deploy reverts unless v1 lists exactly NGN and EUR
   (`lastMarketId == 2`), and `setup` refuses a v2 that does not list both. The deployer is a fresh key, or a used one
   named in `USED_DEPLOYER`; either way it sends nothing more until `setup` lands, which refuses if it has.
2. `setup` (`MARGIN_ENGINE_V2_VAULT_ACTIONS`): accept, wire the cash, every escrow at v1's cap except EURC's, and the
   auction; v1's guardian. Re-reads parity once the vault owns everything. EURC's escrow is whitelisted for v2 at cap
   **0**: a cap is per manager, and v1's 40,000 EURC was sized to on-chain sell depth for the whole venue
   (`DEPLOYED_ADDRESSES.md`, EURC), so a copy would double the venue's EURC to 80,000 with nothing re-checking depth.
   Step 6 opens it.
3. `enable` (`MARGIN_ENGINE_V2_ENABLE_VAULT_ACTIONS`): open the future and register it on the TradeModule. Refused until
   v2 has its own forward keeper, liquidation keeper and pager watch (#258) and markets-service lists `cNGN-30NOV26`
   with the chain's band in USDC per cNGN (#228). Both 30NOV26 series then run to the same expiry, v1's close-only:
   markets-service lists both under distinct symbols (#280: v1's stays `USDC-cNGN-30NOV26`, v2's is `cNGN-30NOV26`,
   from `FUTURE_SERIES`). The keepers and the pager are on the box since 2026-10-28 (OPS_BOX_CHANGES.md); v1's engine
   keeper moved to v2 that day, so v1's series has no liquidator until it settles.
4. markets-service: new spot deposits default to v2 accounts (no listing's `margin_manager_address` is v1), and v1's
   future is listed close-only (`future.close_only`). The spot makers (#34 cNGN-USDC, #36 EURC-USDC, both v1 accounts
   of the MM wallet) quote from v2 accounts: close-only stops a v1 account buying base, so a v1 maker's bids would fill
   into reverting settlements and leave the books one-sided.
5. `v1-close-only`: every cap v1 holds (each escrow, the future) set **at** live open interest, never a raise. Refused
   until 3 and 4 hold, and while any v1 account rests a buy on a spot book or a maker account (`MM_SUBACCOUNT_IDS`,
   default `34,36`) is under v1, resting or not. A cap that lands under open interest, because it rose between the read
   and the approval, is the same close-only and not a freeze: the deployed viewer checks only the assets a transfer
   touched.
   `test/fork/MarginEngineV1CloseOnlyFork.t.sol` proves holders still close, settle VM, withdraw and sell cNGN to v2,
   that nothing opens, and that under the SRM's cap check the same cap freezes them. EURC's escrow need only be
   whitelisted for v2 here, not open: from this step until 6 lands, neither engine takes new EURC.
6. `eurc-cap --eurc N`: `eurcEscrow.setTotalPositionCap(v2, N)`. Gated on the venue's total EURC, v1's cap (now its
   open interest) + N: `propose_eurc_spot_batch.py`'s depth stress gate on a fresh `eurc_depth` reading (50% of the 2%
   sell depth without the main pool's largest LP at least the total), and the engine keeper's `MAX_EURC_INVENTORY` at
   least the total. After 5 because 5 pins v1's cap at its open interest; before it v1's 40,000 leaves v2 almost nothing.
7. 30NOV26 fixes and closes out on v1; holders withdraw and re-deposit under v2.

## EURC-30NOV26 (pending deploy)

A second v2 series on market 2 (EUR): `EURC-30NOV26`, cash settled in USDC, quoted in USDC per EURC, one contract
1,000 EURC (~$1,114 at 1.1138), a long gains as EUR strengthens. v1's futures are inverse with VM in base, so it is v2's
only. `scripts/deploy-eurc-future-v2.s.sol` deploys it, `scripts/ops/propose_eurc_future_v2_batch.py` proposes its
batches, `test/fork/EurcFutureV2Fork.t.sol` proves it against the live engine.

### What the deployed engine needs

Nothing but the vault. The engine has no per-market future slot fixed at deploy: `whitelistAsset(future, 2, Future)` and
`setFutureMarginRequirements(2, mm, im)` are owner-only setters, the viewer arranges futures per market
(`assetDetails(asset).marketId`), and `FutureVMLib` margins a market's futures at that market's requirement. The pool is
not per future: every future's VM moves through the engine's one account `accId` (#37), which only fronts cash between
holders of a series and nets to zero once they settle, so EURC needs no pool of its own. On the TradeModule a future is
one flag (`setDatedFutureAsset`). The fork suite runs the setup and enable batches as the vault against the engine as it
stands and trades, marks, fixes and closes out on it.

One thing the engine couples: a series is its subId, the expiry, and `closeOutExpired(account, subId)` closes it on
every market that lists it, reverting `ME_NotSettled` while any of them is unsettled. At cNGN's 14:00 expiry an EURC
fixing that missed samples (and so fell back to the owner, 24h after expiry) would hold every cNGN-30NOV26 close-out,
and the settled notional stays margined until it closes (`testOneExpiryWouldCoupleTheCloseOuts`). EURC therefore
expires at 16:00 UTC (1796054400, the WM/Reuters London fix; last trade 15:00), and the deploy refuses an expiry any
market's future lists.

### Parameters (decisions, with the deploy defaults)

| | default | why |
|---|---|---|
| expiry / last trade | 2026-11-30 16:00 / 15:00 UTC | a subId of its own (above); the London 4pm fix |
| contract | 1,000 EURC | ~$1,114: v2 cNGN's ~$743 and v1's $1,000 in the same range, so caps read in similar dollars |
| IM / MM | 6% / 4% | below |
| carry | -1.5% a year | an assumption, not a reading: EUR rates less USD rates (ECB deposit ~2% against fed funds ~3.5%). Negative carry puts EUR at a forward premium, `index / (1 + carry x tau)` above the index, +0.14% at 33 days |
| initial mark | the fair forward at the deploy block | `INITIAL_MARK` overrides, held to 0.5% of it and 3% of the index |
| mark move / index band | 2% a mark; 3% narrowing to 0.5% over 14 days | cNGN's 5% and 10% -> 1% are sized to NGN. The band is also the fill band: it bounds what two accounts move between them at an off-market fill |
| cap at enable | 18 contracts (9 a side, ~$20k both sides) | the SecurityModule rule below |

Unchanged from cNGN: 10-minute max mark delay, hourly pulls, 2h forward heartbeat, 1h fixing window sampled within
15 minutes, 24h fallback within 2% (`FALLBACK_BAND`). The index is the EUR market's spot feed (Chainlink EURC/USD,
hourly or 0.1% deviation, 3h limit). An account holding the future now reads that feed on every risk check, as EURC
holders already do: if Chainlink misses two rounds it fails closed until Chainlink posts.

**IM / MM.** By this doc's sizing, an account opened at exactly IM falls under MM at `(IM - MM) / (1 + MM)` for a short
(EUR rallies) and `(IM - MM) / (1 - MM)` for a long, and is bankrupt at `IM`: at 6% / 4% that is 1.9% / 2.1% and 6%.
EUR/USD runs at roughly 6-10% a year, 0.4-0.6% a day, and its largest daily moves on record are under 5%, so an account
at IM is liquidated on a move several times a normal day's and is bankrupt only past any day on record; an account at
MM is bankrupt on a further 4%, about the largest days on record. That is about two to three times the margin a listed EUR/USD
future asks, which is the point: one SecurityModule of $3,250, a keeper that is not yet watching EUR, and an index on a
stablecoin (EURC can trade away from EUR) rather than on the interbank rate. 5% / 3% (bankrupt at 5%, MM at 1.9%) is
the next step once the keeper and pager have run a series; below that the band's 3% would be wider than the margin.

**Cap.** The rule `enable` applies to cNGN, the SecurityModule covering the whole of an `SM_MOVE` (15%) step on one
side, applied to both series together, since every v2 series draws on one module. At 2026-10-27 readings (module
$3,250; cNGN 0.000713260 at its enable cap of 30, $1,604.84; EURC 1.1138): $1,645 is left, which covers a $10,968 side,
9.8 contracts: **9 a side, a cap of 18**. With cNGN still closed it would be 38. 15% is an NGN devaluation step and is
very conservative for EUR (a 6% step, the IM, would allow 24 a side on the same $1,645), but it is the rule the
module is sized by until #245's coverage test runs against v2. `eurc-future-enable` re-reads it at the cap and today's
marks, after cNGN's draw at its live cap; propose_margin_engine_v2_batch.py's `enable` and `cap` now hold back EURC's
draw at its live cap the same way.

### Order

1. `forge script scripts/deploy-eurc-future-v2.s.sol` from a fresh key (or one named in `USED_DEPLOYER`), with
   `FORWARD_SIGNER` the forward KMS key `0xd65F…3650` (each feed's EIP-712 domain binds its signatures to that feed, so
   one key signs both). Writes `EURC_FUTURE_V2.json`, `EURC_FUTURE_V2_VAULT_ACTIONS.json` (4) and
   `EURC_FUTURE_V2_ENABLE_VAULT_ACTIONS.json` (2). Closed: cap 0, not on the engine, not on the TradeModule.
2. `eurc-future-setup`: accept both, `whitelistAsset(future, 2, Future)`, `setFutureMarginRequirements(2, 0.04, 0.06)`.
   Opens nothing (the future's own cap is 0, which refuses any position before the engine is asked).
3. Off chain, before enable: the forward publisher signs this feed (`marks` gate: a mark within 2h); the pager reads the
   future (`futures` in its state); v2's liquidation keeper reports it among its `futures` and holds the IM for a full
   side of each series; markets-service lists `EURC-30NOV26` (`asset_address`, `sub_id` 1796054400, `market`
   `EURC-30NOV26`) with the chain's fill band in USDC per EURC.
4. `eurc-future-enable`: the cap (18), then `setDatedFutureAsset(future, true)`.
5. 30 Nov: fixing samples 15:00-16:00, `fixSettlementFromIndex` after 16:00, close-outs.
