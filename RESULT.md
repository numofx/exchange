# Wrapped-USDC quote leg for USDCcNGN-SPOT

Branch: `feat/spot-wrapped-usdc-quote`

**Verdict: the proposal is sound, and it does not work as stated.** `TradeModule` genuinely does not
care that its quote asset is the CashAsset, and a wrapped quote gives a strictly stronger backing
invariant than the one the book has today. But swapping only the module ships two defects, one of
them latent — it would not surface until someone turned taker fees on. Both are fixed here, and both
have tests that fail without the fix.

---

## Phase 1 — what was verified

### a. Does `TradeModule` or anything it calls assume `quoteAsset` is `CashAsset`?

**No.**

- `contracts/execution/src/modules/TradeModule.sol:32` — `IAsset public immutable quoteAsset`, a
  plain `IAsset`, not `ICashAsset`.
- `contracts/execution/src/modules/TradeModule.sol:47` — the constructor takes `IAsset`.
- The only three uses are `ISubAccounts.AssetTransfer` entries at `subId: 0`:
  `TradeModule.sol:145-152` (taker fee), `TradeModule.sol:224-232` (quote leg),
  `TradeModule.sol:244-251` (maker fee). No interest hook, no settle call, no interface cast.
- `contracts/execution/src/Matching.sol` and `ActionVerifier.sol` never touch an asset at all.

Two adjacent things that *do* assume cash, and are therefore deliberately not part of this change:

- **`RfqModule`** takes an `ICashAsset` in its constructor
  (`contracts/execution/scripts/deploy-all.s.sol:62`). It cannot make the same move without a code
  change.
- **Liquidation.** `BaseManager._executeBid` pays the liquidated account in cash
  (`contracts/risk-core/src/risk-managers/BaseManager.sol:234`) and skips cash when transferring the
  seized portion (`BaseManager.sol:219`). A wrapped-quote book is still liquidated *in cash*. That
  works — it is what the cNGN leg already does — but "cash out of the trade path" is not "cash out of
  the system".

### b. Where do trade fees settle, and can that path take a `WrappedERC20Asset`?

**Not as currently configured. This is the blocker.**

Fees are a quote-asset transfer from the trading subaccount to `feeRecipient`
(`TradeModule.sol:145-152`, `:244-251`). The difference between the two assets is one line:

| | credit side (`amount > 0`) | debit side |
|---|---|---|
| `CashAsset.handleAdjustment` | `needAllowance = false` | `true` |
| `WrappedERC20Asset.handleAdjustment` (`:124-125`) | **`needAllowance = true`** | `true` |

`SubAccounts._transferAsset` spends an allowance on the `toAcc` when `needAllowance` is set and the
caller is not owner-or-approved (`contracts/risk-core/src/SubAccounts.sol:394-403`). The TradeModule
*owns* both trading subaccounts while it executes (`Matching.sol:96`), but it never owns the fee
recipient — so a non-zero fee needs an allowance the fee account granted in advance.

And the live fee recipient can never grant one. Verified against Base mainnet:

```
TradeModule 0x44813aD30b2fFC1bB2871Eed9b19F63c8196eD1c  feeRecipient() = 1
SubAccounts 0x7019244E25FA416e6Ca2ed2F3cA25277aef72843  ownerOf(1)  = 0x3195Bd7e…  (the SRM)
                                                        manager(1)  = 0x3195Bd7e…  (the SRM)
```

`setAssetAllowances` is `onlyOwnerOrManagerOrERC721Approved` (`SubAccounts.sol:116`) and
`StandardManager` exposes no call that reaches it. Subaccount 1 is permanently unable to authorise
the module.

**Why this is worse than a plain blocker:** maker and taker fees are hard-coded to `"0"` today
(`services/markets/internal/matching/executor.go:23,32`), and
`WrappedERC20Asset.handleAdjustment:118` returns early on a zero amount without requesting an
allowance. So the naive port *works* — right up until the first non-zero fee, at which point every
fill reverts. It would ship green.

**Fix:** the new module takes a fee recipient whose owner is an EOA, and that owner grants a
`type(uint).max` positive asset allowance once. Max rather than a budget because allowances are
decremented on every spend (`contracts/risk-core/src/Allowances.sol:142-149`) — a finite grant is a
scheduled outage. The deploy script refuses a contract-owned fee recipient outright.

### c. Does `StandardManager` treat a wrapped-asset spot position differently from cash?

**Yes, in one way that matters: it needs an oracle, and cash does not.**

- **Whitelisting is already done.** `srm.assetDetails(0x364058aFF…)` returns
  `(isWhitelisted: true, assetType: Base, marketId: 1)` on Base, from
  `contracts/risk-core/scripts/deploy-wrapped-usdc-deliverable-asset.s.sol:31-37`. No
  `SRM_UnsupportedAsset`.
- **Margin cannot fail.** `_getBaseMarginAndMtM` (`StandardManager.sol:602-633`) credits a base
  position at `marginFactor × IMScale`; `baseMarginParams(1)` is `(0.98e18, 0.98e18)` on Base. Cash
  is credited at 100% (`StandardManager.sol:416-417`). Either way a portfolio of two non-negative
  base positions has a non-negative margin, so the check passes trivially for a spot-only book.
- **But margin can now *revert*.** `_getMarketMargin` reads `_getSpotPrice(marketId)` for every
  market the account holds (`StandardManager.sol:443`, `:770-772`). Under a cash quote, spot accounts
  hold cash (no oracle) plus wrapped cNGN (market 2, static feed). Under a wrapped quote every
  account holds market 1 — and `spotFeeds[1]` is still `0xDAe566adc61086535986AfBd80093B1DD8686797`,
  the live `LyraSpotFeed` with `heartbeat() = 3600` (both read from mainnet).

  This is precisely the halt the static feeds were deployed to remove from this venue —
  `contracts/risk-core/scripts/deploy-cngn-spot-static-feeds.s.sol:24-29` says so in as many words.
  The change re-introduces it through a different door. Note also that the "frozen price is inert
  only while marginFactor is 0" caveat at `:31-33` does **not** hold for market 1, whose margin
  factor is 0.98.

  **Fix:** one vault call, `srm.setOraclesForMarket(1, staticStableFeed, 0, 0)`, emitted as action 2
  of the deploy script's batch. Proved by `testForkStaleStableFeedHaltsTheBookUntilTheOracleIsRepointed`,
  which warps two hours past the heartbeat on a live Base fork: the fill reverts, the vault call
  lands, the same fill settles.

- **The upside is real, not cosmetic.** `WrappedERC20Asset.handleAdjustment:122` reverts on a
  negative final balance. That is *below* the manager. Today's protection is
  `SRM_NoNegativeCash` (`StandardManager.sol:382`), a policy check gated on
  `borrowingEnabled` — two owner-only settings from the vault key and the same overdraw goes through.
  `testCashQuoteOverdrawIsOnlyAPolicyCheck` and `testWrappedQuoteOverdrawSurvivesAPermissiveManager`
  are that pair.
- **`forceWithdraw` is cash-only** (`CashAsset.sol:216-228`). `WrappedERC20Asset` has no
  manager-driven escape hatch — only `withdraw`, which requires `msg.sender == ownerOf(accountId)`
  (`WrappedERC20Asset.sol:71-72`), i.e. the Matching contract for a deposited subaccount. Exits must
  go through `WithdrawalModule`. Unchanged from the cNGN leg, but it means the wrapped quote has one
  fewer recovery lever than cash.
- **Position caps are not a concern.** `PositionTracking._updateTotalPositions` sums absolute
  balances, so an account-to-account transfer leaves `totalPosition` unchanged; the cap only gates
  deposits. `totalPositionCap(srm)` on wrapped USDC is `1e36`.

### d. Do the services assume the quote asset is cash?

**One place, and it is load-bearing.**

- `services/markets/internal/matching/funding.go:223` built its `eth_call` as
  `getBalance(account, CASH_ASSET_ADDRESS, 0)`. For a wrapped-quote module this reads a ledger the
  trade never touches: a buyer with wrapped USDC and no cash is refused, and a buyer with cash and no
  wrapped USDC is waved into a fill that reverts on chain. Repointed here.
- `services/markets/internal/instruments/registry.go:34` documented the cash assumption in its
  `SettlementNote`. Updated.
- **Module confusion is prevented on chain but not in the book.** `module` is a hashed field of
  `ACTION_TYPEHASH` (`ActionVerifier.sol:22`, hashed at `:126`), so a signature cannot be moved
  between modules, and `Matching.sol:69` rejects a batch whose actions disagree. But the markets
  service never compared `action_json.module` to anything — the matcher takes it from the order and
  only requires taker and maker to agree *with each other*
  (`internal/matching/executor.go:198-205`). During a two-module window the book would rest orders
  for both, cross a mismatched pair, lock it into `matching`, and only then fail. A submit-time pin
  is added.
- `TRADE_MODULE_ADDRESS` was loaded and never read in the Go service
  (`internal/config/config.go:32,85` only) — which made it look as though a module allowlist existed
  there. It is now what the pin uses, and required in production.
- Nothing else offchain touches an asset address. execution-service encodes `OrderData` with no
  asset fields at all; the custody guard checks NFT ownership only; the DB keys on
  `(asset_address, sub_id)`.

---

## Phase 2 — what was built

**Contracts**

- `contracts/execution/scripts/deploy-wrapped-quote-trade-module.s.sol` — deploys the module and
  emits a three-action vault batch (`setAllowedModule`, `setOraclesForMarket`,
  `setAssetAllowances`) with per-action digests and the caller each one needs. Refuses to run if the
  quote asset is not whitelisted `Base` on the SRM, if market 1 has no spot feed, or if the fee
  recipient is contract-owned. It has no default fee recipient, so subaccount 1 cannot be inherited
  by accident.
- `contracts/execution/test/modules/TradeModuleWrappedQuote.t.sol` — 14 deterministic tests on a
  real `StandardManager` + two real `WrappedERC20Asset`s.
- `contracts/execution/test/modules/TradeModuleWrappedQuoteFork.t.sol` — 6 tests against live Base
  contracts. Skipped off-fork, so CI is unaffected.
- `contracts/execution/foundry.toml` — `fs_permissions` read access to `../risk-core`.
  `Utils._readV2CoreDeploymentFile` still points at the pre-monorepo `../../exchange-core` path,
  which does not exist in this repo.

**Services / infra**

- `Config.QuoteAsset()` — `QUOTE_ASSET_ADDRESS`, falling back to `CASH_ASSET_ADDRESS`. Resolved as a
  method rather than mutated in `Load` so the fallback holds for any `Config`.
- `funding.go` — `CashBalance` → `QuoteBalance`, reads the resolved quote asset.
- `validateActionModule` (`internal/api/orders.go`) — pins every submitted order to
  `TRADE_MODULE_ADDRESS`. Inert when unset.
- `validateTradeModule` — production boot guard for `TRADE_MODULE_ADDRESS`.
- `infra/aws` — `quote_asset_address` and `cash_asset_address` variables, injected via `chain_env`,
  both defaulting to `""`.

**Nothing on Base was changed.** Every mainnet interaction in this work was `eth_call` or a local
fork.

---

## Reproducing

```bash
# 1. contract unit tests (no network) — 14 tests
cd contracts/execution && forge test --match-contract TradeModuleWrappedQuoteTest -vv

# 2. contract fork tests against live Base — 6 tests
cd contracts/execution && forge test --match-contract TradeModuleWrappedQuoteForkTest \
  --fork-url "$BASE_RPC_URL" -vv

# 3. full execution suite (fork tests skip off-fork)
cd contracts/execution && forge test

# 4. markets service
cd services/markets && go build ./... && go vet ./... && go test ./...

# 5. the deploy script's fee-recipient guard, against live Base state.
#    Expected to FAIL with "fee recipient is contract-owned…" — that is the guard firing on the
#    live module's feeRecipient (subaccount 1).
cd contracts/execution && FEE_RECIPIENT_SUBACCOUNT=1 \
  forge script scripts/deploy-wrapped-quote-trade-module.s.sol --rpc-url "$BASE_RPC_URL"
```

Results on this branch: (1) 14/14 pass, (2) 6/6 pass, (3) all suites pass, (4) all packages pass,
(5) reverts as documented.

`forge test` in `contracts/risk-core` has **pre-existing** fork-test failures (`CNGNSpotResume`,
`CNGNSpotPreconditions` — the vault batch they assert is unexecuted has since been executed on Base,
plus public-RPC rate limiting). No file under `contracts/risk-core` is modified on this branch.

---

## What I am unsure about

1. **Whether the oracle repoint is wanted at all.** Pointing market 1 at a frozen $1 feed while its
   margin factor is 0.98 means wrapped USDC is credited at 96.04% of a price that can no longer
   move. For USDC-as-numeraire that is the right answer and matches what
   `deploy-cngn-spot-static-feeds.s.sol:53-54` already assumes. If anyone ever wants a real USDC
   depeg to reduce margin credit, this is exactly the wrong call — but then the 3600s halt comes
   back, and that trade-off should be made deliberately rather than inherited.
2. **Whether SRM market 1 is used by anything else.** I could not find another consumer — the
   SEP-16-2026 future uses wrapped USDC as its base under `DeliverableFXManager`
   (`0xcE01f3D7…`), not the SRM — but `setOraclesForMarket` is global to the market and I have not
   proved market 1 has no other reader.
3. **The fee-allowance grant is a trust decision I did not make.** `type(uint).max` on the wrapped
   quote lets the module credit that account without bound. It can only ever *credit* it (the grant's
   negative side is 0), so the exposure is "this module can put tokens here", not "can take them".
   Still, someone should sign off on it rather than inheriting it from a script.
4. **`ENFORCE_FUNDING_CHECK` is inert in production right now.** Neither `APP_ENV` nor
   `CASH_ASSET_ADDRESS` is set on the ECS tasks, so `IsProduction()` is false and the checker returns
   nil. I did not change that — turning it on is a live behaviour change that deserves its own
   deploy. But it means the funding-check repoint in this branch is currently correcting code that
   does not run. It becomes load-bearing the moment `APP_ENV` and the quote asset are set, which the
   cutover will want.
5. **`filled` and `seenNonces` are per-module storage** (`TradeModule.sol:39,45`), so one
   owner+nonce can be spent once on each module — covered by
   `testSameNonceIsSpendableOnceOnEachModule`. The markets-side module pin closes it for this venue,
   but nothing on chain deduplicates across modules. Worth knowing if the two are ever allowlisted
   simultaneously for longer than a cutover.
6. **I did not touch `packages/abis/src/generated/deployments.ts`**, which hard-codes
   `trade: 0x44813aD3…` and is execution-service's fallback when `TRADE_MODULE_ADDRESS` is empty. It
   should be regenerated (`pnpm --filter @numo/abis generate`) after the real deployment, or
   local/`pnpm dev` runs will silently use the old module.

## Cutover order

The two modules cannot both serve the book, so this is a hard cutover, not a rolling one:

1. Deploy the module and execute the three vault actions.
2. Drain the book of resting orders (`services/markets/scripts/quarantine_legacy_orders.sh`).
3. Set `trade_module_address` and `quote_asset_address` in **one** apply, and redeploy markets.
4. Regenerate `@numo/abis`.
5. Only then `setAllowedModule(0x44813aD3…, false)`.
