# EURC-USDC futures and on-chain matching

Status: **v3.3**, 2026-11-14. Supersedes v1 (written against `DatedFutureAsset` and `StandardManager`, which are not the
live contracts) and v2.x–v3.0 (reviewed in conversation, not committed).

- **Step 1** (build now): a new `FutureAsset` version with recovery fixing and no owner price, `StreamsIndexAdapter`,
  a staleness-only `EurcIndexFeed`, traded through the existing `Matching` path. Listing waits on the measurements in
  A6 and A7. Data Streams access is in place (A2.1).
- **Step 2** (`OnchainBook`, oracle-pegged maker curves): gated on a concrete taker, **except for the EURC-30NOV26
  pilot (A1.2)**, for which the gate is lifted.

The pilot ships in two stages (A1.2): Stage 1 lists the new series on `Matching` as soon as its Sepolia rehearsal
passes; Stage 2 adds `OnchainBook` to the same market behind its own gate. The market never waits for `OnchainBook`.

**v3.3 changes from v3.2:** the pilot ships in two stages and the market no longer waits for `OnchainBook` (A1.2);
pilot expiry decided, 2026-11-30 15:00 UTC (A1.2); `acceptData` skips an old report instead of reverting, the
verifier is called with no value so any fee fails closed, and `indexMaxAge` is immutable (A2.2, A2.3); Stage 1 keeps
the index fresh with a keeper rather than executor-attached reports (A2.2).

**v3.2 changes from v3.1:** the old EURC-30NOV26 expires unopened and a pilot series on the new version with
`OnchainBook` replaces it (A1.1, A1.2); the Base verifier proxy and its fee manager are recorded: verification is
free on Base today (A2.1), so the per-second keeper is no longer ruled out on cost (B6a); file placement decided
(A8.1).

**v3.1 changes from v3.0:** the existing EURC-30NOV26 deployment is recorded (A1.1); Data Streams feed IDs, schema,
cadence and per-report fee are recorded (A2.1); the owner fallback is removed and `indexFeed` changes are timelocked
and pinned per fixing window (A8.5), since `setIndexParams` would otherwise let the owner set the settlement price by
swapping the feed; reports reach the index through `managerData` (A2.2); the per-second keeper is ruled out on cost
(B6a); stale lines fixed.

---

# Part A: Step 1, EURC-USDC futures on the existing path

## A0. Contract definition (decided)

- **Underlying:** the EURC token priced in the USDC token. The contract always reflects EURC/USDC spot, **including
  any EURC or USDC depeg**. It never switches to EUR/USD.
- **Settlement price:** Data Streams EURC/USD (DEX-priced) ÷ USDC/USD (CEX-priced), via the fixing TWAP. The stream
  price is final; no owner sets a price (A8).
- **Divergence from EUR/USD never halts anything.** A halt on divergence would block exactly the depeg the contract is
  meant to reflect, and would let an attacker force a gap in a fixing. EUR/USD is an operator alert only.
- **Trading:** 24/7.
- **Consequences:**
  - the settlement price comes from thin on-chain markets with no external guard, so open interest is capped below
    the cost of manipulating them at any size and any hour (A6.0a). This is the binding limit on the market's size;
  - margin, marks and the SecurityModule are sized for a depeg jump, not for EUR/USD moves (A7);
  - a fixing must always be able to complete, or the series freezes permanently (A8).

## A1. What exists and is reused

- `risk-core/src/assets/FutureAsset.sol` (v2, American terms): `contractSize` is a constructor argument; marks from a
  forward feed (`pullMark`) held to `setMarkBounds`; every mark and every priced fill within `markIndexBand(expiry)`
  of the index (`_checkFillInsideIndexBand`), narrowing toward expiry; permissionless fixing samples and TWAP. Its
  owner fallback (`setSettlementPrice`) is **not** carried into the new version (A8).
- `MarginEngine` v2: margin, `checkAllAssetCaps` on every adjustment, depeg and stable-feed parameters, liquidation.
  Futures margin is `requirement × |position| × size × mark` (`FutureVMLib.marketMargin`) and reads no confidence.
- `TradeModule` dated-future branch: `amtQuote = 0`, fill price in `assetData`, VM from the fill price
  (`FutureAsset._blendVM`), realised in `MarginEngine.handleAdjustment`.
- `BaseManager._processManagerData` and `TradeModule._processManagerData`: pass data to whitelisted `IDataReceiver`s
  (`setWhitelistedCallee`). Used to deliver stream reports with trades (A2.2).

### A1.1 Already deployed: EURC-30NOV26 (closed)

`DEPLOYED_ADDRESSES.md` and `docs/margin-engine-v2.md` record a series built on the current `FutureAsset`:

- `FutureAsset` `0x6Ff7084D6F1760a57b9475a41F54b12279cD7744`, market 2 (EUR) on MarginEngine v2, 1,000 EURC a
  contract, expiry 2026-11-30 16:00 UTC. Set up 2026-10-30; IM 6% / MM 4%; cap 0 until `eurc-future-enable` (18).
- Index: the EUR market's spot feed `0xaaE6…C435` (Chainlink EURC/USD push). The same feed is the market's spot feed.
- Owner fallback 24 h after expiry within 2%.

It predates every decision in this spec. **Decided 2026-11-14: it expires unopened at cap 0.** It is not enabled
under the old design; `eurc-future-enable` is never proposed. It stays whitelisted on market 2 with no positions,
which is harmless because nothing shares its subId (below). `DEPLOYED_ADDRESSES.md` marks it intentionally unopened.

Carried forward from it: **a series is its subId (the expiry), and `closeOutExpired` couples every market that lists
that expiry.** A recovery fixing (A8) can delay settlement by hours, so every EURC expiry must have a subId no other
market lists. The existing deploy script already refuses a shared expiry; keep that check in the new one.

### A1.2 Pilot: EURC-30NOV26 on the new version, in two stages (decided 2026-11-14)

A new series replaces the unopened one: one asset and one subId, first traded through `Matching` (Stage 1), then also
through `OnchainBook` (Stage 2). Adding `OnchainBook` needs no redeploy: `FutureAsset.handleAdjustment` does not gate
on the trade module, only on the manager.

- **Expiry 2026-11-30 15:00 UTC, subId `1796050800` (a Monday).** 16:00 (1796054400) is held by the unopened series
  and 14:00 (1796047200) by cNGN-30NOV26; a subId is the expiry (`getSubId`), and `closeOutExpired` couples markets
  that share one (A1.1).
- **Keyed by address and subId, never by name.** The indexer, markets service and `@numo/abis` key the series by
  (asset address, subId); two assets will both read as "EURC-30NOV26".
- **OI cap** well under the A6.0a manipulation cost, for both stages.

**Stage 1: new `FutureAsset`, `StreamsIndexAdapter` and `EurcIndexFeed` on mainnet, traded through `Matching`.**
Target 2026-11-18/19. Opens only when all of these hold:
- the Base Sepolia short-dated series passes, including a **deliberately broken fixing** recovered by A8;
- the full `./scripts/verify.sh` is green;
- a fast independent review of `FutureAsset`'s fixing and recovery code, the adapter and the feed is done. Stopgap
  until a human reviewer can start: a fresh Claude session given only those files and this spec.

**Stage 2: `OnchainBook` added to the same market.** Scope: splines only (no order book), a maker allowlist,
priority-fee tax off. Step 2's concrete-taker gate is lifted for this pilot only. Before it is enabled:
- the full B11 suite, including every guard-firing and griefing test;
- a targeted independent review of the allowance handling (B3, B5a pre-checks), the per-maker `try/catch` and gas
  floor (B5a), and its use of the index (B6);
- a full Base Sepolia rehearsal with `OnchainBook` on a short-dated series.

**Go/no-go for Stage 2: 2026-11-24.** If it isn't ready, the market runs on `Matching` through expiry and
`OnchainBook` targets the next expiry. Nothing is redeployed either way.

## A2. New code in Step 1

### A2.1 Price sources (Base)

| Source | ID / address | Updates | Built from | Role |
|---|---|---|---|---|
| **Data Streams EURC/USD** (`EURC/USD-Streams-DexPrice`) | feed `0x00030f2b89e4498002a62638cc61ae91a9690c33830601fc64bc131a07f0c5cb` | 1 s, 24/7 | DEX prices | **Index and fixing**; Step 2 peg |
| **Data Streams USDC/USD** (`USDC/USD-Streams-CexPrice`) | feed `0x00038f83323b6b08116d1614cf33a9bd71ab5e0abf0c9f1b783a74a43e7bd992` | 1 s, 24/7 | CEX prices | **Index and fixing**; Step 2 peg |
| Data Streams EUR/USD (`EUR/USD-Streams-ForexPrice`) | feed `0x0008b943a6e94c024eb38a19e31802180d12aa0cac4c7fd857c3112378f591aa` | FX hours | FX markets | Alert only (not subscribed) |
| Chainlink EURC/USD push | `0xDAe398520e2B67cd3f27aeF9Cf14D93D927f8250` | 0.3% or 24 h | pool prices | Alert only |
| Chainlink USDC/USD push | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | 0.3% or 24 h | CEX, **capped at $1** | `MarginEngine` stable feed; alert |
| Chainlink EUR/USD push | `0xc91D87E81faB8f93699ECf7Ee9B44D11e1D53F0F` | 0.1% or 1 h, FX hours | FX | Alert only |
| Aerodrome EURC/USDC TWAP | `[pool]` | every trade | the pool | Alert only |

**Data Streams, checked 2026-11-14 against the live API** with the subscribed credentials (SSM
`/numo/data-streams/*`, see `infra/aws/secrets.tf`):

- both streams schema **V3** (`feedId, validFromTimestamp, observationsTimestamp, nativeFee, linkFee, expiresAt,
  benchmarkPrice, bid, ask`), 6 signatures, one report per second for 10 consecutive seconds;
- EURC/USD reports **bid = ask = benchmark**: the stream carries no spread;
- **verifier proxy on Base: `0xDE1A28D87Afd0f546505B28AB50410A5c3a7387a`**, checked on chain 2026-11-14:
  `typeAndVersion()` is `VerifierProxy 2.0.0`, and `getVerifier()` resolves the config digest of a live EURC report
  (`0x00094bae…b17ee`) to verifier `0x223752Eb475098e79d10937480DF93864D7EfB83`;
- **verification is free on Base today.** `s_feeManager()` is `0xb86d1B8a3Bb1c5d7809F5E9EB009311D51d933c6`,
  `NoOpFeeManager 0.5.1`; `getFeeAndReward` quotes a zero fee in both LINK (`0x88Fb…e196`) and WETH (`0x4200…0006`)
  for both feed IDs, with a 100% discount (checked 2026-11-14). The `nativeFee` / `linkFee` fields in each report
  (~0.00018 ETH, ~0.036 LINK) are not charged. Chainlink can repoint the proxy's fee manager, so:
  - `StreamsIndexAdapter` fails closed if a fee becomes due rather than paying from its own balance;
  - an alert watches `s_feeManager()` on the proxy and pages on any change;
- the EURC stream is premium and absent from the public catalog; it appears only to the subscribed account.

Push-feed settings read from Chainlink's feed directory on 2026-11-14. The `eurc-usd-svr` push variant is not used.

**Why the push feeds can't set the price:** updating only on a 0.3% move or every 24 hours, their ratio can lag by
about 0.6% and still count as fresh; a 30-minute window often contains no update, so the settlement price would be
one value up to a day old and partly known in advance.

### A2.2 `StreamsIndexAdapter` (new)

Verifies Data Streams EURC/USD and USDC/USD reports and stores the latest ratio (USDC per EURC, 18 dp) with its
observation time.
- **Newest-report-only:** a report is accepted only if its observation time is strictly newer than the stored one.
- **An `IDataReceiver`.** The executor attaches fresh reports to each match through `managerData`. Verification is paid
  per trade, not per second.
  - **Order matters.** `SubAccounts` runs every asset hook before the manager hook, so the manager's pass over
    `managerData` (`BaseManager._processManagerData`) comes after `FutureAsset` has checked the fill against the
    index: too late. `TradeModule` hands `managerData` to each receiver *before* submitting the transfers
    (`execution/src/modules/TradeModule.sol:108`), which is what makes attached reports work on `Matching`.
    `OnchainBook` must likewise post reports before its transfers (B6).
  - The manager then passes the same data again, so the adapter must be whitelisted on `MarginEngine` with
    `setWhitelistedCallee` or the trade reverts; that second pass finds equal reports and skips them unverified.
- Between trades, a keeper posts reports only where something needs a fresh index: each `pullMark`
  (`minMarkInterval`) and each fixing sample (`maxSampleGap`). Anyone may post.
- **Stage 1 (A1.2) keeps the index fresh with the keeper alone**, posting well inside `indexMaxAge`, because a fill is
  checked against the index and attaching reports to matches needs executor changes. Attaching through `managerData`
  can follow without a contract change.
- **An old or equal report is skipped, not reverted.** Reverting would let anyone who posts a newer report first make
  an attached report, and so the trade carrying it, fail. A report for any other feed ID, or with a non-positive
  price, reverts.
- **No owner, nothing settable.** The verifier proxy and both feed IDs are immutable; a change is a new adapter and
  feed, through the `FutureAsset` feed timelock (A8.5).
- **Fees fail closed:** the adapter calls `verify` with no value and holds no tokens or approvals, so if Chainlink
  repoints the fee manager to one that charges, verification reverts. Checked 2026-11-14 by `eth_call` on Base:
  `verify` of a saved live report, with zero value from an arbitrary address, returns the report data.

### A2.3 `EurcIndexFeed` (`ISpotFeed`), used as `FutureAsset.indexFeed`

`getSpot()` returns the stored ratio and **reverts only on staleness**: either stream's newest verified report older
than `indexMaxAge` (seconds, set from the 1 s cadence plus delivery margin). `indexMaxAge` is **immutable**: an owner
who could set it could hold the index stale and keep fixings failing, or loosen it so a stale price settles. A
change is a new feed through the timelock.

Divergence checks (EUR/USD, the push-feed ratio, the Aerodrome TWAP) **never revert**. They raise operator alerts.

A stale index reverts priced fills, `pullMark` and `recordFixingSample`. Liquidations and close-outs carry no price and
keep working. The feed itself needs no risk-core change; Step 1's risk-core change is the new `FutureAsset` (A8).

**Rules:**
- **The reverting `EurcIndexFeed` is only ever `FutureAsset.indexFeed`, never the market's spot feed.**
  `MarginEngine._getMarketMargin` reads the market's spot feed for every account holding the market; a revert there
  breaks every margin check, liquidations included. Only a non-reverting feed may be set with `setOraclesForMarket`.
  (EURC-30NOV26 uses one push feed for both; that was acceptable for a non-reverting push feed and is not repeated.)
- **USDC:** the index uses the USDC/USD stream. The capped push feed is only the stable feed.
- A fixing window with a gap is recovered by A8.

## A3. Deployment and configuration

Each item is an owner or vault transaction, written back to the repo the same day (CLAUDE.md).

1. Deploy the new `FutureAsset` version (A8) with `contractSize = 1000e18`, on an expiry no other market lists (A1.1).
2. Whitelist `MarginEngine` on the asset.
3. Deploy `StreamsIndexAdapter` (verifier proxy, both feed IDs) and `EurcIndexFeed`. Set the index feed (A8.5) and
   `setIndexParams(maxMarkIndexDeviation, minMarkIndexDeviation, bandNarrowingPeriod, fixingWindow, maxSampleGap,
   recoveryDelay)`. Confirm each push feed with `cast call <proxy> "description()(string)"` and `"decimals()(uint8)"`.
4. `setWhitelistedCallee(adapter, true)` on `MarginEngine` (and wherever `TradeModule` checks callees).
5. Forward feed for marks: `setForwardFeed(forwardFeed, minMarkInterval)`, reusing the cNGN publisher setup.
6. `setMarkBounds(maxMarkDeviation, maxMarkDelay)`.
7. `setContract(expiry, lastTradeTime, initialMarkPrice)`.
8. `MarginEngine`: `whitelistAsset(future, 2, Future)`, `setFutureMarginRequirements(2, mm, im)` sized per A7.
9. EURC collateral already exists on market 2 (escrow `0xfD2A…6cD9`); its v2 cap is a separate, depth-gated decision.
10. `TradeModule.setDatedFutureAsset(future, true)`; `future.setTotalPositionCap(engine, cap)` per A6.0a.
11. Off-chain: the executor attaches stream reports to matches; mark and fixing keeper; markets service; market-maker
    config; `@numo/abis`.

## A4. 24/7 operation

- **Weekends:** liquidity is thinnest and manipulation cheapest. The OI cap (A6.0a) is sized for the cheapest hour.
- **Marks:** the forward-difference publisher runs 24/7; A7 sets how fast marks follow a jump.
- **Expiries:** fixing windows when the source pools are deepest (measure).

## A5. Step 1 tests

- Fork: list on a fork of live Base, trade through `Matching` with reports in `managerData`, marks, a fixing,
  settlement, close-out.
- Guards fire: a fill outside the band reverts; asset cap reverts; a stale index reverts priced fills, `pullMark` and
  `recordFixingSample` **while a liquidation and a withdrawal still complete for an account holding the future**.
- `EurcIndexFeed`: ratio correctness including EURC and USDC depegs; reverts only on staleness; each divergence
  check alerts and never reverts. `StreamsIndexAdapter`: rejects an older or equal report; rejects a report for the
  wrong feed ID; accepts reports through `managerData`.
- Band floor (A6.1): offset the index by its measured error, mark and trade at fair value through the narrowing
  period; nothing reverts.
- Depeg jump (A7): a 10% step in the stream; marks catch up within the stated time; liquidations run; no account ends
  negative beyond SecurityModule coverage.
- Recovery and owner powers: A8.7.

## A6. Conditions for listing (must be met)

**A6.0 Data Streams.** Done 2026-11-14: subscription, feed IDs, schema, cadence, verifier proxy, and fee (none on
Base today) (A2.1).

**A6.0a Manipulation cost sets the OI cap (binding).**
1. Get the DEX venues and weights behind the EURC stream and measure their depth, including the thinnest hours.
2. For every size and duration of skew, the cost of holding it against what it gains through (a) the fixing, (b)
   marks and the VM they move, (c) liquidations it triggers, at any hour.
3. Cap open interest below the cheapest attack's cost with a safety factor, with the existing asset caps.
4. Re-measure on a schedule; lower the cap when depth falls. Record each measurement in the repo.

**A6.1 Band floor.** `minMarkIndexDeviation ≥ the index's measured error + the forward's distance from spot near
expiry`.

**A6.2 Alerts.** Thresholds for divergence from EUR/USD, the push feeds and the pool, routed to operators; prove each
fires.

**A6.3 Fixing parameters.** `fixingWindow` and `maxSampleGap` so the TWAP is costly to move (A6.0a) and the keeper can
sample reliably; `recoveryDelay` (A8.2).

## A7. Sized for a depeg

- **Initial margin** covers a depeg-sized jump (USDC fell ~12% over a weekend in March 2023), not EUR/USD moves.
  EURC-30NOV26's 6% / 4% was sized to EUR/USD and does not carry over.
- **Marks follow a jump within a stated time:** `maxMarkDeviation`, `minMarkInterval` and the narrowest band set
  together. In v2 a jump wider than the band plus one deviation step **froze** the mark (one step cannot reach the
  band and every intermediate step is outside it; near expiry, a few percent). v3 lets a mark outside the band move if
  it is strictly closer to the index, and clamps a feed mark to one step instead of refusing it, so a jump `J` is
  followed in `ceil(J / maxMarkDeviation) × minMarkInterval`, permissionlessly. Tests:
  `testADepegStepDuringARecoveryIsMarkedAndPaid`, `testAMarkOutsideTheBandMustMoveTowardsTheIndex`.
  The live cNGN-30NOV26 (v2: 5% steps, band 10% → 1% over the last 14 days, OI 0.7 contracts on 2026-11-14) has the
  freeze; the remedy there is an owner `setIndexParams` widening the band.
- **SecurityModule coverage** sized against the OI cap for a jump larger than margin that lands before marks catch up.

## A8. Fixing always completes: the new `FutureAsset` version (decided)

Samples are accepted only between `expiry − fixingWindow` and expiry, and a fixing completes only if no gap exceeds
`maxSampleGap` (`FutureAsset.sol` `recordFixingSample`, `_fixingComplete`). Without recovery, one gap freezes the
series and every position's margin permanently.

### A8.1 A new version beside the old

Built 2026-11-14 as `src/assets/FutureAsset.sol` with `src/interfaces/IFutureAssetV3.sol`; v2 frozen at
`src/legacy/v2/FutureAssetV2.sol` (bytecode matches both deployed v2 series). `IFutureAsset` is unchanged: the engine
calls only `contractSize`, `futureContracts`, `getPendingVM` and `settleAccountVM` (FutureVMLib), and v3 keeps those
selectors and the `FutureContract` layout; v3 leaves out `setSettlementPrice` and `fallbackReference`. The constructor
takes the initial index feed and the immutable `feedTimelock`. `setIndexParams` bounds the fixing parameters
(`recoveryDelay ≤ 7 days`, `fixingWindow ≤ 1 day`, `maxSampleGap ≥ 1 minute`) so no setting can stop a series
settling. Tests: `TestMarginEngine_FutureV3`; each guard was broken and seen to fail its test.


Live cNGN-30NOV26 and EURC-30NOV26 are deployed from today's `FutureAsset.sol`, which stays reproducible. The new
version keeps `IFutureAsset` unchanged so `MarginEngine` works with it as is. Placement (decided): today's file moves to
`src/legacy/v2/FutureAssetV2.sol` in a pure move-and-rename commit whose bytecode must match the deployed cNGN asset,
then the new version is written as `src/assets/FutureAsset.sol`. This is
Step 1's risk-core change and sets the audit scope.

### A8.2 Recovery windows

- **Trigger:** after expiry, if the fixing is incomplete, anyone opens a recovery window. No owner action.
- **Window:** same `fixingWindow` and `maxSampleGap`, starting `recoveryDelay` after the break.
- **Broken-window samples are discarded,** not merged.
- **If a recovery window breaks, the next opens.** The series settles once the stream and the chain work for one full
  window.
- Settlement is always from the streams. Never EUR/USD, never a chosen price.

### A8.3 Marks until settlement

`pullMark` runs until the series is settled, not only until `lastTradeTime`, so margin follows the price during a
recovery. Consequences to state in user-facing docs:
- after expiry the published forward difference is zero (spot is what the contract converges to);
- during the outage that caused the break, marks cannot move either (`pullMark` reads the stale index);
- holders cannot exit after `lastTradeTime` (only the manager moves positions), so they carry depeg risk until
  settlement. Consistent with A0.

### A8.4 Why recovery should be rare

`EurcIndexFeed` reverts only on staleness and anyone can post reports, so an attacker cannot force a gap; only a
stream or sequencer outage can. If a divergence halt were ever added back, breaking the fixing would become a way to
choose a later settlement time and would need its own analysis.

### A8.5 No owner price (decided)

- **`setSettlementPrice` is removed** from the new version.
- **`indexFeed` changes are timelocked and pinned per window.** Today `setIndexParams` is `onlyOwner` with no timing
  restriction and `recordFixingSample` reads `indexFeed` live, so an owner could point it at any contract mid-window
  and choose the settlement price with no band and no delay. In the new version a feed change is announced, waits a
  timelock, emits an event, and applies only to windows opened after it takes effect; each window records its feed in
  its `Fixing` struct, as `maxSampleGap` is recorded today.
- **A discontinued stream** is handled by announcing a replacement feed; once the timelock passes, the next recovery
  window samples it and the series settles from a feed, not from a chosen number.
- **Remaining owner levers on marks** (`setMark`, `setMarkBounds`, band parameters) move VM within bounds but not the
  settlement price. Review their bounds for a depeg-sized market (A7).

### A8.6 Not adopted: late-report backfill

Filling gaps in the original window with late reports by observation time: dropped. It needs historical reports by
timestamp and sampling by observation time rather than `recordFixingSample`'s rules, and repeating windows already
guarantee settlement.

### A8.7 Tests (prove each fires)

- a gap in the window → `fixSettlementFromIndex` reverts → a recovery window opens → the series settles from it;
- the recovery window also breaks → the next opens and settles;
- broken-window samples don't affect the recovery price;
- a feed change during an open window → that window still samples the old feed; a change before the timelock passes
  is refused;
- a 10% step during a recovery → marks follow, liquidations run, no account negative beyond SecurityModule coverage;
- **ABI check:** no function sets a settlement price, and every function that changes `indexFeed` is behind the
  timelock (on the model of `scripts/ops/abi_selectors.py`).

---

# Part B: Step 2, `OnchainBook`

## B1. Purpose

Move matching for the EURC market out of the whitelisted executor (`Matching.verifyAndMatch`, `onlyTradeExecutor`)
into a contract: anyone trades directly and atomically; makers quote with oracle-pegged curves repriced by one update.

## B2. Reuse, don't rebuild

`OnchainBook` adds matching only: no OI caps (`checkAllAssetCaps` already runs; a second cap could disagree and freeze
holders), no depeg breakers, no settlement feed, no sequencer-outage changes to liquidation.

## B3. Custody (decided)

`Matching` owns every account it trades, so `OnchainBook` cannot reach them. Makers and takers use separate
subaccounts outside `Matching`, each granting `OnchainBook` allowances on the future and on cash
(`FutureAsset.handleAdjustment` always returns `needAllowance = true`).

**Allowances are consumed:** `SubAccounts` subtracts every transfer and reverts with
`NotEnoughSubIdOrAssetAllowances` when one runs out (`Allowances.sol`). Makers and takers set `type(uint).max` on the
future and on cash in both directions; revoking is setting them to 0; transferring the account NFT drops them
(allowances are keyed by owner).

Once granted, `OnchainBook`'s code is the only thing protecting those accounts. Every authorization check ties the
caller to the account owner (or an approved operator). Runbook: revoking, what happens to live splines, moving funds
back to a `Matching`-held account.

## B4. Manager permissions

`OnchainBook` is never a `trustedRiskAssessor` (maintenance-only checks, `MarginEngine.sol:418`).
`feeBypassedCaller`: open, default no.

## B5. Settlement of a fill

The same transfers `TradeModule` builds for a dated future: position transfer with the fill price in `assetData`,
`amtQuote = 0`, plus fees. Test: identical balance changes to `TradeModule` for the same fill.

## B5a. One failing maker must not freeze the market

- **Taker pre-check** before walking the book: allowances cover the take's maximum in each direction, else revert
  `TakerAllowanceTooLow`.
- **Maker pre-checks** (views): allowance covers this fill's amount in its direction; no live auction. Failures are
  attributable: skip and deactivate (`MakerDeactivated(maker, reason)`).
- **One `submitTransfers` per maker in `try/catch`.** A caught revert only skips the maker for this take and never
  changes stored state: `SRM_PortfolioBelowMargin()` carries no account id and the taker's margin is checked in the
  same batch, so deactivating on catch would let an underfunded taker switch off every maker.
- **Gas floor** before each `try`; revert the take if lower (the 63/64 rule).
- **Permissionless `poke(maker)`** deactivates on `getMargin(maker, true) < 0` or a failed pre-check. It deactivates
  even though position-reducing fills are held only to maintenance (`MarginEngine.sol:393-395`); simpler and safer.
- `minFill` applies to the total. An inactive spline reactivates only on the maker's next update.

## B6. Oracle use

- **Peg:** the adapter's stored EURC/USDC ratio. The EURC stream has no spread (A2.1), so makers set their own around
  it. With no external guard, a DEX skew moves every spline at any hour within the index band. Open (B14): spreads
  sized for skews up to the OI cap, or quoting only in deep-liquidity hours.
- **Newest-report-only** on every path; each fill uses the stored price at the time of the take.
- **Post before transferring.** Reports a taker supplies go to the adapter before `submitTransfers`, as `TradeModule`
  does; the manager's `managerData` pass runs after the asset hooks and is too late for the fill check (A2.2).
- **Index band:** read `indexFeed.getSpot()` and `markIndexBand(expiry)`; stop the walk at the band edge.

## B6a. The stale-price option (main economic risk)

A taker can withhold a newer report and trade against a stale stored price.
- `takeMaxAge` short: splines quote only if the stored price is within `takeMaxAge` of `block.timestamp`, otherwise
  the taker attaches a fresh report or fills nothing from splines.
- Base blocks are 200 ms, timestamps whole seconds: `takeMaxAge = 1` is the floor and means up to ~2 s in real time.
  Makers size `halfSpreadTicks` for a 2-second move.
- **Freshness comes from takers' and makers' own reports.** Verification is free on Base today (A2.1), so a keeper
  posting every second costs gas only and is an option again: measure its gas (B10) and choose. If the fee manager
  ever starts charging, the adapter fails closed (A2.1) and this choice is revisited.

## B7. Splines

Hot state per maker per market in one slot: `offsetTicks`, `halfSpreadTicks`, curve ids, `skewTicksPerLot`,
`refillLotsPerSecond`, `updatedAt`, `ttl`, `seq`, flags. Curves (up to 10 regions a side) preloaded by id.

- `mid = oracleTicks + offsetTicks − skew`; skew from the maker's position at the start of the take, clamped, not
  recomputed between levels.
- Consumption: a per-maker, per-side cursor refilling at `refillLotsPerSecond`, reset on a maker update. Not per block:
  200 ms blocks would hand the best levels out five times a second.
- `updateSplines` batches; each update's maker-supplied `seq` must exceed the stored one. Quotes lapse after
  `updatedAt + ttl`. Best bid < best ask per spline, or the update reverts.
- Priority: price, then registration order. No pro-rata.
- Launch: maker allowlist; makers-per-market cap from B10.

## B8. Taker interface

```solidity
struct TakeOrder {
  uint    marketId;
  uint    takerAccountId;
  bool    isBuy;
  uint    amount;
  uint    limitPrice;     // worst acceptable price
  uint    minFill;        // revert if less
  uint    maxFee;         // fee + priority-fee tax, in USDC; revert if exceeded
  uint64  deadline;
  uint16  maxLevels;
  uint8   selfTradeMode;  // Abort or DecrementTake
  bytes   managerData;
}
function take(TakeOrder calldata o, bytes calldata optionalReport) external returns (uint filled, uint avgPrice);
```

`maxFee` is mandatory and enforced (the `worstFee: 0` class: sweep docs and examples). The walk stops at the limit,
the band, `maxLevels` or a full fill. Priority-fee tax built in, off at launch, counted inside `maxFee`.

## B9. Events

`SplineRegistered`, `SplineUpdated`, `SplineCancelled`, `CurvesSet`, `Fill`, `TakeExecuted`, `MakerSkipped`,
`MakerDeactivated`, `ReportAccepted`, `ReportRejected`.

## B10. Gas: measure first

On a fork of live Base: one `handleAdjustment` for a two-account fill and the cost of repeating the taker's check per
maker (gives the gas floor); one report verification, gas plus fee; `updateSplines` for 1 and 10 markets with and
without a report. Then set targets and the makers-per-take cap.

## B11. Tests

Equivalence with `TradeModule`; invariants (net position zero, cash conserved, no fill past the limit or outside the
band, none against an expired spline or stale price, `maxFee` never exceeded, older or equal reports rejected, `seq`
never decreases, bid < ask); adversarial (pool skew within the band, older report, withheld report, reordered
updates, max makers and levels, reentrancy via a taker contract); failing makers, exhausted and transferred
allowances, `TakerAllowanceTooLow`; griefing via catch and via gas; order splitting gets depth only at the refill
rate; one test per revert path. CI: `./scripts/verify.sh` runs the package; gas snapshots.

## B12. Rollout

Spec review → implement → internal review → external audit → Base Sepolia including a short-dated settlement →
mainnet beside the live contracts, maker allowlist, tax off, every admin transaction written back the same day. The
`Matching` path keeps running for the same market.

## B13. v2 order book (constraint only)

Later: a FIFO book (bit-index price tree, O(1) post and cancel, amend, expiring orders, match cap, post-only, IOC,
reduce-only), merged with splines at equal prices without jumping a better resting price; then calendar spreads.
v1 structures the take loop so a second liquidity source can be added without a rewrite.

## B14. Open questions

- Pilot OI cap, from the A6.0a measurement.
- Fixing parameters, proposed 2026-11-14 and awaiting decision: `feedTimelock` 24 h, `fixingWindow` 30 min,
  `maxSampleGap` 2 min, `recoveryDelay` 1 h, `indexMaxAge` 60 s.

Decided 2026-11-14 (kept for the record):
- the old EURC-30NOV26 expires unopened at cap 0; the pilot replaces it (A1.1, A1.2);
- the pilot ships in two stages, `Matching` first; pilot expiry 2026-11-30 15:00 UTC, subId `1796050800` (A1.2);
- file placement: today's `FutureAsset.sol` moves to `src/legacy/v2/FutureAssetV2.sol` (the v1 precedent), the new
  version is `src/assets/FutureAsset.sol` (A8.1);
- Base verifier proxy and fee: recorded in A2.1, no fee today.
- Step 2 spline policy for DEX skews (B6); `feeBypassedCaller` (B4).
- Parameters: tick size, `takeMaxAge`, gas floor, ttl limits, refill rates, makers-per-market cap, tax.
- Licensing: risk-core files are BUSL-1.1 (Lyra/Derive v2 lineage). Confirm the terms permit this product before
  mainnet.
