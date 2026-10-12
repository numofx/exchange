# MarginEngine and the cNGN future: reviewer brief

Scope, design, invariants and evidence for the outside review of [#180](https://github.com/numofx/exchange/pull/180):
USDC/cNGN dated futures, **cash settled in cNGN**, margined in **one account with spot cNGN and the cNGN-PERP**, on
**MarginEngine**, a fork of Lyra v2's StandardManager.

## 1. What to review

| File | Lines | How to read it |
|---|---|---|
| `src/risk-managers/MarginEngine.sol` | 866 | **As a diff against `StandardManager.sol`** (194 changed lines): `diff -u src/risk-managers/StandardManager.sol src/risk-managers/MarginEngine.sol`. The contract header lists every change. |
| `src/risk-managers/MarginEnginePortfolioViewer.sol` | 238 | As a diff against `SRMPortfolioViewer.sol` (90 lines): type renames, futures excluded from `depegPenaltyPos`, and the `_checkAssetCap` override. |
| `src/risk-managers/MarginEngineOptionHelper.sol` | 228 | As a diff against `OptionMarginHelper.sol` (31 lines): struct types renamed, **no logic change**. |
| `src/libraries/FutureVMLib.sol` | 244 | **New, in full.** Futures VM settlement, futures margin, close-out. |
| `src/assets/FutureAsset.sol` | 524 | **New, in full.** The dated future: marks, VM accounting, fixing, settlement. |
| `src/interfaces/IMarginEngine.sol`, `IMarginEnginePortfolioViewer.sol`, `IFutureAsset.sol` | 234, 21, 114 | Interfaces. |
| `src/risk-managers/BasePortfolioViewer.sol` | 1 word | `_checkAssetCap` made `virtual`. No behaviour change for existing managers. |
| `scripts/deploy-margin-engine.s.sol` | 585 | The deployment, its postconditions, and the two vault batches it writes. |

### Carried, unaudited code (recommended in scope)

The live perp SRM is not Lyra's audited StandardManager. Numo changed it after the import, and the fork inherits
those changes:

- `0d81da6` added a USDC-settled `DatedFuture` asset type. **The fork reworks this path.** It replaces it with the
  cNGN-settled `FutureAsset`, so that code is new either way.
- `3063ff0` moved option margin into `OptionMarginHelper` to fit the contract size limit (309 lines out of the
  manager). **Options are retained in the fork, unlisted.**

The cumulative diff from Lyra's last audited version (#361, `12cb35a`) is about 389 lines in `StandardManager.sol`
and 179 in `SRMPortfolioViewer.sol`. Reviewing the fork against today's `StandardManager.sol` trusts those changes as
they stand. Reviewing it against `12cb35a` covers them too.

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
  - **The matcher must enforce the same bound before matching**, so out-of-band orders are refused instead of reverting at
    settlement. It is a requirement of the futures listing in markets-service, which has no futures path yet.
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
     at it), then the rest at par. Series are taken in settlement's order.
   - **A gain** counts at the base factor.
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
     pool-withdraw`. A cNGN withdrawal must leave the reserve target; a cash one must leave zero cash.
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
| Futures OI cap | 30 contracts (15 a side, $15k) | sized so the SecurityModule's $3,250 covers a 25% step (~$2,947 with the perp) |
| Perp OI cap on the engine | the SRM's (50M cNGN) | deploy script |
| cNGN escrow cap on the engine | 100M (**proposed, awaiting sign-off**) | spot and perp collateral (50M) plus futures (50M) |
| Pool reserve | 30% of one side at the cap, ~6.1M cNGN | a 25% move paid in cash, plus one 5% mark |
| Marks | 1h pull interval; 5% move limit; 10% → 1% band over 14 days; 2h forward heartbeat | deploy script |
| Fixing | 1h window, 15-minute gap limit, fallback after 24h within 2% | deploy script |

## 7. Evidence

| | Command | Result |
|---|---|---|
| StandardManager's suite on the engine | `forge test --match-path "test/risk-managers/unit-tests/MarginEngine/*"` | 141/141, the same as on StandardManager |
| Futures suite (FutureManager's 65, ported) and engine tests | same path, `TestMarginEngine_Future` | 87: cross-margin, the depeg, close-only cap, reduction between MM and IM, settlement invariance (including series out of order and gain/loss in both orders), the negative pool, and the fill bound |
| Fork tests (Base, real contracts) | `BASE_RPC_URL=… forge test --match-contract MarginEngineDeployFork` | 23 |
| Fork rehearsal (keeper process, vault batches through the proposer) | `pnpm rehearse:future` in `services/perp-feeds` | passes |
| Full CI equivalent | `./scripts/verify.sh` | risk-core 1,339, execution 261, perp-feeds 126 |

The fork tests include:
- **margin parity on live contracts:** the same spot and perp portfolio under the SRM and under the engine has
  identical IM, MM and mark-to-market;
- spot, perp and future in one engine account;
- the live SRM untouched;
- liquidation through the real auction, and an insolvency paid by the real SecurityModule;
- a stale index during the fixing, then the bounded fallback;
- **the pool run negative:** a solvent liquidation still starts and its fee reaches the SecurityModule, with borrowing on
  and off; `startAuction(pool)` reverts; the treasury tops up a negative pool.

The fork rehearsal runs:
- one account holding spot cNGN, the perp and futures;
- the enable batch refused until the pool is seeded;
- marks from the book and from carry, and the band narrowing;
- the payers-first sweep, and the startup sweep after a kill;
- the fixing across a keeper restart, close-out, and withdrawal of real cNGN;
- **a pager drill:**
  1. The pool is emptied of cNGN; the proposer refuses that, so the vault does it directly.
  2. It is drained past −$250 by winners settling before the loser.
  3. The real pager pages `future-pool-borrowing` to the stubbed phone.
  4. The pool is topped up, and the page resolves.

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

## 8. Known limitations

- **Not covered by any test:**
  - fills through the TradeModule and matcher (tests and the rehearsal submit transfers directly);
  - the KMS signer and the systemd unit on the ops box.
- **Gain valuation with a short pool** is conservative, not exact (§3).
- **No offsets:** a perp/future basis trade pays both requirements.
- **No migration code:** positions left open on the old SRM stay there under its existing keeper and pager.
- **The keeper's holder scan** reads every account on each sweep: fine at dozens of accounts, not at thousands.
- **The matcher's fill-band check** is required before the enable batch, as part of the futures listing. Until then, an
  out-of-band order would match and revert at settlement.
