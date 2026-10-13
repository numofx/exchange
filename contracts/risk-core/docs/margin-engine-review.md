# MarginEngine and the cNGN future: reviewer brief

Scope, design, invariants and evidence for the outside review of [#180](https://github.com/numofx/exchange/pull/180):
USDC/cNGN dated futures, **cash settled in cNGN**, margined in **one account with spot cNGN and the cNGN-PERP**, on
**MarginEngine**, a fork of Lyra v2's StandardManager.

## 1. What to review

| File | Lines | How to read it |
|---|---|---|
| `src/risk-managers/MarginEngine.sol` | 866 | **As a diff against Lyra's StandardManager at #361 (`12cb35a`)**: 453 changed lines. That covers Numo's carried changes and the fork's (see below). The contract header lists the fork's own changes. |
| `src/risk-managers/MarginEnginePortfolioViewer.sol` | 238 | As a diff against Lyra's `SRMPortfolioViewer.sol` at #361: 205 changed lines. They are the dated-future arrangement, type renames, futures excluded from `depegPenaltyPos`, and the `_checkAssetCap` override. |
| `src/risk-managers/MarginEngineOptionHelper.sol` | 228 | Against the option margin that Lyra's #361 StandardManager computes inline. `4480270` + `3063ff0` moved it into a helper; this copy renames only the struct types (31 lines against `OptionMarginHelper.sol`). |
| `src/libraries/FutureVMLib.sol` | 244 | **New, in full.** Futures VM settlement, futures margin, close-out. |
| `src/assets/FutureAsset.sol` | 524 | **New, in full.** The dated future: marks, VM accounting, fixing, settlement. |
| `src/interfaces/IMarginEngine.sol`, `IMarginEnginePortfolioViewer.sol`, `IFutureAsset.sol` | 234, 21, 114 | Interfaces. `IMarginEngine` against Lyra's `IStandardManager` at #361: 38 lines. |
| `src/risk-managers/BaseManager.sol` | 480 | As a diff against Lyra's at #361: Lyra #362 made it upgradeable, Numo `1e9f8fa` split `executeBid` and moved cash settlement into `_applyCashDelta` (see below). The engine inherits it. |
| `src/risk-managers/BasePortfolioViewer.sol` | 1 word | `_checkAssetCap` made `virtual`. No behaviour change for existing managers. |
| `scripts/deploy-margin-engine.s.sol` | 585 | The deployment, its postconditions, and the two vault batches it writes. |

### Scope: against Lyra's #361, including Numo's earlier SRM changes (decided)

The baseline is Lyra's StandardManager at #361 (`12cb35a`), the last Lyra commit before Numo's changes, not today's. The live perp SRM carries Numo
changes made after the import, the fork inherits them, and **they are in scope**:

| Commit | What it changed | Diff |
|---|---|---|
| `0d81da6` | The `DatedFuture` asset type: margin hook, settle-before-risk-check, viewer arrangement. The commit message reads "add SquaredPerpAsset"; the change is in the same commit. **The fork reworks this path**, replacing the USDC-settled `DatedFutureAsset` with the cNGN-settled `FutureAsset`. | +218 −75 across the manager, viewer and interface |
| `4480270` + `3063ff0` | Option margin moved out of StandardManager into `OptionMarginHelper`, to fit the contract size limit. Options are retained in the fork, unlisted. | the helper added; 309 lines out of the manager |

`1e9f8fa` (deliverable-FX wiring) and `8166d52` (its removal) leave no deliverable code in the manager, viewer or
interface. **They do not net to zero:** `1e9f8fa` also changed `BaseManager`, and `8166d52` did not revert that (see
below).

**Also in scope:** `FutureVMLib` in full, and `FutureAsset` in full.

Reviewing against #361 also reviews the live SRM's own Numo changes, since it runs the same code at `0d81da6` and
`3063ff0`.

### Also changed since #361 on the engine's path

Every file under `src/` that changed between #361 and the import, and that the engine runs, was checked:

| File | Since #361 | Verdict |
|---|---|---|
| `DutchAuction`, `CashAsset`, `WrappedERC20Asset`, `Allowances`, `ISubAccounts`, `BaseLyraFeed` | `95a0eb5` (forge fmt) | identical to #361 with whitespace removed |
| `PerpAsset` | `0d81da6`: six functions made `virtual`, for `SquaredPerpAsset` | no behaviour change |
| **`BaseManager`**, which the engine inherits | see below | **in scope** (decided) |

`BaseManager` is in scope: the engine's pool guard depends on Numo's `_executeBid` split, and a reorder of cash steps
is exactly what a review should see. Its diff against #361 has two sources:
- **Lyra #362 (`57cdd00`, PMRM2):** made upgradeable. Immutables became storage, `Ownable2Step` became
  `Ownable2StepUpgradeable`, and a storage gap was added.
- **Numo `1e9f8fa`:**
  - `executeBid` was made `virtual`, with its body moved into an internal `_executeBid`. The engine's `executeBid`
    override depends on this.
  - Cash settlement moved into `_applyCashDelta`. This reorders option settlement: `updateSettledCash` now runs before
    `managerAdjustment` rather than after.

Reproduce it with `git show 12cb35a:src/risk-managers/BaseManager.sol` against
`contracts/risk-core/src/risk-managers/BaseManager.sol`. The commits themselves are `git show 57cdd00 1e9f8fa --
src/risk-managers/BaseManager.sol`.

### Check before reviewing: how the engine gets its owner

**The question:** since #362, `BaseManager` uses `Ownable2StepUpgradeable` and storage where it had immutables. The
engine is deployed directly, not behind a proxy. How does it get its owner, and is any initializer left open for
someone else to call first after deployment?

**Our answer:**
- **The owner comes from the constructor.** It calls `_transferOwnership(msg.sender)` and sets `subAccounts`,
  `cashAsset`, `liquidation`, `viewer` and `accId`.
- **The only later writer of those fields** is the owner-only `setLiquidation`.
- **No initializer is exposed.** The engine inherits `Initializable` only through `Ownable2StepUpgradeable`, which has
  no external initializer. `BaseManagerUpgradeable`'s initializer is `internal onlyInitializing`, behind
  `_disableInitializers()`, and the engine does not inherit it.
- **The engine's external interface** carries no `initialize`. Its only ownership functions are OZ's: `owner`,
  `pendingOwner`, `transferOwnership`, `acceptOwnership` and `renounceOwnership`. Note `renounceOwnership`: the vault
  could leave the engine ownerless, as on the SRM.
- **The sequence:** straight after deploy the deployer owns the engine and the vault is nominated. The vault becomes
  owner when the setup batch's `acceptOwnership` lands.

**Pinned by** `MarginEngineDeployFork.testTheEngineIsOwnedFromItsConstructorAndNothingCanInitializeIt`:
- after deploy: owner is the deployer, the vault is nominated, and the constructor's wiring is set;
- a stranger can't call any initializer shape, accept or transfer ownership, or `setLiquidation`;
- after the batch: the vault owns it, nothing is pending, and the wiring is unchanged.

A planted open `initialize(address)` fails it.

**The deployer's window.** Between deploy and the vault's `acceptOwnership`, the deployer key owns the engine, viewer,
future and forward feed, and could change any setting. Two measures close it:
- **A single-use deployer key.** The deploy script refuses a key that has sent a transaction before. Forge's deploy
  of the linked `FutureVMLib` is the key's first transaction, so the script allows nonce 1 and nothing more. It
  records the address in `MARGIN_ENGINE.json` as `deployer`, and its nonce at the end of the deploy as
  `deployerNonce`. Retire the key once the vault has accepted.
- **Parity re-checked after the vault accepts.** `propose_margin_engine_batch.py` re-reads every setting the deploy made
  once the setup batch has landed, and again as an enable gate, so a change in the window is caught before enable:
  - market 1 on the engine against market 1 on the live SRM, as the deploy's `assertParity` does, including the four
    copied callees (read from storage, slot 12);
  - the futures margin, `FutureAsset`'s mark and fixing settings, the forward feed's signer, quorum and heartbeat, and
    the engine's wiring, against the values the deploy recorded in the artifact;
  - that the deployer holds nothing: not an owner, not a nominee, not a forward signer;
  - that the deployer has sent no transaction since the deploy: its nonce still equals `deployerNonce`. This catches
    anything sent in the window, including changes to settings parity does not read.

  The fork rehearsal breaks both measures:
  - a deployer key that has sent one transaction is refused;
  - the deployer halves the futures MM before the vault accepts, the batch lands, and parity goes red naming
    `futureMarginRequirements mm`.

  A clean deploy passes.

**Please confirm this before reviewing the rest.**

Files changed since #361 that the engine does not run: PMRM2 and its libraries, the deliverable-FX manager and asset,
`SquaredPerp*`, the Chainlink feeds, `SpotPassthroughDiffFeed`, `LyraRateFeedStatic` and `DatedFutureAsset`.

To reproduce the diffs:

```sh
git show 12cb35a:src/risk-managers/StandardManager.sol    > /tmp/lyra-StandardManager.sol
git show 12cb35a:src/risk-managers/SRMPortfolioViewer.sol > /tmp/lyra-SRMPortfolioViewer.sol
diff -u /tmp/lyra-StandardManager.sol    contracts/risk-core/src/risk-managers/MarginEngine.sol
diff -u /tmp/lyra-SRMPortfolioViewer.sol contracts/risk-core/src/risk-managers/MarginEnginePortfolioViewer.sol
git show 0d81da6 -- src/risk-managers/StandardManager.sol src/risk-managers/SRMPortfolioViewer.sol src/interfaces/IStandardManager.sol
git show 4480270 3063ff0
```

The Numo commits live in the imported history, under paths without `contracts/risk-core/`.

The parity evidence: StandardManager's suite passes 141/141 on the engine, and on a Base fork the same portfolio has
identical margin under the live SRM and the engine. That shows the fork preserved the carried behaviour. It does not
show the carried behaviour is right; reviewing it is.

### Out of scope

- The keeper (`services/perp-feeds`).
- The matcher (`services/markets`).
- Ops scripts and infra.

These are in the PR and tested, but they hold no funds.

## 2. Context

- **Lyra v2 accounts.** Each `SubAccounts` account has **exactly one manager**, and this `SubAccounts` has **no
  `changeManager`**. A position moves to a new manager only by being closed and reopened, or transferred to an
  account under it.
- **The live venue** (Base) runs spot cNGN-USDC and the cNGN-PERP **in one account under the perp SRM**. Both
  markets' `margin_manager_address` is the SRM, and spot's asset is the perp's cNGN escrow.
- **MarginEngine deploys beside the SRM** and reuses these live contracts:

| | Address |
|---|---|
| SubAccounts | `0x7019244E25FA416e6Ca2ed2F3cA25277aef72843` |
| Perp SRM (live, read only) | `0xDE0423D0a1E15536265C9513d2e0c10DAb5835D4` |
| cNGN-PERP | `0xC74EfC8B4808803dBCF439E76Fde076d56625b8E` |
| USDC cash | `0xA74E49b4Ed7cb176bc02ef4D8a1A3240C9aD4272` |
| cNGN escrow (spot, collateral, VM) | `0x37c976bb5d4887a714ef19AF6B83e34fe2f37c98` |
| Index feed (USDC per cNGN) | `0xFaC420d160C7c219A72DC676971670980bAC20a5` |
| DutchAuction | `0xd07176B006cE8246e930d37b8bc44B1154f8c4cE` |
| SecurityModule | `0x92A6F2f5EE253Db67a5980864195b7BC5A586530` |
| Vault (owner) | `0x1dcA42ab54Bd3862853A821F84B29BF65245F435` |

- **The cutover** (in #180) is forced by date, with no migration code:
  1. The engine opens.
  2. Markets-service points new accounts and orders at it.
  3. The old SRM's perp cap is set to its live open interest, so it is close-only, never below.
  4. Owners close on the SRM and reopen on the engine.

## 3. Design

### FutureAsset

- **Units:**
  - Contract size: USDC (1,000).
  - Prices: cNGN per USDC.
  - VM: cNGN per contract, `Δmark × contractSize`.
  - The index and forward feeds are USDC per cNGN; the asset inverts them.
- **Marks:** `pullMark` is permissionless and rate-limited by `minMarkInterval` (1h). It reads a signed `LyraForwardFeed`
  (forward = index + a signed per-expiry difference). Each mark is held to:
  - a per-mark move limit (5%);
  - an index band, 10% that narrows linearly to 1% over the last 14 days.

  The owner can `setMark` as a fallback.
- **Fills** carry their price in `assetData`. VM is blended at the fill price, so a fill away from the mark realises the
  difference at once.
- **The fill bound:** a fill must be priced inside the band a mark must sit in, `markIndexBand` around the index now
  (10%, narrowing to 1% at expiry); otherwise it reverts `FA_FillOutsideIndexBand`.
  - It is measured against the index, not the last mark, so fills at a market that has moved are taken while marks catch
    up.
  - Transfers with no price (liquidation, close-out) move at the mark and are not bounded.
  - **Residual:** a colluding pair can still move up to one band's width of value per contract at a maintenance-margin
    check, through a reduction.
  - **markets-service enforces the same bound before matching**, so out-of-band orders are refused instead of reverting
    at settlement (§8). **The enable batch refuses to open the market until `/v1/markets` reports that band and it
    matches the chain** (the proposer's `fills` gate, below).
  - **A stale index on a fill** reverts inside `FutureAsset.handleAdjustment`, before the margin check, with the index
    feed's own `BLF_DataTooOld()`, the same error as every other path that reads a stale index (proved on a Base fork).
- **Last trade:** trading closes at `lastTradeTime`. After that, only the manager moves positions: liquidations and
  close-out.
- **Settlement:**
  1. `recordFixingSample` is permissionless, over the last hour, with a 15-minute gap limit.
  2. `fixSettlementFromIndex` sets the price to the time-weighted index.
  3. If the fixing is incomplete, the vault's `setSettlementPrice` is allowed only after a 24h delay, and only within
     2% of the samples' TWAP (or of the last index read).
- **Who settles:** `settleAccountVM` may be called only by the account's own manager.

### MarginEngine: the fork's changes

1. **The dated-future type is the cNGN-settled `FutureAsset`.**
   - VM moves as the market's base asset (wrapped cNGN) through the engine's pool account `accId`.
   - A payer pays from its held cNGN first, then the rest as cash at the index (the settlement price at close-out).
   - The pool pays a winner in cNGN while it has it, then in cash.
   - Base cannot go negative, so **settlement never reverts on a shortfall**. Cash may go negative; the live SRM has
     `borrowingEnabled`, and the engine copies it.
2. **Views count unsettled VM, as StandardManager counts unrealised perp PnL.** It is valued as settlement will pay it:
   - **A loss** is paid from the account's held cNGN first, which costs it only the base factor (held cNGN was counted
     at it), then the rest at par.
   - **A gain** counts at the base factor, whatever the pool holds. That is the least settlement can pay it: the pool
     pays in cNGN (worth the factor) while it has it, then in cash at par. Valuing a gain by what the pool could pay
     instead would credit cash at par while the pool is short, and a treasury top-up in cNGN would then switch it to
     cNGN at the factor, lowering other accounts' margin. Ignoring the pool's balance keeps a top-up from ever doing
     that.
   - So **margin before settlement equals margin after** for losses, whatever order the series settle in: across
     losing series the cNGN spent is min(total owed, held).
   - With a gain, the view is at most what settlement gives, in any order. That covers a gain while the pool is short
     (paid in cash at par), and a gain that settles before a loss and funds it in cNGN. It cannot be exact: the pool is
     shared, and which winner receives cNGN depends on who settles first.
3. **Where VM is realised:**
   - before every risk check (`handleAdjustment`, including a position the adjustment itself closed);
   - by the auction, through `settlePerpsWithIndex`, before it prices or takes a bid;
   - by anyone, through `settleAccount`;
   - at expiry, through `closeOutExpired`, at the settlement price.
4. **A trade that only reduces futures is held to maintenance margin**, so an account can always deleverage. The
   flag passes through `_assessRisk`.
5. **Futures margin is gross:** |position| × contractSize × requirement. In v1 there are no offsets between perp and
   future positions.
6. **Depeg IM penalty** on the futures' own USDC notional. Numo's earlier dated-future code added raw contract counts
   to `depegPenaltyPos`, which is priced at spot.
7. **Cap check fix** (`MarginEnginePortfolioViewer._checkAssetCap`): an asset the trade did not touch is skipped.
   - The base viewer checks every asset an account holds. An untouched asset has no snapshot, so its pre-trade OI reads
     as 0.
   - So under the SRM, a cap below open interest makes every deposit, withdrawal and spot trade by a holder revert
     `BM_AssetCapExceeded`. This was reproduced on a Base fork: a 1 USDC deposit into a perp holder reverted.
   - With the fix, a cap below open interest means close-only.
8. **The pool `accId` is exempt** (after the review's High finding).
   - In `handleAdjustment` it returns right after `_preAdjustmentHooks`. So the guardian pause and the asset caps still
     apply, but there is no live-auction check, no VM settlement and no risk check.
   - The views report its margin as 0, so it can never be auctioned. Its mark-to-market still reports the deficit.
   - Without this, a negative pool failed its own margin check on the liquidation fee that passes through it to the
     SecurityModule's account, under another manager. Every solvent liquidation then reverted, and anyone could start an
     auction on the pool itself.
   - The exemption is safe because nothing but the engine moves the pool. Leaving it needs the engine's allowance, and
     `FutureAsset` and `PerpAsset` need an allowance for any adjustment, so no position can be pushed in.
   - **`withdrawFromPool` is therefore unchecked:** owner only, and gated in `propose_margin_engine_batch.py
     pool-withdraw`. A cNGN withdrawal must leave the reserve target (0 at launch); a cash one must leave zero cash.
9. **New functions:**
   - `settleAccount(uint)`;
   - `closeOutExpired(uint, uint96)`, which finds the series by subId on each market's future;
   - `withdrawFromPool` (owner);
   - `executeBid` refuses the pool as bidder (`ME_PoolCannotBid`; the auction already requires the bidder's owner to
     be the caller).

### Why a library, and how it runs

The engine is **24,142 of 24,576 bytes**; StandardManager had 1,174 bytes of headroom. `FutureVMLib` is an
**external library, delegatecalled**:

- It runs as the engine, so `SubAccounts.managerAdjustment` and `FutureAsset.settleAccountVM` accept it.
- It reads the engine's own state back through its public getters (`assetDetails`, `assetMap`, `getMarketFeeds`,
  `lastMarketId`) via `IMarginEngine(address(this))`.
- These are external **view** calls from inside a delegatecall, often while a `nonReentrant` entry point is active.

## 4. Invariants to check

1. **Parity:** for any portfolio of spot cNGN, cash and perp, the engine's IM, MM and mark-to-market equal
   StandardManager's.
2. **VM conservation:** VM only moves cNGN and cash between accounts and the pool. Summed over all accounts and the
   pool, cNGN changes only by deposits and withdrawals.
3. **Settlement never reverts on a shortfall**, and **rounding never favours a trader**. A trader's cash remainder
   rounds up when paying; the pool's rounds down.
4. **Settlement invariance:** margin before `settleAccount` equals margin after for losses, in any series order. With
   gains it is ≤ (the pool is short, or a gain funds a loss in settlement).
5. **Close-out depends on no live feed:** any cash leg converts at the settlement price.
6. **The pool never holds positions, can never be liquidated, and never blocks a transfer the engine makes through
   it.** It is owned by the engine, which grants no allowances. `executeBid` refuses it as bidder. The views report its
   margin as 0. `handleAdjustment` does not risk-check it.
7. **Deleveraging is always possible:** a pure futures reduction passes at maintenance margin.
8. **A cap below open interest is close-only:** deposits, withdrawals and reductions still pass, and growth reverts.
9. **Only the account's manager settles its VM.** Only the owner sets parameters, and the settlement fallback is
   bounded and delayed.
10. **The deployment copies the live SRM's market-1 settings exactly** (`assertParity`), and **leaves the SRM
    untouched**.

## 5. Where to look hardest

- **The delegatecall library:** state read through `address(this)` getters mid-adjustment, reentrancy across
  `SubAccounts.managerAdjustment`, and whether any external call in a view path could be steered.
- **The old SRM stays load-bearing:** the SecurityModule's account 21 sits under the old SRM `0xDE04…`. The fee
  `startAuction` pays it goes through `_transferCash`'s cross-manager branch (`submitTransfer` into account 21), and
  the SecurityModule pays insolvencies with `submitTransfer` out of it. Both run the old SRM's `handleAdjustment`, so
  **pausing the old SRM stops every engine auction that charges a fee, and every insolvency payout**. The TradeModule's
  fee account, 22, is under it too, so a pause also stops every engine fill that pays a fee. It must stay deployed and
  unpaused, and keep its cash whitelisting, for as long as the engine is live. Fork tests pin all three.
- **The pool exemption:** any path where an account that is not the engine could adjust `accId`, or where skipping its
  live-auction or risk check matters.
- **The fill bound:** reading the index in `FutureAsset.handleAdjustment` on every priced fill (a stale index reverts
  the fill, as the margin check would), and its interaction with `lastTradeTime`.
- **The auction:** `startAuction` and `bid` settle the liquidated account first. `executeBid` does not settle the
  bidder: its VM on what it takes accrues in `FutureAsset` and is counted by the views. Insolvent auctions draw on the
  SecurityModule, whose account sits under the old SRM.
- **The shared CashAsset:** VM shortfalls make cash negative, the pool's included. Check interest, the SecurityModule
  fee, and `totalBorrow`.
- **The cap override:** is there any path where an asset is touched in a trade without taking a snapshot?
- **Fill-price blending, last-trade closure, and manager-only moves after it** (`FutureAsset.handleAdjustment`).
- **Feeds:** a stale index makes `getSpot` revert, so margin views revert, and so do trading and liquidation. Close-out
  uses the settlement price. Futures carry no oracle-contingency penalty.
- **`maxAccountSize` (48)** with spot, perp and futures in one account.
- **Options:** unchanged code, never run on this venue. Their margin now shares an account with futures VM.

## 6. Launch parameters

| | Value | Source |
|---|---|---|
| Perp IM / MM | 33.333% / 20% | copied from the SRM |
| cNGN base factor / IM scale | 0.5 / 1.0 | copied |
| Oracle contingency | 0.55 / 0.55 / 0.55, factor 1.0 | copied |
| Depeg | threshold 0.99, factor 2 | copied |
| Futures IM / MM | 25% / 15% | deploy script |
| Futures OI cap | 30 contracts (15 a side, $15k) | sized so the SecurityModule's $3,250 covers a 25% step (~$2,947 with the perp) **at today's open interest**. Coverage is checked at enable (the proposer's `sm` gate) and watched afterwards by the pager's `sm-coverage`, which counts the perp and the future together |
| Perp OI cap on the engine | 0 at enable (**decided** 2026-10-13); the SRM's 50M is in the enable artifact, deferred to the perp's cutover | deploy script; propose_margin_engine_batch DEFERRED |
| cNGN escrow cap on the engine | 100M (**decided**) | spot and perp collateral (50M) plus futures (50M) |
| Pool reserve | **none at launch** (decided 2026-10-13; was 30% of one side at the cap, ~6.1M cNGN) | launch traders margin in USDC, so a seed would drain to winners and be refilled in USDC within a few marks; it changes neither settlement nor margin. Winners are paid in USDC once the pool holds no cNGN; the pager pages a pool deficit past $250 or outlasting a mark and its sweep (75 min) |
| Marks | 1h pull interval; 5% move limit; 10% → 1% band over 14 days; 2h forward heartbeat | deploy script |
| Fixing | 1h window, 15-minute gap limit, fallback after 24h within 2% | deploy script |

## 7. Evidence

| | Command | Result |
|---|---|---|
| StandardManager's suite on the engine | `forge test --match-path "test/risk-managers/unit-tests/MarginEngine/*"` | 141/141, the same as on StandardManager |
| Futures suite (FutureManager's 65, ported) and engine tests | same path, `TestMarginEngine_Future` | 87: cross-margin, the depeg, close-only cap, reduction between MM and IM, settlement invariance (including series out of order and gain/loss in both orders), the negative pool, and the fill bound |
| Fork tests (Base, real contracts) | `BASE_RPC_URL=… forge test --match-contract MarginEngineDeployFork` | 26 |
| Real fills, through the live Matching and cNGN TradeModule (**an enable requirement**, below) | `BASE_RPC_URL=… forge test --match-contract MarginEngineTradeModuleFork` | 7 |
| Fork rehearsal (keeper process, vault batches through the proposer) | `pnpm rehearse:future` in `services/perp-feeds` | passes |
| Full CI equivalent | `./scripts/verify.sh` | risk-core 1,367, execution 261, markets 517 (database-backed, none skipped), perp-feeds 126 |

`MarginEngineTradeModuleFork` signs orders as the matcher's clients sign them and matches them through
`Matching.verifyAndMatch`, on accounts under the engine:
- **the venue is closed until enable:** before the enable batch the future is unregistered, and a fill reverts;
- **a fill lands:** one contract each side, no quote leg, and both sides margined by the engine;
- **the fill price reaches the future:** a fill 1% above the mark moves the VM in the fill. Planting a `FutureAsset`
  that ignores the price fails this test;
- **the index band holds on the venue path:** a fill outside it reverts `FA_FillOutsideIndexBand`;
- **fees:** the taker fee lands in the TradeModule's fee account, which sits under the old SRM;
- **an under-margined order** is refused by the engine (`SRM_PortfolioBelowMargin`);
- **pausing the old SRM** stops every fill that pays a fee.

**It is an enable requirement.** It runs at head, so it must pass against the chain as it stands, at the commit to be
enabled, immediately before the enable batch is proposed. CI runs it on every change. Nothing on chain enforces this;
it is a step in the enable procedure.

**The market maker's futures model is an enable requirement too.** numofx/market-maker#35 quotes the future on its
own model, in place of the DFXM-era one:
- **notional is contracts × contract size (1,000 USDC)**, for its per-side cap, the inventory value and the signed
  `worstFee` (3e18 a contract);
- **sized by the engine's IM**, not cash: at most 80% of `getMargin(account, true)` over the IM a contract adds;
- **priced off the future's own index** (`MM_ANCHOR_SOURCE_TYPE=future_index_carry`, required), and kept inside the
  fill band;
- **no quoting near expiry:** off from an hour before the earlier of the fixing window and last trade, and no order
  signed to expire after that.

The requirement is met once #35 is merged and the bot runs it: an instance with
`MM_MARKET_SYMBOL=USDC-cNGN-<DDMONYY>`, `MM_ANCHOR_SOURCE_TYPE=future_index_carry` and an account under the engine,
quoting both sides. Nothing on chain enforces this; it is a step in the enable procedure. (Met 2026-10-13: account #32,
market-maker 8242a9d1574b, three bids and three asks inside the band.)

**A liquidation keeper for the engine is an enable requirement, and a gate.** The perp keeper watches accounts under the
perp SRM only, so until another runs, an engine account under maintenance is never auctioned. `numo-engine-keeper` is
services/perp-keeper with `MANAGER` the engine: DutchAuction settles each account through the engine before an auction
and every bid (its `settlePerpsWithIndex` realises the future's VM), so the keeper needs nothing engine-specific beyond
the address. The enable batch's `keeper` gate refuses unless it is live and out of DRY_RUN, reports the engine as its
manager, and funds bids from its own account under the engine holding no future or perp and the IM for one full side
of the future at the cap (cap / 2 × contract size × imReq: 3,750 USDC at launch). On a fork of Base, against the live
engine, it auctions an engine account the raised futures margin put under maintenance and buys into it from the engine
(`services/perp-keeper/scripts/e2e-engine.sh`).

The fork tests include:
- **margin parity on live contracts:** the same spot and perp portfolio under the SRM and under the engine has
  identical IM, MM and mark-to-market;
- spot, perp and future in one engine account;
- the live SRM untouched;
- the engine owned from its constructor, with no initializer to call;
- pausing the old SRM stops engine auctions and insolvency payouts (`testPausingTheOldSrm…`);
- liquidation through the real auction, and an insolvency paid by the real SecurityModule;
- a stale index during the fixing, then the bounded fallback;
- **the pool run negative:** a solvent liquidation still starts and its fee reaches the SecurityModule, with borrowing on
  and off; `startAuction(pool)` reverts; the treasury tops up a negative pool.

The fork rehearsal runs:
- one account holding spot cNGN, the perp and futures;
- the enable batch refused until the pager runs and the future is listed (no reserve: an empty pool passes);
- marks from the book and from carry, and the band narrowing;
- the payers-first sweep, and the startup sweep after a kill;
- the fixing across a keeper restart, close-out, and withdrawal of real cNGN;
- **a pager drill:**
  1. The pool is emptied of cNGN; with no reserve the proposer allows it, and the vault does it directly.
  2. It is drained past −$250 by winners settling before the loser.
  3. The real pager pages `future-pool-borrowing` to the stubbed phone.
  4. Its deficit timer backdated past 75 min, the next run pages `future-pool-deficit-stuck`.
  5. The pool is topped up, and both pages resolve.

**Mutations.** Each change below made a test fail:

| Area | Mutations |
|---|---|
| Unsettled VM | VM gain at par; VM not counted; losses all at par; held cNGN not spent across series; no held cNGN passed |
| Margin | no depeg; notional without contract size |
| Guards | cap fix off; pool may bid; reduction held to IM |
| Settlement | close-out at spot; the closed position's VM not settled |
| Pool | the risk-check exemption removed (caught with borrowing off); the never-liquidatable view removed; the withdrawal floor ignored |
| Fills | the bound removed |
| Deploy | a 1-wei mis-copy of perp IM (caught by the margin-parity test and by `assertParity`) |
| Matcher | close-only never refusing; manager not compared |

**One mutation survived, and is equivalent:** removing the close-only `continue` in the matcher, whose reduction check
already passes.

## 8. The futures listing

The vault proposer's `fills` gate holds the enable batch until markets-service serves this, and it must match the chain.
markets-service lists the future once `CNGN_FUTURE_*` is set on the API and the matcher (`services/markets/README.md`,
"cNGN future"):

- **The listing:** `GET /v1/markets` lists the future, by `asset_address` and `sub_id` (the expiry), with:
  - `fill_band_enforced: true`;
  - `fill_band_low` and `fill_band_high` (cNGN per USDC, decimal strings), withheld while the band cannot be read.
- **The band:** the index ∓ `markIndexBand(expiry)`, read from the chain and tested with `FutureAsset`'s own integer
  arithmetic (`internal/futures`). A test runs the gate's own `fills_gate` on the listing: it passes, and fails once the
  band is moved off the chain's.
- **Where it is enforced:**
  - the API refuses an order whose signed limit is outside the band now, from an account not under the engine, or after
    the last trade time;
  - the matcher re-checks every fill's on-chain price against a read at most 2 s old, so a resting order the index has
    moved away from is held back, not settled into a revert;
  - a stale or unreadable index refuses both.
- **Revert classes for the matcher:**
  - `FA_FillOutsideIndexBand` (`0x01bb8f43`) is balance-dependent. It is rare but possible: the index can move between the
    matcher's read and the block the fill lands in. The pair backs off and is retried against the next band.
  - `BLF_DataTooOld` (`0x1141796d`) is balance-dependent and transient: the index returns once the publisher resumes.
  - `FA_TradingClosed`, `FA_UnknownFuture`, `FA_InvalidSubId` and `MW_UnknownManager` are permanent for the pair.
- **Fees:** 25 bps taker, 0 maker, of contracts × 1,000 USDC, so 2.5 USDC a contract at any price. Signed `worstFee` must
  be at least `2.5e18`.

## 9. Known limitations

- **Not covered by any test:**
  - the matcher process itself (`MarginEngineTradeModuleFork` signs and submits orders as the matcher's clients do,
    through the live Matching and TradeModule, but not through markets-service);
  - the KMS signer and the systemd unit on the ops box.
- **Gain valuation with a short pool** is conservative, not exact (§3).
- **No offsets:** a perp/future basis trade pays both requirements.
- **Engine liquidations depend on the old SRM** (§5): it must never be paused while the engine is live. The runbook's
  guardian pause targets the engine after the cutover (`docs/cngn-perp-go-live.md`, "After the MarginEngine
  cutover").
- **No migration code:** positions left open on the old SRM stay there under its existing keeper and pager.
- **The keeper's holder scan** reads every account on each sweep: fine at dozens of accounts, not at thousands.
- **The matcher's margin pre-check for the future is an estimate.** It checks each account against
  `getMargin(account, true)` less the IM the fill adds, holds back the short account's order from every counterparty,
  and cancels it after 3 refusals over at least a minute (`insufficient_margin`). It is optimistic (no depeg penalty,
  a fill-time VM gain at par, a loss ignored), so the engine remains the authority: a revert it did not foresee carries
  no account, backs the pair off and cancels nothing.
- **RFQ is not supported.** Engine accounts trade only through the TradeModule. The RfqModule `0x8399…` was deployed
  against the same Matching, has the perp and the future unregistered, and settles in the frozen DFXM-era cash:
  - **Today:** Matching no longer allows it, so any RFQ action is refused before it reaches a manager
    (`M_OnlyAllowedModule`, in `verifyAndMatch`).
  - **If it were ever re-allowed:** it would price the future as an option premium and pass no fill price to the
    index-band check.

  It was never used: from its deployment its only logs were ownership events. It is retired on Base at block 52523521
  (tx `0x5ab98ed1…74db`), and the enable batch's `rfq` gate keeps it off: it refuses to open the market while the
  module is allowed, so it cannot quietly come back. The rehearsal checks the gate at head: the vault re-allows the
  module on the fork, enable is refused, and it passes again once the vault has retired it.
