# EURC-USDC futures and on-chain matching

Status: **v3.6**, 2026-11-15. Supersedes v1 (written against `DatedFutureAsset` and `StandardManager`, which are not the
live contracts) and v2.x–v3.0 (reviewed in conversation, not committed).

- **Step 1** (build now): a new `FutureAsset` version with recovery fixing and no owner price, `StreamsIndexAdapter`,
  a staleness-only `EurcIndexFeed`, traded through the existing `Matching` path. Listing waits on the measurements in
  A6 and A7. Data Streams access is in place (A2.1).
- **Step 2** (`OnchainBook`, oracle-pegged maker curves): gated on a concrete taker, **except for the EURC-30NOV26
  pilot (A1.2)**, for which the gate is lifted.
- **Stage 3** (Part C, design direction 2026-11-17, not built): a composable venue. Self-priced maker quotes so takers
  attach nothing, a quote view and a router, then resting orders, a maker vault and tokenized positions for lending.

The pilot ships in two stages (A1.2): Stage 1 lists the new series on `Matching` as soon as its mainnet canary
(A1.4) passes; Stage 2 adds `OnchainBook` to the same market behind its own gate. The market never waits for `OnchainBook`.

**v3.6 changes from v3.5:** Stage 2 started: `OnchainBook` is built and tested (B15), with four departures from
this spec (a failed maker's size is re-planned to the others, one transfer per maker at its average price,
`DecrementTake` excludes the taker's own maker, the tax is its own transfer), two defects found by its tests and fixed
(a maker-chosen manager on every take; an out-of-gas batch caught as a skip), and B10's gas measured on a Base fork.

**v3.5 changes from v3.4:** the Stage 1 gate is a mainnet canary (A1.4) in place of the Base Sepolia run: a short
series the deployer lists on the same contract, drilled with a broken fixing against Chainlink's real verifier.

**v3.4 changes from v3.3:** the Stage 1 independent review is done and its owner-lever findings are fixed in
`FutureAsset` (A8.8): each series keeps the fixing parameters it was listed with, with tighter bounds; a feed change
after last trade is a rescue only and a proposal lapses; `setMark` obeys `minMarkInterval`; marks come from the index
from last trade; the enable batch registers on `TradeModule` before opening the cap.

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
  - the settlement price comes from thin on-chain markets with no external guard. Open interest was to be capped below
    the cost of manipulating them (A6.0a); **the owner decided on 2026-11-15 to list the pilot uncapped**, accepting
    that risk (A6.0a, "Decision");
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

### A1.1 Already live: EURC-30NOV26 (open since 2026-10-31)

`DEPLOYED_ADDRESSES.md` and `docs/margin-engine-v2.md` record a series built on the current `FutureAsset`:

- `FutureAsset` `0x6Ff7084D6F1760a57b9475a41F54b12279cD7744`, market 2 (EUR) on MarginEngine v2, 1,000 EURC a
  contract, expiry 2026-11-30 16:00 UTC. Set up 2026-10-30; IM 6% / MM 4%; **enabled 2026-10-31 at cap 18**.
- Index: the EUR market's spot feed `0xaaE6…C435` (Chainlink EURC/USD push). The same feed is the market's spot feed.
- Owner fallback 24 h after expiry within 2%.

It predates every decision in this spec. **Correction 2026-11-14:** v3.1 and v3.2 called it closed, from a stale
heading in `DEPLOYED_ADDRESSES.md`, and the decision to let it "expire unopened at cap 0" rested on that. On chain it
is open: cap 18e18, open interest 0.022e18, registered on the `TradeModule`, makers quoting since 2026-10-31.

**It also blocks the pilot on market 2.** `MarginEngine` holds one future per market (`assetMap[marketId][Future]`),
and `whitelistAsset` *replaces* the holder: listing the new asset on market 2 would de-list this one while accounts
hold it. Open (B14): where the new series lives, and what happens to this one, before Stage 1 deploys.

Carried forward from it: **a series is its subId (the expiry), and `closeOutExpired` couples every market that lists
that expiry.** A recovery fixing (A8) can delay settlement by hours, so every EURC expiry must have a subId no other
market lists. The existing deploy script already refuses a shared expiry; keep that check in the new one.

### A1.2 Pilot: EURC-30NOV26 on the new version, in two stages (decided 2026-11-14)

A new series beside the live old one (A1.1): one asset and one subId, first traded through `Matching` (Stage 1), then also
through `OnchainBook` (Stage 2). Adding `OnchainBook` needs no redeploy: `FutureAsset.handleAdjustment` does not gate
on the trade module, only on the manager.

- **Expiry 2026-11-30 15:00 UTC, subId `1796050800` (a Monday).** 16:00 (1796054400) is held by the old, live series
  and 14:00 (1796047200) by cNGN-30NOV26; a subId is the expiry (`getSubId`), and `closeOutExpired` couples markets
  that share one (A1.1).
- **Keyed by address and subId, never by name.** The indexer, markets service and `@numo/abis` key the series by
  (asset address, subId); two assets will both read as "EURC-30NOV26".
- **OI cap:** none, by the owner's decision of 2026-11-15 (A6.0a), for both stages.

**Stage 1: new `FutureAsset`, `StreamsIndexAdapter` and `EurcIndexFeed` on mainnet, traded through `Matching`.**
Target 2026-11-18/19. Opens only when all of these hold:
- the **mainnet canary** passes (A1.4): a short series on the same contract, one contract between two of our own
  accounts, a **deliberately broken fixing** recovered by A8 against Chainlink's real verifier, close-out with cash
  conserved and the USDC back. Decided 2026-11-15, in place of the Base Sepolia run: Sepolia could only use a
  stand-in verifier, and the canary tests the real one. The Sepolia tooling and the local drills stay (A1.3).
  **Passed 2026-11-15** (A1.4, "Result");
- the full `./scripts/verify.sh` is green;
- a fast independent review of `FutureAsset`'s fixing and recovery code, the adapter and the feed is done. Stopgap
  until a human reviewer can start: a fresh Claude session given only those files and this spec. **Done 2026-11-15**:
  no critical or high findings; the owner-lever findings are fixed (A8.8).

**Stage 2: `OnchainBook` added to the same market.** Scope: splines only (no order book), a maker allowlist,
priority-fee tax off. Step 2's concrete-taker gate is lifted for this pilot only. Before it is enabled:
- the full B11 suite, including every guard-firing and griefing test;
- a targeted independent review of the allowance handling (B3, B5a pre-checks), the per-maker `try/catch` and gas
  floor (B5a), and its use of the index (B6);
- a full Base Sepolia rehearsal with `OnchainBook` on a short-dated series.

**Go/no-go for Stage 2: 2026-11-24.** If it isn't ready, the market runs on `Matching` through expiry and
`OnchainBook` targets the next expiry. Nothing is redeployed either way.


**A1.3 The Sepolia rehearsal (no longer the gate: replaced by A1.4 on 2026-11-15).** `scripts/rehearse-eurc-v3-sepolia.s.sol` deploys the series with the
production `DeployEurcFutureV3.deploy` (fixing parameters, 15% / 10% margin, no cap) into a minimal stack: real
`SubAccounts` and `MarginEngine` v2, the unit tests' mock cash, auction and spot feed, and
`scripts/rehearsal/StandInStreamsVerifier.sol` in place of Chainlink's verifier. The stand-in checks one signature
exactly as Chainlink's does and refuses Base mainnet; the keeper signs reports with `DATA_STREAMS_STANDIN_KEY`, which
`forward-config` refuses on mainnet. Not covered by the rehearsal, and covered by the mainnet fork tests instead:
Chainlink's verifier, the live `TradeModule` and `Matching`. Steps: deploy; start the keeper; open 10 contracts; stop
the keeper for longer than `maxSampleGap` inside the window and restart it at a different price; after settlement,
close out and require cash conserved.

Local dress rehearsals on anvil, with the chain clock advanced 5–10x, 2026-11-15:
- **Run 1:** an outage gave a 276 s gap (limit 120 s); the keeper opened recovery round 1 on restart, the
  `fixing-recovery-opened` alert reached the webhook, round 1 settled at 1.16; cash conserved.
- **Run 2, price moved to 1.17 at the restart:** round 0 broke (398 s gap); round 1 also broke (200 s, from the 10x
  clock outrunning the 60 s index age), and round 2 opened by itself and settled at 1.17. Index marks ran through the
  recovery and moved the mark to 1.17 before settlement (alice's pending VM +100 USDC). Close-out: alice +100, bob
  −100, pool 0, cash conserved.
- **Found and fixed by them:** the keeper stopped marking at last trade, so nothing pulled the v3 index marks A8.3
  relies on (`ForwardPublisher.indexMark`); and the stand-in reports are stamped with chain time.

**A1.4 The mainnet canary (Stage 1 gate, decided 2026-11-15).** `deploy-eurc-future-v3.s.sol` with
`CANARY_EXPIRY=<unix>` has the deployer, while it still owns the future, list a canary series before the production
one: a 15-minute fixing window (the contract's minimum), a 5-minute recovery delay, and production's 2-minute sample
gap and 60 s index age, so the drill's outage is judged by the real limits. The production series is listed after it on
30 min / 2 min / 1 h, which stay the contract's defaults. No extra vault action: the canary rides the same setup and
enable batches. The deploy refuses a canary less than 2 h out (setup and enable must land before its last trade), more
than a week out, on an expiry another market lists, or one that would settle, recovery included, after the production
series' fixing opens. Exactly one of `CANARY_EXPIRY` or `NO_CANARY=true` must be set. The proposer's parity gate checks
the canary's listing and fixing params against the artifact.

What it covers that nothing else has: Chainlink's verifier on real reports in real transactions, the production
keeper unit with the KMS forward signer and the subscription's credentials, and mainnet block times. Not covered: the
`TradeModule` and `Matching` fill path, because the canary moves its one contract by a priced transfer (the
fork tests cover that path; the first public fill is its first mainnet use).

Order:
1. **Deploy** with `CANARY_EXPIRY` 3–4 h out, then write `future-feeds-v3-eurc-30nov26.env` and
   `future-feeds-v3-eurc-canary.env` from the artifact. Each keeper instance (`numo-future-feeds-v2@…`,
   `FUTURE_VERSION=v3`) has its own funded relayer under `/numo/feeds`: two keepers sharing one race for nonces.
2. **Setup batch** (`eurc-v3-setup`), start both keepers (a dry run first), then the **enable batch**. Enable opens
   the whole contract, the production series included, but nothing fills it in public: the markets service does not
   list it until the canary has passed.
3. **Open**: `CANARY_KEY=<throwaway key> forge script scripts/canary-eurc-v3.s.sol --sig "open()"`. Two accounts,
   300 USDC each, one contract (1,000 EURC) at the index.
4. **Break**: inside the canary's window, stop the canary keeper for over 2 minutes, then restart it. Round 0 cannot
   complete; after expiry the keeper opens a recovery window 5 minutes out, samples it, and settles.
5. **Close**: `... RETURN_TO=<address> --sig "closeOut()"`. Both close out; the VM must net to zero and cash be
   conserved across the close-out; every whole cent goes to `RETURN_TO`. Read balances back after broadcasting.
6. **Then** list the production series in the markets service.

About 40 minutes from the canary's last trade to close-out; the wait before that is the vault's approvals. If the
canary is missed (its last trade passes before enable), its fixing and recovery still run, unpositioned, and a
second canary needs the vault's `setContract`. If it fails: the vault sets the cap to 0 before anything is listed.
`EurcFutureV3Fork` runs the drill script's own `openOn` and `closeOutOn` on a fork, with only the verifier mocked.

**Result, 2026-11-15: passed.** Canary `1794776400` (expiry 21:00 UTC) on `0xC350…b227`, accounts 54 (long) and 55
(short), one contract opened at 1.0999746 by a priced transfer.
- **Break:** the canary keeper was stopped 20:49:03–20:53:34 UTC. At expiry, round 0 had a 276 s gap (limit 120 s),
  and the keeper opened recovery round 1 (tx `0xffd18423…0d`); `fixing-recovery-opened` fired.
- **Settle:** round 1 sampled 21:05–21:20 against Chainlink's verifier and settled at **1.1012790** at 21:20:32 (tx
  `0x435f78de…3937`). The first attempt hit a 429 from `mainnet.base.org` on `eth_sendRawTransaction` and the
  keeper's retry landed.
- **Close-out:** the keeper itself closed out 54 and 55 (`0x50ce1435…`, `0x16015c93…`), so the drill script's
  `closeOut()` was not used and conservation was read from chain at blocks 57936391 and 57936397. Pending VM was
  ±2.069421147 USDC and moved exactly between the two accounts. The three-account sum (54, 55 and pool 37) moved by
  −1.6e-6 USDC across the 6 blocks, which is interest. The long's net was +1.304433 USDC = 1,000 × (1.1012790 −
  1.0999746).
- **USDC back:** 301.304433 + 298.695566 withdrawn to the engine keeper wallet, then 599.999999 re-deposited to #38
  (5,000.006 USDC after). The canary keeper unit is stopped and disabled.
- **Found:** `closeOutOn` assumes it runs the close-out, but the keeper closes out expired accounts first; the fork
  test passed only because no keeper ran in it. For a later canary, read conservation from chain as above or make
  `closeOutOn` skip a closed account. The trading app showed the canary's contract as $1.1K open interest on the
  production market, so it counts the whole `FutureAsset` and not the series.

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
  - Then **every manager a fill touches** passes the same data again and requires the receiver on its own
    whitelist. A fill through `TradeModule` pays the taker fee to account #22, which is under the perp SRM
    (`0xDE04…D5D4`), not v2: attached reports revert `BM_UnauthorizedCall` there even with the adapter whitelisted on
    v2 (`EurcFutureV3Fork.testAttachedReportsRevertOnTheFeeAccountsManager`, 2026-11-15). Attaching therefore needs the
    adapter whitelisted on the SRM too, or the fee account moved under v2. Equal reports in the later passes are
    skipped unverified.
- Between trades, a keeper posts reports only where something needs a fresh index: each `pullMark`
  (`minMarkInterval`) and each fixing sample (`maxSampleGap`). Anyone may post.
- **Stage 1 (A1.2) keeps the index fresh with the keeper alone**, posting well inside `indexMaxAge`, because a fill is
  checked against the index, and attaching reports needs executor changes and the whitelist above. Its setup batch
  whitelists the adapter nowhere. Attaching can follow without a contract change.
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

1. Deploy the new `FutureAsset` version (A8) with `contractSize = 1000e18`, on an expiry no other market lists (A1.1):
   `scripts/deploy-eurc-future-v3.s.sol`, rehearsed by `test/fork/EurcFutureV3Fork.t.sol`. Its setup batch lists the
   future on market 2, replacing the retired series, only while that series is empty (`checkSlotFree`).
2. Whitelist `MarginEngine` on the asset.
3. Deploy `StreamsIndexAdapter` (verifier proxy, both feed IDs) and `EurcIndexFeed`. Set the index feed (A8.5) and
   `setIndexParams(maxMarkIndexDeviation, minMarkIndexDeviation, bandNarrowingPeriod, fixingWindow, maxSampleGap,
   recoveryDelay)`, before step 7: a series takes the fixing parameters in force when it is listed, for good. Confirm each push feed with `cast call <proxy> "description()(string)"` and `"decimals()(uint8)"`.
4. Stage 1: no `setWhitelistedCallee` (the keeper posts reports). Attaching later needs it on `MarginEngine` and on
   the fee account's manager (A2.2).
5. Forward feed for marks: `setForwardFeed(forwardFeed, minMarkInterval)`, reusing the cNGN publisher setup.
6. `setMarkBounds(maxMarkDeviation, maxMarkDelay)`.
7. `setContract(expiry, lastTradeTime, initialMarkPrice)`. Refused until step 3's fixing parameters are set.
8. `MarginEngine`: `whitelistAsset(future, 2, Future)`, `setFutureMarginRequirements(2, mm, im)` sized per A7.
9. EURC collateral already exists on market 2 (escrow `0xfD2A…6cD9`); its v2 cap is a separate, depth-gated decision.
10. `TradeModule.setDatedFutureAsset(future, true)`, then `future.setTotalPositionCap(engine, cap)` per A6.0a, in that
    order: until the future is registered a fill carries no price and skips the band check, and the cap of 0 holds
    fills off until then.
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

**Measurement 1, 2026-11-15 04:39 UTC (Base block 57635919).** `scripts/ops/eurc_depth/depth.py --once` on the ops
box (provider RPC, scratch CSV, no webhook), the depth tool the EURC spot cap uses: the input whose marginal price is
2% worse than a $10 trade's, summed over every Base EURC/USDC pool.

| 2% depth, Base | 2026-10-21 | 2026-10-28 | 2026-11-15 |
|---|---|---|---|
| sell (EURC in), EURC | 590,051 | 37,968 | **10,665** |
| buy (USDC in), USDC | 696,514 | 346,092 | **167,090** |

Main Slipstream pool (ts50) sell depth 484,445 → 1,687 EURC. The largest-LP check was unreadable (RPC 429).

- **Step 1 is not done:** Chainlink does not publish the venues or weights behind `EURC/USD-Streams-DexPrice`. Until
  they are known, the cap assumes the cheapest case, Base pools alone.
- **Cost of a skew:** pushing Base's EURC price down 2% sells about 10,665 EURC at an average slippage near 1%:
  roughly **$120 a push**, before arbitrage undoes it. The sell side is the cheap one.
- **What one push buys:** a sample the attacker posts and records itself (`recordFixingSample` is permissionless),
  weighted until the next sample; or a pulled mark, which moves at most one `maxMarkDeviation` step (2%) and moves VM
  on every position at once.
- **Cap, Base-only:** one side's notional × δ must stay under the push's cost ÷ a safety factor of 2: one side at most
  about depth(2%) ÷ 4 ≈ $2,900, **2 contracts a side, a cap of 4** (both sides counted).
- **Recommendation:** list at 4 only if the pilot's purpose survives it; otherwise get the stream's venue weights from
  Chainlink first. If Base is a small share of an aggregate across chains, a push costs proportionally more and the
  cap rises with it.
- **Also found:** the EURC **spot** cap on v2 (18,000 EURC) now fails its own gate (50% of 2% sell depth, about 5,300
  EURC). 3,281 EURC is held, under that. The depth timer stopped sampling at its 7-day window on 2026-10-28, so this
  raised no alert.

**Decision, 2026-11-15: no OI cap.** The owner chose to list the pilot uncapped (`FUTURE_OI_UNCAPPED=true`: the cap is
`type(uint256).max`) and accepts, in full:
- **index manipulation:** above roughly 2 contracts a side (measurement 1, Base-only), pushing the index can pay for
  itself; the loss falls on the other side, then the SecurityModule;
- **SecurityModule:** a jump larger than margin is covered only up to what the module holds after cNGN-30NOV26; beyond
  it, winners are paid short. The module is shared, so EURC losses can also use cover sized for cNGN;
- **liquidation:** v2's keeper takes over accounts only up to its cash; beyond it, an under-margin account may wait for
  another liquidator.

What still holds: the enable batch's `sm` and `keeper` gates block for cNGN-30NOV26 at its cap, and two informational
gates report how many EURC contracts each backstop covers (`sm-capacity`, `keeper-capacity`). The pager pages on actual
open interest: `sm-coverage` (already summed every v2 series) and `keeper-capacity-v2` (new). Both need the v3 artifact
in the pager's `FUTURE_V2_ARTIFACTS`, which is a cutover step, and a drill on the box. The remedy either names is to fund
the backstop, or to set a cap at current open interest (one vault transaction, which makes the market close-only). Rehearsed
by `testUncappedDeploysAndFillsFarOverTheMeasuredCap` (a 50-contract position fills; under an 18-contract cap it
reverts `BM_AssetCapExceeded`).

**A6.1 Band floor.** `minMarkIndexDeviation ≥ the index's measured error + the forward's distance from spot near
expiry`.

**A6.2 Alerts.** Thresholds for divergence from EUR/USD, the push feeds and the pool, routed to operators; prove each
fires.

**A6.3 Fixing parameters.** `fixingWindow` and `maxSampleGap` so the TWAP is costly to move (A6.0a) and the keeper can
sample reliably; `recoveryDelay` (A8.2).

## A7. Sized for a depeg

- **Initial margin** covers a depeg-sized jump (USDC fell ~12% over a weekend in March 2023), not EUR/USD moves.
  EURC-30NOV26's 6% / 4% was sized to EUR/USD and does not carry over. **Decided 2026-11-15: IM 15%, MM 10%**, the
  deploy script's defaults.
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
(`recoveryDelay ≤ 6 hours`, `15 minutes ≤ fixingWindow ≤ 1 day`, `1 minute ≤ maxSampleGap ≤ fixingWindow / 4`) so
no setting can stop a series settling or reduce its fixing to a few samples, and `setContract` copies them into the
series (`seriesFixing(subId)`): a later `setIndexParams` reaches only series listed after it. Tests: `TestMarginEngine_FutureV3`; each guard was broken and seen to fail its test.


Live cNGN-30NOV26 and EURC-30NOV26 are deployed from today's `FutureAsset.sol`, which stays reproducible. The new
version keeps `IFutureAsset` unchanged so `MarginEngine` works with it as is. Placement (decided): today's file moves to
`src/legacy/v2/FutureAssetV2.sol` in a pure move-and-rename commit whose bytecode must match the deployed cNGN asset,
then the new version is written as `src/assets/FutureAsset.sol`. This is
Step 1's risk-core change and sets the audit scope.

### A8.2 Recovery windows

- **Trigger:** after expiry, if the fixing is incomplete, anyone opens a recovery window. No owner action.
- **Window:** the series' own `fixingWindow` and `maxSampleGap`, starting its `recoveryDelay` after the break (all
  three fixed at listing, A8.1).
- **Broken-window samples are discarded,** not merged.
- **If a recovery window breaks, the next opens.** The series settles once the stream and the chain work for one full
  window.
- Settlement is always from the streams. Never EUR/USD, never a chosen price.

### A8.3 Marks until settlement

`pullMark` runs until the series is settled, not only until `lastTradeTime`, so margin follows the price during a
recovery. Until `lastTradeTime` it reads the forward feed; from `lastTradeTime` on it reads the index (the forward
publisher stops at last trade and its last forward ages out before expiry, which left the last ~25 minutes with no
permissionless mark). Consequences to state in user-facing docs:
- from last trade the mark is the index: the forward difference that close to expiry is negligible, and after expiry
  it is zero (spot is what the contract converges to);
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
- **A proposal lapses** if not activated within `FEED_ACTIVATION_PERIOD` (2 days) of its timelock ending, so none is
  held in reserve for a moment of the owner's choosing.
- **After last trade a feed change is a rescue only.** While any series is past `lastTradeTime` and unsettled, its
  holders cannot exit, so `activateIndexFeed` requires the current feed to be failing now and to have given no price
  for a full fixing window of every such series (`lastIndexReadAt`, stamped by every mark, priced fill and sample of
  the current feed). Anyone holding Data Streams reports keeps the current feed alive by posting them, and so blocks a
  change. Before last trade the timelock alone applies: holders see the proposal and can exit.
- **A discontinued stream** is handled by announcing a replacement feed; once the timelock passes and the old feed has
  been dead a full window, the next recovery window samples it and the series settles from a feed, not from a chosen
  number.
- **Remaining owner levers on marks** (`setMark`, `setMarkBounds`, band parameters) move VM within bounds but not the
  settlement price. `setMark` obeys `minMarkInterval` like `pullMark`, so the owner can neither mark faster than anyone
  else nor hold permissionless marks off for longer than one interval. Review the bounds for a depeg-sized market
  (A7).

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

### A8.8 Independent review, 2026-11-15

A fresh session given only `FutureAsset`, `StreamsIndexAdapter`, `EurcIndexFeed` and this spec. No critical or high
findings: nobody, the owner included, can name a settlement price. It found owner levers that shaped or delayed the
fixing, each proven with a throwaway test. Fixed, each with a test reproducing the attack and now failing, and each
guard broken and seen to fail its test (`TestMarginEngine_FutureV3`):

| # | Finding | Fix | Test |
|---|---|---|---|
| 1 | `setIndexParams` could shrink the fixing to one sample (window = gap = 60 s): 1.13 against an index of 1.10 | Per-series params fixed at listing; window ≥ 15 min, gap ≤ window / 4 | `testTheOwnerCannotShrinkAListedSeriesFixingToOneSample` |
| 2 | A feed proposal never lapsed and anyone could activate it after last trade: 1.50 against 1.10 | Lapses after 2 days; after last trade only a rescue of a dead feed (A8.5) | `testAFeedProposalCannotBeActivatedAfterLastTradeWhileTheFeedIsAlive`, `testAfterLastTradeTheFeedMustBeDeadForAFullWindow`, `testAFeedProposalLapses` |
| 3 | Widening the window just before round 0 forced it to fail; a 7-day delay pushed each retry a week | Per-series params; `recoveryDelay ≤ 6 h` | `testTheOwnerCannotStretchAListedSeriesRecovery` |
| 4 | `setMark` was not rate-limited and reset `pullMark`'s cooldown: 8% in one block | `setMark` obeys `minMarkInterval` | `testTheOwnersMarkObeysTheMarkInterval` |
| 6 | The enable batch opened the cap before `TradeModule` registration | Registration first (A3 step 10) | `propose_eurc_future_v3_batch.py --self-test` |
| 7 | No permissionless mark from ~expiry − 25 min to expiry | Index marks from last trade (A8.3) | `testMarksRunFromTheIndexFromLastTrade` |

Not changed: (5) a sampler chooses when to sample, and a favourable sample holds until the next; frequent keeper
samples (every 20 s against a 2-minute gap limit) bound it, as already stated. Margin is now 15% / 10% (A7, decided 2026-11-15). Residual on (2): the owner runs the only report poster today, so it can let the feed die;
a change then still needs a full dead window and the 24-hour public timelock, and anyone else with Data Streams access
can block it by posting reports.

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

Every take calls into each maker's manager (the auction check), so a maker's account must be under the market's
engine, checked at `registerMaker`; a market's engine must be a whitelisted manager of its future, checked at
`createMarket`. Checked once: `SubAccounts` sets an account's manager at creation and cannot change it (B15).

## B5. Settlement of a fill

The same transfers `TradeModule` builds for a dated future: position transfer with the fill price in `assetData`,
`amtQuote = 0`, plus fees. Test: identical balance changes to `TradeModule` for the same fill.

One transfer per maker per take, at the maker's average fill price. `FutureAsset` checks only that average against
the band, so the walk stops each **level** at the band edge: a level outside it never rides inside an in-band
average (B15).

## B5a. One failing maker must not freeze the market

- **Taker pre-check** before walking the book: allowances cover the take's maximum in each direction, else revert
  `TakerAllowanceTooLow`.
- **Maker pre-checks** (views): allowance covers this fill's amount in its direction; no live auction. Failures are
  attributable: skip and deactivate (`MakerDeactivated(maker, reason)`).
- **One `submitTransfers` per maker in `try/catch`.** A caught revert only skips the maker for this take and never
  changes stored state: `SRM_PortfolioBelowMargin()` carries no account id and the taker's margin is checked in the
  same batch, so deactivating on catch would let an underfunded taker switch off every maker.
- **A skipped maker's size goes back to the take** (decided in build, B15): the walk is planned in memory, then
  re-planned without each maker that failed, at most once per maker. Without it a failing maker at the best price
  held the whole take away from the others.
- **Gas floor** before each `try`; revert the take if lower (the 63/64 rule). And **a batch that ran out of gas is
  not skipped**: if the `catch` is left with about 1/64 of the gas it started with, the take reverts
  (`OB_BatchOutOfGas`). The floor alone does not cover it: the taker can make every batch heavy through its own
  account, and then chooses the gas that decides which makers fill.
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

**Measured 2026-11-15, re-measured 2026-11-16 after the review fixes** (`test/fork/OnchainBookFork.t.sol`, block 57,985,892, the live v3 stack and Chainlink's
verifier, real reports from the keeper's next post):

| | Gas |
|---|---|
| Take, 1 maker, reports already posted | 1,129,609 |
| Same, both reports verified inside the take | 1,262,953 (verification 133,344; fee 0) |
| Each further maker settled | ~610,000 |
| Take filling 10 makers | 6,619,506 |
| 1 maker, 10 levels | 986,760 |
| `updateSplines`, 1 market, warm | 16,789 |
| `updateSplines`, 10 markets, first write | 756,304 (the spline's owner takes a third slot on first write) |

Nearly all of a maker's cost is the engine's margin checks on the two accounts, not the book. Proposed from this:
gas floor 700,000 (above 64/63 of one batch); makers per market 10 (a worst-case take ~7M gas).

## B11. Tests

Equivalence with `TradeModule`; invariants (net position zero, cash conserved, no fill past the limit or outside the
band, none against an expired spline or stale price, `maxFee` never exceeded, older or equal reports rejected, `seq`
never decreases, bid < ask); adversarial (pool skew within the band, older report, withheld report, reordered
updates, max makers and levels, reentrancy via a taker contract); failing makers, exhausted and transferred
allowances, `TakerAllowanceTooLow`; griefing via catch and via gas; order splitting gets depth only at the refill
rate; one test per revert path. CI: `./scripts/verify.sh` runs the package; gas snapshots.

**Status 2026-11-15** (B15): unit (`test/periphery/OnchainBook.t.sol`), invariant
(`test/periphery/OnchainBookInvariant.t.sol`) and fork (`test/fork/OnchainBookFork.t.sol`) suites. Every guard was
removed in turn and seen to fail a test. Not yet covered: pool skew within the band (needs the Aerodrome pool on a
fork), reordered updates across makers in one block, and gas snapshots in CI.

## B12. Rollout

Spec review → implement → internal review → external audit → Base Sepolia including a short-dated settlement →
mainnet beside the live contracts, maker allowlist, tax off, every admin transaction written back the same day. The
`Matching` path keeps running for the same market.

## B13. v2 order book (constraint only)

Later: a FIFO book (bit-index price tree, O(1) post and cancel, amend, expiring orders, match cap, post-only, IOC,
reduce-only), merged with splines at equal prices without jumping a better resting price; then calendar spreads.
v1 structures the take loop so a second liquidity source can be added without a rewrite.

## B14. Open questions

- **Blocking Stage 1:** the old EURC-30NOV26 is open with positions and holds market 2's only future slot (A1.1).
  Where the new series lives (a new futures-only market, or market 2 after the old one settles and closes out) and
  what happens to the old one.
- ~~Pilot OI cap, from the A6.0a measurement~~: decided 2026-11-15, none (A6.0a).
- Fixing parameters, proposed 2026-11-14 and awaiting decision: `feedTimelock` 24 h, `fixingWindow` 30 min,
  `maxSampleGap` 2 min, `recoveryDelay` 1 h, `indexMaxAge` 60 s.

Decided 2026-11-14 (kept for the record):
- ~~the old EURC-30NOV26 expires unopened at cap 0~~: withdrawn, it is live (A1.1);
- the pilot ships in two stages, `Matching` first; pilot expiry 2026-11-30 15:00 UTC, subId `1796050800` (A1.2);
- file placement: today's `FutureAsset.sol` moves to `src/legacy/v2/FutureAssetV2.sol` (the v1 precedent), the new
  version is `src/assets/FutureAsset.sol` (A8.1);
- Base verifier proxy and fee: recorded in A2.1, no fee today.
- Step 2 spline policy for DEX skews (B6); `feeBypassedCaller` (B4).
- Parameters: tick size, `takeMaxAge`, gas floor, ttl limits, refill rates, makers-per-market cap, tax.
- Licensing: risk-core files are BUSL-1.1 (Lyra/Derive v2 lineage). Confirm the terms permit this product before
  mainnet.

### B14a. Stage 2 decision sheet (2026-11-16, for the 2026-11-24 go/no-go)

Each row is the owner's call; the recommendation is the reviewer's, with its reason. Every value is a deploy-script
env (`deploy-onchain-book.s.sol`) or a vault `setMarketParams` later, never a code change.

| Decision | Recommended | Why | Alternative |
|---|---|---|---|
| `takeMaxAge` | **1 s** (tested) | B6a's stale-price option is the main economic risk. The keeper posts every 20 s, so at 1 s only a taker that attaches reports fills (+133k gas, B10). The only taker is our own (no outside integrators), and it holds Data Streams credentials. | 30 s: fills on the keeper's reports, no credentials needed; makers carry a 20–30 s stale option, which a depeg widens. |
| Tick | **1e12** (0.000001 USDC per EURC, ~0.01 bp) | Finer than any useful quote; the walk's cost does not depend on it. | 1e13 if quotes should be coarser. |
| Lot | **1e15** (1 EURC) | One contract is 1,000 EURC; a lot of 1 EURC lets small takes fill. | 1e17 (100 EURC) for fewer, larger fills. |
| `maxTtl` | **1 h** | A maker that stops updating stops quoting within the hour. | 10 min, tighter, but the maker must reprice at least that often. |
| Makers per market | **3** | Makers are allowlisted, so the cap bounds gas (B10: 1 maker 1.13M, about +0.61M each; 3 makers about 2.4M), not spam. Raised by the vault when a second maker exists. | 10 (tested; 6.6M gas worst case). |
| Gas floor | **700,000** (tested) | Above a measured settlement batch (~600k) with margin; the out-of-gas revert (B5a) covers what the floor misses. | — |
| Priority tax | **off** (B12) | The script refuses anything else at rollout. | — |
| Taker fee | **the registry's, today 5 bps** | Not chosen here: the proposer refuses an enable whose fee differs from `/markets`. | — |
| DEX-skew policy (B6) | **Maker-side: widen the half-spread when the Aerodrome pool is thin or the EURC dexprice stream diverges from the push feed; stop quoting past a set divergence.** No contract change. | The index is a DEX-weighted stream; the book cannot tell a skew from a move. | Quote only in deep-liquidity hours (a schedule in the maker). |
| Rehearsal | **Mainnet canary**, as Stage 1 (A1.4): deploy closed, enable with our maker quoting one small curve, take against it from a throwaway account, then raise size. | The 2026-11-15 precedent; Sepolia lacks the verifier and the live engine. | Base Sepolia with a short-dated series (B12 as written; ~3 h). |
| Licence | **Owner to confirm** | `LICENSE` names Numo Foundation as licensor, Additional Use Grant: none, Change Date 2029-03-20 for code from 2025-02-17 (GPL-3.0-or-later after). Whether the upstream Lyra/Derive v2 BUSL permits Numo's production use is outside this repo. | — |

## B15. Implementation record (Stage 2 started 2026-11-15)

`src/periphery/OnchainBook.sol`. **Deployed closed on Base 2026-11-16** at `0x8Fc63DcB3a173aAF5d2de0F42648D908A519d456`
(block 58,358,413, `ac3e4b1`, single-use deployer `0xd58a…b0b2`; `deployments/8453/ONCHAIN_BOOK.json`): tick 1e12, lot
1e15, taker fee 5 bps, `takeMaxAge` 1 s, ttl cap 1 h, 3 makers, gas floor 700,000, tax off, maker owner the market maker
`0x3448…B47B`. Setup and enable batches landed (enabled 22:27 UTC); the book-maker quotes from #56 on ECS; the matcher indexes the
book. **Canary takes passed 22:44–22:45 UTC**: 5 EURC bought at 1.100656 and sold at 1.100036 from #57, both accounts
flat, fees exact to cash interest, both fills on `/trades` (scripts/ops/OPS_BOX_CHANGES.md). Go-ahead from the owner the same day, on
the B14a defaults; the licence row was put to the owner with the deploy and not separately answered.

**Built as specified:** maker curves (up to 10 regions a side) per owner, splines keyed by (market, account), mid
`index + offset - skew`, skew from the position at the start of the take and clamped, per-side refill cursors reset on
update, `seq` strictly increasing, best bid below best ask, ttl capped per market, maker allowlist and makers-per-market
cap, taker pre-check (`TakerAllowanceTooLow`), maker pre-checks (allowance: deactivate; live auction: skip), one
`try/catch` per maker, gas floor, `poke`, `takeMaxAge` freshness on the adapter's two stored reports, reports posted
before any transfer, `maxFee` covering fee and priority tax, `minFill` on the total, priority then registration order.

**Departures, for review:**
1. A maker skipped on a caught revert has its size re-planned to the others in the same take (B5a).
2. One transfer per maker at its average price; the band is enforced per level by the walk (B5).
3. `DecrementTake` cancels the crossing level and excludes the taker's own maker for the rest of the take.
4. The priority-fee tax is charged as its own cash transfer from the taker, after the makers.

**Defects found by the tests and fixed before commit:**
- A maker could register an account under a manager it controls; the walk calls that manager on every take, so one
  revert there froze the market. Now the market's engine is fixed at `createMarket` and required at `registerMaker`.
- A batch out of gas was caught and skipped like a margin failure. Now it reverts the take (B5a).

**Independent review (2026-11-16).** A fresh session given only the code and this spec found no critical or high
issue and no path to move an account that did not agree to the trade. Fixed, each with the reviewer's reproduction
turned into a test that goes red when the fix is removed:
- *Medium.* An ask below the band (or a bid above it) ended the walk, so one maker's out-of-band quote closed that
  side for everyone. Now a level short of the near edge is skipped for the take; past the far edge the walk stops.
- *Medium.* Out of gas below `submitTransfers`' own frame (the manager hook, a `managerData` receiver) surfaces as a
  revert with no data, which was caught and skipped, so the taker's gas limit still chose which makers fill (B5a). An
  empty revert reason now reverts the take (`OB_BatchOutOfGas`); every real failure on the path carries a selector.
- *Low.* The maker allowance pre-check now adds subId and asset allowances as `SubAccounts` does (checked): a sum that
  overflows there covered the fill here, and the maker was skipped forever instead of switched off.
- *Low.* A spline records the owner that wrote it; after the account changes hands it stops quoting, and the new
  owner quotes only through its own update, which the allowlist gates.
- *Low.* `setPriorityTaxRate` is capped (`MAX_PRIORITY_TAX_RATE`, 10 USDC a take at a 1 gwei priority fee), and a take
  that fills nothing pays no tax.
- *Low.* `createMarket` requires the adapter behind the future's index (`EurcIndexFeed.adapter()`).
- Removed the unused `MakerRegistered` event.

**Second review (2026-11-16, of the fixes).** No critical or high issue; each fix judged correct. Three follow-ups,
fixed and tested the same way:
- *Medium.* Treating every empty revert as out of gas let one maker whose batch reverts empty for another reason (a
  feed with no code, a return too short to decode, in its margin check) freeze the side. Now an empty revert reverts
  the take only when the batch also used at least 9/10 of the gas it was given; otherwise the maker is skipped.
- *Low.* Levels dropped short of the band's near edge counted against `maxLevels`, so a maker's unfillable levels
  could use up a small limit. Now only filled and `DecrementTake`-cancelled levels count; drops are bounded by
  `MAX_REGIONS` per maker.
- *Low.* The adapter check ran only at `createMarket`. The future's index can be rotated later (timelocked), so `_peg`
  now quotes nothing once the index reads another adapter (about +2,000 gas a take); a market on the new adapter
  replaces it.

Informational, not changed: a spline stopped by an account transfer is not deactivated, so it quotes again if the
account returns to its writer within the ttl (harm to that owner only); `setMakerAllowed(owner, false)` does not stop
live splines, which lapse at their ttl (at most `maxTtl`). The reviewer's note that `owner` packs into the spline's
second slot is wrong: the fields before it fill 33 bytes, so it takes a third slot on first write (B10), about 20k gas
once per maker and market; warm updates are unchanged.

Accepted, not changed: `setCurve` can bring a live spline's best bid level with its best ask when the half-spread is 0
(harm to the maker only); a re-plan round (departure 1) reloads makers, so their skew is recomputed from round-one
positions and a maker can settle twice in one take; a maker with a finite allowance can be switched off by a large
take (the runbook requires max allowances, and book-maker's preflight refuses less than 2^128).

**Tests:** 63 unit tests (12 from the two reviews) (real `SubAccounts`, `MarginEngine` v2, `FutureAsset` v3, `StreamsIndexAdapter`,
`EurcIndexFeed`; the verifier, auction and cash mocked), 4 invariants over random takes, updates, price moves and
pokes, and 6 fork tests on the live stack in which Chainlink's verifier checks real reports inside the take and a
flipped signature bit is refused (`0x4df18f07`). 48 guards (36, then 7 and 5 from the two reviews) were each removed and seen to turn a test red.

**Parameters used in tests, awaiting decision (B14):** tick 0.000001, lot 1 EURC (0.001 contract), `takeMaxAge`
1 s, ttl cap 1 h, taker fee 5 bps (the `Matching` path's), tax off, gas floor 700,000, makers per market 10.

**Before the 2026-11-24 go/no-go:** the parameter and DEX-skew decisions and the licence (B14); the targeted
independent review (A1.2); the Base Sepolia rehearsal with a short-dated series; a deploy script and vault batch;
off-chain, a curve-quoting mode in the market maker, maker subaccounts outside `Matching`, and indexing `Fill` and
`TakeExecuted`.

Indexing is built (2026-11-16, markets-service, README "OnchainBook fills"): the matcher writes each `Fill` onto the
series' tape (`trade_fills`, source `book`, at block time) and each `TakeExecuted` to `book_takes`, refusing a range
whose fills do not add up to their take. It waits on the deploy for `ONCHAIN_BOOK_ADDRESS` and its start block.

**End-to-end on a fork of Base (2026-11-16, block 58,347,197, chain time stepped 1 s a block).** Every Stage 2 piece in
one run, against the live v3 stack:
- `deploy-onchain-book.s.sol` deployed the book (`TAKE_MAX_AGE=60` for the fork); the setup and enable batches landed as
  the vault; the proposer read them as landed, parity 22/22.
- The book-maker set its curve, registered account 56 and quoted at +555 ticks.
- Account 57 took three times: bought 150 lots at 1.100823, sold 300 through both curve regions at 1.1006063, and sent
  a buy limited below the ask, which filled nothing.
- markets-service's indexer, with the production EURC-30NOV26 listing, wrote both fills to the tape (150 and 300 EURC,
  block-time, 5 bps fees) and all three takes; a second pass wrote nothing.
- The fees matched the fee account's credits net of cash interest.
- Unplanned: mining 25 blocks staled the index, and the book-maker cancelled (`index_unreadable`); at SIGTERM it left
  the cancelled spline alone.

Not covered: Base Sepolia, and the book under a live keeper's report cadence, where `takeMaxAge` is 1 s.

# Part C: Stage 3, a composable venue (design direction, 2026-11-17)

Not built. Direction agreed with the owner on 2026-11-17; scope and the decisions in C6 come before any code.

## C0. Goal and test

The futures exchange should be **composable on chain with lending and spot markets**: another contract (a lending
protocol, a vault, a DEX aggregator, a basis-trade product) can open, close and hedge futures positions in the same
transaction as its own logic, using all of the venue's liquidity, with no off-chain party in the path.

The test, for each item below: **a contract with no off-chain component can do it in one transaction.**

1. Price a trade (a view: size → fill, average price, fee) and execute it, getting the result back.
2. Open, increase, reduce and close a position, with collateral in and out.
3. Reach all of the venue's liquidity, not a side venue's.
4. Read the account's margin and mark, to decide or to liquidate.
5. Hold the position (or a claim on it) as a transferable, priceable asset a lending market can accept.

## C1. Benchmark: Phoenix (Solana)

Phoenix (docs.phoenix.trade, read 2026-11-17) is composable because everything is one on-chain program:
- **One engine, all liquidity.** A FIFO book and makers' splines are merged into one book at match time; at equal
  prices splines fill first, but a worse spline price never skips a better resting order; splines never trade with
  each other.
- **Trading by cross-program call.** Their Rust SDK exposes CPI helpers for orders (market, limit, multi-limit,
  delegated, cancels), deposits and withdrawals, conditional orders and trader registration. Order calls return
  matching-engine data to the caller.
- **Readable risk.** A margin view (`hawkeye::ViewMargin`) is callable by other programs.
- **Self-priced splines.** A maker updates its own reference price ("spline oracle update", ~600 compute units),
  with sequence numbers against stale updates and region lifespans in slots. **A taker attaches nothing:** staleness is
  the maker's risk, managed by the maker's update rate and expiries.

Not stated in their docs: which parts are permissioned (deposits take an optional `permission_account`, onboarding
has invites) and how the external component of their mark price reaches the chain.

## C1a. Benchmark: Perpl (an EVM on-chain order book)

Perpl (docs.perpl.xyz/exchange/order-book, read 2026-11-17; the page does not name its chain) runs a limit-order book
entirely on chain on an EVM chain, so its costs compare directly with ours:
- **Structures.** A three-level bit-index tree of 256-bit words finds the next price up or down (more than 16M price
  levels); a two-level tree indexes order ids (more than 65k orders per contract); orders at a price sit in lists that
  share storage across nearby prices.
- **Cost.** Post O(1), cancel O(1), match O(n). A post-and-cancel is "100k gas, including solvency checks", against
  their figure of 200k for a Uniswap V2 swap. Tuned for makers, whose post-and-cancel cycle is the common operation.
- **Order types.** Limit, market, an expiry block on any resting order, and a change operation replacing
  cancel-and-post; changing only size or expiry does not move storage.
- **Stale orders.** An order with an expiry pays a recycling fee, refunded on full fill or the issuer's cancel; a
  taker who walks into an expired order keeps the fee for clearing it. Tunable at runtime.
- **One permissioned element.** A backend can cancel far-from-market orders when the book fills, against spam.
- Not stated: oracle use, a contract-callable interface, how margin and settlement work beyond "solvency checks".

## C2. Where Numo stands (2026-11-17)

| C0 test | Today | Why |
|---|---|---|
| 1. Price and execute | Partly: `take` returns `(filled, avgPrice)` | No quote view; only a simulated `take` prices a trade |
| 2. Positions and collateral | Yes, for an account the contract owns or operates | `CashAsset.deposit`/`withdraw`; `take` authorizes owner, operator or approved address |
| 3. All liquidity | **No** | Nearly all liquidity is on `Matching`: paired off chain by the matcher, executed by an allowlisted executor, accounts held by `Matching`. The book has one allowlisted maker, 60 EURC a side |
| 3a. With no off-chain party | **No**, even on the book | Splines quote only on reports at most `takeMaxAge` (1 s) old; the keeper posts every 20 s, so a taker must fetch and attach signed Data Streams reports (off-chain code and credentials) |
| 4. Read margin and mark | Yes | `getMargin`, `getMarginAndMarkToMarket`, `futureContracts` are views. The index reverts when its reports are over 60 s old |
| 5. Positions as collateral | **No** | Positions are SubAccounts balances, not tokens; an account is an ERC-721 no lender values |

Already on chain: execution, margin, variation margin and settlement on both paths (verified on fill #548, tx
`0x4ae42402…9385`).

## C3. The core choice: who carries staleness

Pegging quotes to the verified index (B6, B6a) protects makers from stale prices, but it moves the freshness
requirement onto every taker, which is what blocks C0 item 3a. Phoenix puts staleness on the maker.

**Direction: a maker chooses, per spline, between two modes.**
- **Pegged** (today, B7): `mid = index + offset − skew`, quoting only within `takeMaxAge` of the stored reports.
- **Self-priced** (new): `mid` is an absolute price the maker posts, quoting until `updatedAt + ttl`, with `seq`
  strictly increasing (both exist today). A taker attaches nothing. Per-market cap on a self-priced `ttl` (proposed
  60 s).

What stays in both modes:
- **Index band.** A fill outside `markIndexBand` is refused (A2.2). For self-priced takes the band reads the
  *stored* index, valid while it is at most `indexMaxAge` (60 s) old, which the keeper's 20 s cadence keeps. A band
  that cannot be read stops self-priced quoting, so the venue fails closed when the index is stale.
- Maker allowlist (until C4.5), per-maker caps, skew, refill, the engine's margin checks.

Costs and risks:
- **Update cost.** About 70k gas a transaction on mainnet (16,789 for the warm write, B10, plus base cost), about
  0.00000042 ETH with Base's L1 fee at 2026-11-16 prices: about 0.0073 ETH a day per maker updating every 5 s,
  about 0.036 updating every second.
- **Pick-off risk is the maker's,** as on any order book: a slow maker's quote can be taken at a stale price. The band
  bounds the damage; the ttl cap bounds how stale.
- **Off-market quotes.** A self-priced maker can post any mid inside the band. That is their loss, not the taker's or
  the venue's.

## C4. Work items

1. **Quote view. Built 2026-11-17, in source for the next book version (v1 at `0x8Fc6…d456` is not upgradeable).**
   `quote(TakeOrder) view returns (filled, avgPrice, fee, makers)`: what `take(o, "")` does if every settlement
   succeeds. The same walk (`_walk`), the same rounds (a maker whose allowance no longer covers its fill is left out
   and the take re-planned), the same fee and priority tax (at the call's gas price), the same reverts. It cannot see a
   settlement reverting on margin. `takerAccountId` 0 is a price quote with no account. `makers` sizes gas (~610k
   each, B10).
   - **Re-plan fidelity.** `take`'s second round reads the first round's settlements from storage (cursors,
     positions, so skew). A view cannot write them, so `Pass.pendingLots` carries them and `_loadMaker` adds them to
     consumption and position; in `take` it is always 0. Cost to `take`: ~4,060 gas (1 maker 1,133,667 vs 1,129,609;
     10 makers 6,623,580 vs 6,619,506; fork, block 57,985,892). Size 22,146 bytes.
   - **Tests** (`test/periphery/OnchainBookQuote.t.sol`, 8): quote equals take across makers and regions, through an
     allowance re-plan with and without skew, a 256-run fuzz (equal results or the same revert), no-account quotes,
     stale reports, every revert, the tax at the caller's gas price. Seven guards mutation-tested; the existing 68
     book tests unchanged; 1,715 risk-core tests pass.
2. **Self-priced splines** (C3). **Built 2026-11-17, in source for the next book version.**
   - **Mode.** `SplineUpdate.selfPriced`: `offsetTicks` is then the mid itself (positive, `OB_InvalidMid`), not an
     offset from the index. Stored as `Spline.selfPriced`, packed into the `owner` slot (no extra read per maker).
   - **Freshness.** A self-priced spline quotes until the earlier of its ttl and the market's `maxSelfPricedTtl`
     (`setSelfPricedTtlCap`, owner, at most `maxTtl`; default 0 = off; set it to 60 at listing, per C6). The cap is
     read at take time, so lowering it, to 0 included, stops quotes already posted. Pegged splines keep `takeMaxAge`.
   - **Fail closed.** Every fill stays inside the index band. If `getSpot()` reverts (reports over the index's 60 s)
     the walk plans nothing and the take fills 0 rather than reverting (v1 reverted); a rotated index stops every
     spline. A pegged spline is left out before its mid is computed on old reports (index + a negative offset would
     otherwise underflow and revert the take).
   - **ABI.** `markets(uint256)` and the `splines(uint256,uint256)` return bytes are v1's, so the indexer and the
     vault proposer decode both books the same way (`splines` now returns a 12-field `SplineView`, the same 12 words;
     `isSelfPriced` reads the mode; the 13-field auto getter was too deep for the legacy pipeline). `updateSplines`'
     selector changes (`0xdf20ee06` → `0x5c06631f`): the book-maker needs the v2 ABI when it moves (item 5).
   - **Cost.** take +~2,100 gas (1 maker 1,135,791 vs 1,133,667 after C4.1; 10 makers 6,625,717), mostly the `try`
     around `getSpot`; `updateSplines` +~700. Size 23,165 bytes (1,411 under the limit).
   - **Tests** (`test/periphery/OnchainBookSelfPriced.t.sol`, 15): its own mid; the index moving does not move it;
     quoting on reports too old for pegged; a pegged negative offset beside it; the unreadable index (fills 0, no
     revert); rotation; ttl expiry; lowering the cap and 0 = off; the band's far and near edges; registration order at
     equal prices across modes; update validation; the cap's owner and bound; mode switches and v1's getter layout;
     and a 256-run quote-equals-take fuzz over mid, report age (0–70 s) and modes. Twelve guards mutation-tested (one
     equivalent mutant, the catch setting the index to 0, replaced by the meaningful one: no `try`, as v1). The 76
     existing book tests unchanged; 1,729 risk-core tests pass.
3. **Router** (periphery). **Built 2026-11-17: `src/periphery/OnchainBookRouter.sol`, 4,035 bytes, ownerless and not
   upgradeable; deployed with the next book (it takes the book's address).** `route(Route)` → `(filled, avgPrice)`:
   deposit stable from the caller, take (reports attached), optionally reduce-only, withdraw to a recipient (default
   the caller). Each step is optional; any failure reverts the whole call.
   - **Who.** Only the account's owner calls it (`R_NotOwner`, an operator of the owner included); the take must be on
     the routed account (`R_WrongAccount`). The router is the owner's operator (`setApprovalForAll`). The book still
     needs its own permission on the account, as for any take (operator, or allowances on the future and cash).
   - **Withdrawal.** CashAsset pays out only to the owner (`CA_OnlyAccountOwner`, proven on the live cash), so the
     router holds the account for that step: owner → router → owner inside the call. Allowances are keyed by
     (account, owner) and survive; ERC721 clears a per-account `approve`, so withdrawals need `setApprovalForAll`
     (tested). A maker account's splines are inert only within the call.
   - **Reduce-only.** The take must oppose the position (`R_NotReducing`, flat included) and is cut to its size.
   - **Holds nothing.** Exactly the deposit is pulled and deposited; afterwards the router holds no tokens and no
     account (asserted on the fork).
   - **Gas.** Deposit + take (1 maker, reports attached) + withdraw: 1,364,329 on the live-stack fork, ~95k over the
     take alone (1,269,142).
   - **Tests.** 10 unit (`test/periphery/OnchainBookRouter.t.sol`) and 2 fork (the live cash refusing an operator;
     the full route against Chainlink's verifier). Nine guards mutation-tested.
4. **Integration kit. Built 2026-11-17.** Guide: `docs/onchain-book-integration.md`.
   - **Interface** `src/interfaces/IOnchainBook.sol`: take, quote, the market and spline reads, Fill/TakeExecuted/
     MakerSkipped, a take's errors. Selectors, event topics and error selectors asserted equal to the contract's, and a
     caller holding only the interface quotes and takes (`test/periphery/OnchainBookKit.t.sol`, 3). `markets` is
     declared as a 13-field `MarketView` struct return: the same bytes, but destructuring 13 values is too deep for the
     legacy pipeline (the router hit it too, and now reads through the interface).
   - **Example** `examples/DeltaHedgedEurcVault.sol`: one transaction flash-borrows USDC from Morpho Blue, buys EURC on
     Aerodrome Slipstream (EURC/USDC tick spacing 1, `0xc5E5…48c1`, the deepest at the fork block: ~37.8k USDC, 99k
     EURC), supplies it to Morpho as collateral, borrows the flash loan back, and shorts the same EURC on the book, all
     or nothing; `rehedge` restores delta after the collateral or position moves. Uses only the interface and minimal
     ABIs. The flash loan is useful only because the EURC becomes collateral to borrow against; a bare spot-plus-short
     has nothing to repay it with. Not audited, not deployed.
   - **Fork tests** (`test/fork/OnchainBookKitFork.t.sol`, 5) on the live stack: real Morpho Blue (a market created in
     the test: EURC collateral, USDC loan, the enabled adaptive IRM and 86% LLTV, a fixed oracle at the index; no
     existing market assumed), the real Aerodrome pool, the book on MarginEngine v2 and FutureAsset v3 with
     Chainlink-verified reports. `open`: 1,995.23 EURC bought and posted, 1,995 EURC shorted, delta 0.23 EURC (under a
     lot), no USDC or EURC idle, 3,276,751 gas. Rehedge after outside collateral; an unfillable hedge undoes the
     swap, collateral and loan; callbacks only from Morpho mid-open and from the pool. Seven guards mutation-tested.
   - `OnchainBookFork` was split into `OnchainBookForkBase` (the fixture) and the tests, so the kit reuses it.
5. **Open the maker set.** Raise the per-market cap with measured gas, or allow permissionless makers behind a bond.
   Pre-req for C0 item 3 to mean anything.
6. **Resting limit orders on the book** (B13: FIFO, O(1) post and cancel, merged with splines as Phoenix does).
   Then the matcher becomes optional: a maker or router onto the book, not the exchange. Gas is the constraint on
   Base, not compute. From Perpl (C1a):
   - **Settlement is the bottleneck, not the book.** Perpl posts and cancels for ~100k gas; our take is 1.13M, of
     which ~610k is each maker's settlement through `SubAccounts` and the engine's margin hook (B10). Perpl most likely
     keeps balances inside the book contract; ours stay in the shared margin accounts, which is what makes positions
     usable by lenders (C0 items 4 and 5) and is kept. **Measure first:** how much of the ~610k batching a take's
     fills into one margin check per account would save, before choosing book structures.
   - **Copy:** expiring orders with a recycling fee (takers clear stale orders, no keeper), and a change operation
     (no cancel-plus-post).
   - **Avoid:** an off-chain hand on the book. Spam limits in the contract instead: a minimum order size, a per-account
     order cap, the recycling fee itself.
7. **Maker vault** (ERC-4626). Pooled USDC running a self-priced spline. It deepens the book, and its share token is a
   lendable yield asset: the first link to lending markets.
8. **Tokenized positions** for lending (C0 item 5). A wrapper (ERC-20 for a long or short position, or a basis token:
   long spot EURC, short the future), with a price from margin and mark. After C4.7, so there is a liquid venue to
   price against.

## C5. Contract versions

`OnchainBook` is not upgradeable. C4.1–C4.2 are a new book version: deploy it closed, as Stage 2 was, list the next
series on it, and keep v1 running to EURC-30NOV26's expiry. C4.3–C4.4 are periphery and can follow either version.
Every contract change goes through the Stage 2 cycle: spec, tests with mutation checks, independent review, fork
rehearsal, vault batches, mainnet canary.

## C6. Decisions (approved by the owner 2026-11-17)

| Decision | Decided |
|---|---|
| First scope | C4.1–C4.4 (quote view, self-priced splines, router, kit), **plus our own maker's quoting moved from `Matching` onto the book in self-priced mode**: the fastest route to C0 test 3 |
| Self-priced `ttl` cap | 60 s per market. Our maker targets a ~10 s ttl at a 5 s update cadence |
| Pegged mode | Kept beside self-priced; a maker picks per spline |
| Priority-fee tax (B12) | Ships ready in the new version; **off while only our maker quotes, on when outside takers arrive** |
| Maker caps | **Two separate parameters:** the per-take cap on makers settled (gas, B10) and the per-market maker set (who may quote, C4.5) |
| Maker set (C4.5) | Raise the allowlist cap first; permissionless with a bond later |
| Matching path | Kept for now; becomes a maker or router once C4.6 exists |
| Lending (C4.7–C4.8) | After the venue is liquid |

**Before any C4 item ships** (self-priced quoting stops when the stored index is stale, C3, so the keeper becomes the
venue's liveness): a keeper funding alert, a backup keeper key, and an alert on the stored reports' age.

**C4.6 measurement, extended:** besides one margin check per account per take, measure a **hybrid**: one batch per take,
falling back to per-maker settlement when the batch reverts, so B5a's isolation of a failing maker still holds.

**Order of work:** hot-wallet top-ups (2026-11-17), then the EURC-30NOV26 expiry run-sheet, then C4.1 (quote view).

**Our maker onto the book, self-priced: the bot built 2026-11-17** (market-maker `f7049c62`, `docs/book-maker.md`).

- **What changed.**
  - `MM_BOOK_SELF_PRICED=true` sends the forward as the mid, `round(forward / tick)`, with a 10 s ttl. A 5 s poll
    and a 2 s refresh mean every cycle sends.
  - Startup refuses a configuration where `refresh + poll + 3 s` exceeds the ttl. It also refuses a v1 book, a
    `maxSelfPricedTtl` of 0, and a ttl over the cap.
  - The bot detects the book version through `maxSelfPricedTtl` (only a plain revert counts as v1, not an RPC
    error), so the same image keeps quoting the live v1 book pegged.
  - The index guards are unchanged.
- **Proof.**
  - Tests pin the v2 selectors and `updateSplines` calldata to `cast`, and v1's layout to the v2 reads.
  - Eleven guards were mutation-tested; one survivor was fixed by a stronger test.
- **Fork rehearsal against a v2 book** (block 58,635,311):
  - all five refusals fired;
  - a 30-lot take filled at the curve as `quote` predicted;
  - after `kill -9` the quote stopped filling at its 10 s ttl;
  - SIGTERM cancelled the spline;
  - a stale index cancelled it.
- **Cost.** 73,061 gas per refresh, 17,280 a day: about 0.0076 ETH a day plus the L1 fee. That is roughly 300
  times pegged mode's (at most ~100 updates a day at ~40k gas).
- **Left for the deploy (a separate go-ahead; prepared 2026-11-17 in `onchain-book-v2-runsheet.md`: the deploy script takes `EXPIRY` and sets the cap, the proposer takes `--version 2`, the matcher indexes both books):**
  - `deploy-onchain-book.s.sol` targets EURC_FUTURE_V3 and its vault batch has no `setSelfPricedTtlCap(id, 60)`
    yet;
  - the MM wallet (`0x3448…B47B`) holds 0.0004 ETH, under an hour of self-priced quoting, and its
    `check_signer_balance.py` floor (0.00005) assumes pegged;
  - the ECS env needs `MM_BOOK_SELF_PRICED`, the v2 book's address, and a market on a series that trades past
    30 Nov;
  - the `report-age` check watches the EURC v3 adapter, so a next series on a new adapter needs it repointed.
