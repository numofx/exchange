# EURC-USDC futures and on-chain matching

Status: **v3.5**, 2026-11-15. Supersedes v1 (written against `DatedFutureAsset` and `StandardManager`, which are not the
live contracts) and v2.x–v3.0 (reviewed in conversation, not committed).

- **Step 1** (build now): a new `FutureAsset` version with recovery fixing and no owner price, `StreamsIndexAdapter`,
  a staleness-only `EurcIndexFeed`, traded through the existing `Matching` path. Listing waits on the measurements in
  A6 and A7. Data Streams access is in place (A2.1).
- **Step 2** (`OnchainBook`, oracle-pegged maker curves): gated on a concrete taker, **except for the EURC-30NOV26
  pilot (A1.2)**, for which the gate is lifted.

The pilot ships in two stages (A1.2): Stage 1 lists the new series on `Matching` as soon as its mainnet canary
(A1.4) passes; Stage 2 adds `OnchainBook` to the same market behind its own gate. The market never waits for `OnchainBook`.

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
