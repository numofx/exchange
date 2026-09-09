# Wrapped-USDC quote leg for the USDC/cNGN spot book

Branch: `feat/wrapped-usdc-quote-leg`

**Verdict: the proposal is sound.** A `TradeModule` whose `quoteAsset` is the existing wrapped USDC
(`0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84`) works, makes both legs of a spot fill 1:1 token
transfers, and keeps `CashAsset` entirely out of the trade path. It is not a drop-in swap: three
prerequisites must land with it, one of which (the fee-recipient allowance) is a latent trade-halting
bug that only fires the day fees are switched on.

Two premises in the brief were wrong on the facts and are corrected below: the live spot book is not
on the StandardManager, and the fee recipient cannot grant the allowance the design needs.

---

## Phase 1 — what I verified

### a. Does `TradeModule` assume `quoteAsset` is `CashAsset`?

**No.** The quote asset is held and used as a plain `IAsset` throughout; there is no cast to
`ICashAsset`, no interest hook, no settle hook, no cash-specific branch.

- `contracts/execution/src/modules/TradeModule.sol:32` — `IAsset public immutable quoteAsset;`
- `contracts/execution/src/modules/TradeModule.sol:47-50` — constructor takes `IAsset`, stores it,
  never introspects it.
- `contracts/execution/src/modules/TradeModule.sol:233-241`, `:243-250`, `:252-259` — the three
  transfers in a fill (quote, base, fee) are built as `ISubAccounts.AssetTransfer` structs and handed
  to `subAccounts.submitTransfers`. Nothing calls a cash method.
- `contracts/execution/src/modules/TradeModule.sol:148-155` — the taker-fee transfer, same shape.
- `contracts/execution/scripts/deploy-all.s.sol:58` — the only thing binding it to cash today is the
  deploy script passing `IAsset(config.cash)`.

Prices and amounts are 18dp on both sides. `WrappedERC20Asset` normalises to 18dp on deposit
(`contracts/risk-core/src/assets/WrappedERC20Asset.sol:48` — `assetAmount.to18Decimals(assetDecimals)`),
so the `multiplyDecimal` arithmetic at `TradeModule.sol:228` is unchanged for a 6-decimal token.

The one real difference is the allowance contract, and it is what breaks the fee path:

- `contracts/risk-core/src/assets/CashAsset.sol:392` — returns
  `(finalBalance, adjustment.amount < 0)`: **credits need no allowance.**
- `contracts/risk-core/src/assets/WrappedERC20Asset.sol:125` — returns `(finalBalance, true)`:
  **every adjustment needs an allowance, credits included.**

### b. Where do trade fees settle, and can that path take a `WrappedERC20Asset`?

Fees settle as a third `quoteAsset` transfer into the `feeRecipient` **subaccount**, inside the same
`submitTransfers` batch as the fill:

- taker fee — `contracts/execution/src/modules/TradeModule.sol:148-155`
- maker fee — `contracts/execution/src/modules/TradeModule.sol:252-259`

It can take a `WrappedERC20Asset` **only if the fee subaccount grants the module a positive
allowance**, and today's fee subaccount cannot.

The fee subaccount is not one of the signed actions, so it is never transferred to the module
(`contracts/execution/src/Matching.sol:85-93`) and the module is not its owner. So
`_isApprovedOrOwner` is false at `contracts/risk-core/src/SubAccounts.sol:401` and `_spendAllowance`
runs. With cash that never mattered (credits skip the allowance); with a wrapped asset it reverts the
**entire batch** unless an allowance exists.

And the production fee recipient cannot create one:

- `contracts/execution/scripts/deploy-all.s.sol:50` — `feeRecipient = 1`.
- Subaccount 1 is the `SecurityModule`'s own account —
  `contracts/risk-core/src/SecurityModule.sol:42,53` creates it in the constructor, and
  `contracts/risk-core/scripts/deploy-core.s.sol:67` is reached with nothing else having claimed id 1.
- `subAccounts.setAssetAllowances` is `onlyOwnerOrManagerOrERC721Approved`
  (`contracts/risk-core/src/SubAccounts.sol:114-119`) and `SecurityModule` exposes no way to call it
  or to `approve` — its whole external surface is `setWhitelistModule`, `withdraw`, `recoverERC20`,
  `donate`, `payCashInsolvency`, `requestPayout`.

**Why this has not already bitten anyone:** fees are hardcoded to zero offchain —
`services/markets/internal/matching/executor.go:32` (`takerFillFee = "0"`) and `:23`
(`makerFillFeeZero = "0"`). A zero-amount adjustment returns `needAllowance = false`
(`WrappedERC20Asset.sol:118`), so it settles fine. The break is armed, not triggered.

**Fix, and it is inside the module's own API:** deploy with, or `setFeeRecipient` to, a subaccount
owned by the MPC vault, then have the vault call `setAssetAllowances(feeAcc, newTradeModule,
[{quoteAsset, positive: max, negative: 0}])`. `negative: 0` means the module can credit the fee
account and can never debit it. Both calls are emitted by the deploy script as vault actions.

No OI fee is charged on this path — `StandardManager._chargeAllOIFee` only bills `Perpetual` and
`Option` deltas (`contracts/risk-core/src/risk-managers/StandardManager.sol`, `_chargeAllOIFee`), so
a base/base spot fill needs no cash at all.

### c. Does `StandardManager` treat a wrapped quote leg differently from cash?

It does, in ways that are all fine, plus one prerequisite that is **already satisfied on mainnet**.

- **Whitelisting is mandatory.** `contracts/risk-core/src/risk-managers/StandardManager.sol:311-321`:
  cash is special-cased and skipped; every other asset must be whitelisted or `SRM_UnsupportedAsset`.
  Wrapped USDC already is: `contracts/risk-core/scripts/deploy-wrapped-usdc-deliverable-asset.s.sol:34-37`
  created market 1, whitelisted it as `AssetType.Base`, set `marginFactor 0.98/0.98` and pointed the
  market at the SRM's global `stableFeed`. Recorded at
  `contracts/risk-core/deployments/8453/WRAPPED_USDC_DELIVERABLE.json:3-6`.
- **Both sides now run a full margin check.** With cash, a seller receiving cash was
  `isPositiveCashDelta` and bypassed the check (`StandardManager.sol:311-317`). A wrapped debit is a
  `Base` delta `< 0`, so `riskAdding = true` on both sides. Not a correctness problem — an account
  holding only non-negative collateral has `IM >= 0` — just more gas.
- **Nothing can go negative.** `WrappedERC20Asset.sol:122` reverts `WERC_CannotBeNegative`. That is
  the structural backing the change is for, and it is stricter than `SRM_NoNegativeCash`, which is a
  risk parameter (`borrowingEnabled`) rather than an invariant.
- **Position caps do not bite on trading.** `checkAllAssetCaps` skips cash
  (`contracts/risk-core/src/risk-managers/BasePortfolioViewer.sol`), so wrapped USDC is now capped —
  but a transfer between two accounts leaves `totalPosition` unchanged
  (`contracts/risk-core/src/assets/utils/PositionTracking.sol:56` sums absolute balances), so only
  deposits can trip it.
- **Liquidation is unreachable in practice and unchanged in shape.** MM applies no oracle-contingency
  penalty (`StandardManager.sol`, `_getBaseMarginAndMtM` returns early when `!isInitial`), so an
  all-positive-collateral account cannot fall below MM. The IM path *can* go negative on a
  low-confidence feed, which blocks new trades rather than triggering an auction. `forceWithdraw`
  exists only on `CashAsset` (`contracts/risk-core/src/assets/CashAsset.sol:216`) and is unaffected;
  wrapped withdrawals go through `WithdrawalModule`, which is already asset-generic
  (`contracts/execution/src/modules/WithdrawalModule.sol:26`).

**The premise correction.** The brief says "same StandardManager", but the live spot book is not on
the SRM. `contracts/risk-core/DEPLOYED_ADDRESSES.md:42-49` — the cNGN spot SRM registration is
**"NOT YET EXECUTED"**, the batch is pending vault signature, and *"spot still runs on
`DeliverableFXManager` until all 11 actions land."* So I verified the live manager too:

- `contracts/risk-core/src/risk-managers/DeliverableFXManager.sol:216-224` — both `baseAsset`
  (wrapped USDC) and `quoteAsset` (wrapped cNGN) are recognised; a spot fill in either is accepted.
- `DeliverableFXManager.sol`, `_getMarginAndMarkToMarket` — wrapped USDC is credited 1:1 with cash,
  and with no futures the margin check reduces to "no negative balances", which wrapped assets
  guarantee.
- **New coupling, worth a reviewer's attention:** DFXM reserves wrapped USDC to back a short future's
  physical delivery (`_refreshReservations`, `_getDeliveryReadiness`). Once past `lastTradeTime`
  (`_getAggregateDeliveryRequirements` skips series before it), a spot buy that spends reserved USDC
  is rejected. Under the cash quote leg the same trade settled and the delivery obligation failed
  later, at delivery. This is the right direction — you cannot sell USDC you have promised to deliver
  — but it is a **new way for a spot order to be rejected**, for accounts that hold a deliverable
  future in its delivery window. Pinned by two tests.

### d. Offchain assumptions that the quote asset is cash

Three, one of which is dangerous:

1. **The funding check reads a hardcoded cash balance.**
   `services/markets/internal/matching/funding.go:223` built
   `SubAccounts.getBalance(accountId, c.cashAsset, 0)` from the single `CASH_ASSET_ADDRESS`, for every
   market, with the cache keyed by subaccount only. Pointed at a wrapped-quote module it would clear
   buys against a balance the fill never debits — a silently *weaker* guard, not a broken one.
   `quoteScale = 1e18` (`funding.go:51`) is **correct for both**, since `WrappedERC20Asset` stores
   18dp regardless of token decimals. Fixed.
2. **The matcher never validated the module address.** `cfg.TradeModuleAddress` was loaded
   (`services/markets/internal/config/config.go` (`TradeModuleAddress`)) and read nowhere. The only check was
   taker-module == maker-module, *after* a pair is reserved
   (`services/markets/internal/matching/executor.go:198-205`) — release, retry, loop, rather than a
   rejection at submit. Fixed.
3. **The quote asset is not in the signed payload.** `TradeData` is 7 words with no quote/settlement
   field (`services/execution/scripts/generate_trade_order.mjs:117-143`;
   decoder `services/markets/internal/api/orders.go:379-419`). The module address *is* the quote
   asset. That is what makes check 2 the right place to enforce it.

Deposits already work unchanged: both legs go through the asset contracts directly
(`services/execution/scripts/deposit_cngn.sh` calls `WrappedERC20Asset.deposit`), and `DepositModule`
is asset-generic (`contracts/execution/src/modules/DepositModule.sol:33-50`).

`services/execution` needs no code change — it already rejects any module address other than its one
configured `TRADE_MODULE_ADDRESS` (`services/execution/src/executor.ts:144-155`). That does mean **one
process serves one module**: this is a cutover, not coexistence.

---

## Phase 2 — what I built

### Contracts

- `contracts/execution/scripts/deploy-wrapped-quote-trade.s.sol` — deploys the wrapped-quote
  `TradeModule`. Preconditions are read from live chain state, not restated from config: quote asset
  must expose `wrappedAsset()`, and the fee subaccount must not be held by `Matching` (which could
  never grant the allowance). Warns when the fee subaccount's owner is a contract, naming
  `SecurityModule` as the case that does not work. Writes the two owner-only follow-ups
  (`matching.setAllowedModule`, `subAccounts.setAssetAllowances`) to
  `deployments/{chainId}/WRAPPED_QUOTE_TRADE_VAULT_ACTIONS.json` for the vault, in the style of
  `register-cngn-spot-srm.s.sol`.
- `contracts/execution/test/modules/TradeWrappedQuote.t.sol` — 11 tests under the StandardManager,
  set up to mirror mainnet (6dp USDC/cNGN, wrapped USDC as market 1 `Base` at `marginFactor 0.98`,
  wrapped cNGN as market 2 at `0`).
- `contracts/execution/test/modules/TradeWrappedQuoteDFXM.t.sol` — 5 tests under
  `DeliverableFXManager`, the manager actually live.

Covering the three tests asked for, plus the two findings:

| test | what it pins |
|---|---|
| `testWrappedQuoteRoundTripMovesOnlyWrappedBalances` | both balances move by *exactly* the traded amounts, the totals are conserved, all three `CashAsset` balances stay `0`, and the wrapped supply inside `SubAccounts` equals the tokens the asset custodies |
| `testWrappedQuoteRoundTripTakerIsSeller` | same, quote leg moving the other way |
| `testWrappedQuoteFeeBearingTradeCreditsFeeRecipientInWrappedUsdc` | taker + maker fees land on the fee subaccount as wrapped USDC; cash untouched |
| `testWrappedQuoteNonZeroFeeRevertsWithoutFeeRecipientAllowance` | **finding (b)**: a non-zero fee to an allowance-less recipient reverts `NotEnoughSubIdOrAssetAllowances` |
| `testWrappedQuoteZeroFeeSettlesAgainstAllowancelessFeeRecipient` | why (b) is latent — zero fees settle fine, so the misconfiguration is invisible |
| `testOrderSignedForCashModuleIsRejectedByWrappedModule` / `...WrappedModuleIsRejectedByCashModule` | **negative test**: `ACTION_TYPEHASH` commits to `module` (`contracts/execution/src/ActionVerifier.sol:21-23`), so a signature for one module fails `OV_InvalidSignature` on the other, both directions |
| `testMixedModuleBatchIsRejected` | a mixed batch fails `M_MismatchedModule` before any signature check |
| `testFilledAmountIsPerModuleNotShared` | `filled[owner][nonce]` is per-module state — the chain will not double-fill, but it will not stop an offchain matcher from offering the same size twice either, which is why the submit-time check below exists |
| `testBuyerCannotOverdrawTheWrappedQuoteLeg` | `WERC_CannotBeNegative` — the structural backing |
| `testCashQuotedModuleWouldTakeTheQuoteLegNegative` | the same trade on the cash module drives the quote leg negative and is stopped only by `SRM_NoNegativeCash`, a flag |
| `testSpotTradeSettlesInWrappedUsdcUnderDeliverableFXManager` + fee variant | it works under the manager that is actually live |
| `testSpotBuyCannotSpendUsdcReservedForFutureDeliveryInDeliveryWindow` | the new delivery coupling |
| `testSpotBuySpendingReservedUsdcIsAllowedBeforeDeliveryWindow` + `...WithinFreeUsdc...` | exactly when it does and does not bite |

### markets-service

- `internal/config/config.go` — new `QuoteAssetAddress` (`QUOTE_ASSET_ADDRESS`) and a
  `Config.QuoteAsset()` accessor that falls back to `CashAssetAddress`. It is an accessor, not a
  load-time default, so the fallback holds for a `Config` built any way — a test that sets only the
  cash address gets the same answer the service does. `validateFundingCheck` uses it.
- `internal/matching/funding.go` — the checker queries the quote asset;
  `fundingChecker.CashBalance` → `QuoteBalance`; the enabled log now states the quote asset and
  whether it is the cash ledger, because a wrapped-quote module paired with a cash-pointed check is
  the one misconfiguration that fails open.
- `internal/api/orders.go` — new `validateActionModule`, wired into `toParams`. Rejects an order
  whose `action_json.module` is not `TRADE_MODULE_ADDRESS`, naming both addresses. Unset means off,
  so dev and test are unaffected. This is what stops the two modules sharing a book.
- Tests: `TestChainFundingCheckerQueriesTheQuoteAssetNotCash`,
  `TestQuoteAssetDefaultsToCashAndIsOverridable`,
  `TestFundingGuardAcceptsQuoteAssetWithoutCashAsset`, and four
  `TestCreateOrderRequestToParams*Module*` cases.
- `README.md` — documents both variables and why they move together.

### infra

- `infra/aws/variables.tf` / `ecs.tf` — added `CASH_ASSET_ADDRESS` and `QUOTE_ASSET_ADDRESS` to
  `local.chain_env`. **`CASH_ASSET_ADDRESS` was never set in Terraform at all**, and since `APP_ENV`
  is also unset the production boot guard never fired — so the funding check has been *inert* in the
  AWS deployment. Found while tracing (d); fixed here because a wrapped quote leg makes that check
  load-bearing, but it is worth fixing regardless.

---

## What I am unsure about

1. **I could not read live chain state.** Every mainnet fact here comes from committed deployment
   artifacts. Confirm before deploying:
   - `cast call 0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c "feeRecipient()(uint256)"` — I assume 1;
     it is owner-mutable.
   - `cast call 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843 "ownerOf(uint256)(address)" 1` — I assume
     the `SecurityModule`.
   - `cast call 0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84 "totalPositionCap(address)(uint256)" <manager>`
     — must be non-zero for deposits; it caps deposits, not trading.
   - Which manager each live trading subaccount uses. My reading says `DeliverableFXManager`; the
     tests cover both.
2. **Which subaccount becomes the fee recipient.** I did not pick one, because it is a vault decision.
   It must be owned by an address that can call `setAssetAllowances` — i.e. the MPC vault directly,
   not a subaccount deposited into `Matching` and not the `SecurityModule`'s. The deploy script
   refuses the `Matching`-held case and warns on the contract-owner case; it cannot detect
   "contract that happens to have no allowance setter".
3. **Order-book migration is out of scope and unaddressed.** At cutover, orders resting on the book
   were signed for the old module. They cannot fill on the new one (proved by the negative tests) and
   they will now be rejected at submit. Someone has to cancel and re-sign the book. I did not write
   that.
4. **`RfqModule` was not touched.** It has the same `IAsset quoteAsset` shape
   (`contracts/execution/src/modules/RfqModule.sol:33`) and the same fee-allowance exposure. If RFQ
   is meant to move to a wrapped quote leg too, it needs the same treatment.
5. **The `MAX_UINT` allowance is decremented, not infinite** (`Allowances.sol`, `_spendAbsAllowance`).
   At realistic fee sizes it will not exhaust, but it is not literally permanent.
6. **I did not run a fork test** against Base mainnet. The suites use mocked feeds and fresh
   deployments. A fork test that executes the vault actions and a real fill against live state would
   be the right last gate before signing.
7. **I did not verify the `is_cash_asset: false` log line renders as intended** in the live log
   pipeline; it is new.

## Reproducing the test run

```bash
cd contracts/execution

# 16 new tests: 11 under StandardManager, 5 under DeliverableFXManager
forge test --match-path "test/modules/TradeWrappedQuote*.t.sol" -vv

# full execution suite, no regressions (226 passed, 1 skipped)
forge test --no-match-path "test/*Fork*.t.sol"

# the deploy script compiles
forge build
```

```bash
cd services/markets

go build ./...
go vet ./...
go test ./...

# just the changed paths
go test ./internal/config/ ./internal/matching/ ./internal/api/ -v -run 'Quote|Funding|Module'
```

Foundry `1.7.1`, solc `0.8.27`. The Go suite needs no database for these packages.

## Deploy order, if this ships

1. Vault creates (or designates) a fee subaccount it owns directly.
2. `QUOTE_ASSET=0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84 FEE_RECIPIENT=<id> forge script
   scripts/deploy-wrapped-quote-trade.s.sol --rpc-url $BASE_RPC_URL --broadcast`
3. Vault executes both actions in `WRAPPED_QUOTE_TRADE_VAULT_ACTIONS.json`, in order.
4. Confirm `cast call <newTrade> "quoteAsset()(address)"` matches, then set on markets-service and
   the matcher **together**: `TRADE_MODULE_ADDRESS=<newTrade>` and
   `QUOTE_ASSET_ADDRESS=0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84`. Changing one without the other
   is the failure this whole change is trying to prevent.
5. Point execution-service's `TRADE_MODULE_ADDRESS` at the new module (it accepts exactly one).
6. Cancel the resting book; clients re-sign against the new module.
