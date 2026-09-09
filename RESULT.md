# Wrapped-USDC-quoted TradeModule for USDC/cNGN spot

Branch: `feat/wrapped-usdc-quote-trade-module`

Goal: make the USDC leg of the USDC/cNGN spot book structurally 1:1 backed, the way the cNGN leg
already is, by quoting the book in the existing `WRAPPED_USDC_DELIVERABLE` `WrappedERC20Asset`
(`0x364058aFF6f36E01505fB2Cc870f8B6BD4835e84`) instead of `CashAsset`
(`0x6B232A2155Bd0C9bf741dB4cf8E7e8A0176A6fc6`).

**Verdict: the proposal is sound.** Nothing in `TradeModule`, `StandardManager`, or the asset layer
assumes the quote asset is cash. Two things do have to change with it, and both are handled here:
a fee-recipient allowance on chain, and the markets-service funding check, which reads a *cash*
balance by hardcode.

---

## Phase 1 — what was verified

### a. Does `TradeModule` (or anything it calls) assume `quoteAsset` is `CashAsset`?

**No.** The quote asset is stored and used only as the generic `IAsset`.

- `contracts/execution/src/modules/TradeModule.sol:32` — `IAsset public immutable quoteAsset;`
- `contracts/execution/src/modules/TradeModule.sol:47-50` — constructor takes `IAsset`, no cast.
- `TradeModule.sol:149`, `:234`, `:253` — the only three uses, all as `AssetTransfer.asset`.
  No `ICashAsset` call, no interest hook, no settle hook anywhere in the file.
- `contracts/execution/src/interfaces/ITradeModule.sol:57` — the public getter is `IAsset` too.

For contrast, the module that *does* hardcode cash is the liquidation one, and it is untouched by
this change: `contracts/execution/src/modules/LiquidateModule.sol:28,32,62` holds an `ICashAsset`
read off the auction.

`RfqModule` has the same generic shape (`contracts/execution/src/modules/RfqModule.sol:33,41-42`)
but is **out of scope here** — it is still cash-quoted and stays that way.

### b. Where do trade fees settle, and can that path take a `WrappedERC20Asset`?

Fees are a third `quoteAsset` transfer into the `feeRecipient` **subaccount**:

- `TradeModule.sol:145-155` — the taker fee leg.
- `TradeModule.sol:248-257` — the maker fee leg, appended per fill.
- `contracts/execution/scripts/deploy-all.s.sol:50` — `uint defaultFeeRecipient = 1;` — subaccount 1
  on Base.

**It can, but only after a one-time allowance grant.** This is the one real finding:

- `contracts/risk-core/src/assets/WrappedERC20Asset.sol:124-125` — returns
  `needAllowance = true` for **every** non-zero adjustment, credits included.
- `contracts/risk-core/src/assets/CashAsset.sol:392` — returns `adjustment.amount < 0`, so a cash
  *credit* needs nothing.
- `contracts/risk-core/src/SubAccounts.sol:401-403` — allowance is spent on the **`toAcc`** side too
  when the caller is not owner-or-approved.
- `contracts/execution/src/Matching.sol:89-97` — Matching transfers only the subaccounts *named in
  the actions* to the module. The fee recipient is never among them, so `msg.sender` (the module)
  is neither its owner nor approved.

Net effect: with a wrapped quote asset, any **non-zero** fee reverts with
`IAllowances.NotEnoughSubIdOrAssetAllowances` until the fee-recipient subaccount's owner calls
`subAccounts.setAssetAllowances(feeRecipient, module, [{wrappedUsdc, positive: N, negative: 0}])`.
A **zero** fee is fine — `WrappedERC20Asset.sol:118` short-circuits a zero adjustment before asking
for allowance, and `Allowances.sol:96-98` early-returns on zero. Fees on this venue are `"0"` today
(`services/markets/internal/matching/executor.go:25-32`), so the module works from day one, but it
would break the moment fees are switched on.

Two consequences worth stating plainly, because they are not obvious:

1. **The fee-recipient subaccount must not be held by Matching.** `Matching` exposes no way to call
   `setAssetAllowances`, so a Matching-held fee subaccount can *never* grant this allowance.
   Allowance is keyed `[accountId][owner][asset][delegate]` and resolved against `ownerOf` at spend
   time (`Allowances.sol:22-35`, `:95-119`), so it must be granted by whoever holds it. The deploy
   script reads `ownerOf(feeRecipient)` and warns loudly if it is Matching.
2. **The allowance is a budget, not a switch** — `_spendAbsAllowance`
   (`Allowances.sol:132-151`) decrements it, so it needs topping up.

The same applies to any fill where `TradeData.recipientId != subaccountId`, since that credit leg
also lands on an account the module does not hold (`TradeModule.sol:234-241`). The matcher sets them
equal today.

### c. Does `StandardManager` treat a wrapped-asset spot position differently from cash?

**Yes, but in the safe direction, and the paths that are cash-specific are ones this change does not
enter.**

- **Margin check.** A negative delta on a whitelisted `Base` asset takes the `else` branch at
  `contracts/risk-core/src/risk-managers/StandardManager.sol:346-350` and sets `riskAdding = true`,
  exactly as a negative cash delta does at `:311-317`. So the payer still gets a full IM check.
- One difference: `isPositiveCashDelta` stays `true` when no cash moves, so the
  `SRM_NoNegativeCash` guard at `StandardManager.sol:382` is skipped. Harmless — cash cannot go
  negative in a trade that never touches it.
- **Margin value.** `_getBaseMarginAndMtM` (`StandardManager.sol:602-633`) takes a `uint position`:
  base assets can only be positive, which is exactly `WrappedERC20Asset`'s
  `WERC_CannotBeNegative` invariant (`WrappedERC20Asset.sol:122`). Wrapped USDC is market 1 at
  `marginFactor 0.98 / IMScale 0.98`
  (`contracts/risk-core/scripts/deploy-wrapped-usdc-deliverable-asset.s.sol:19-20,35-37`), so it
  contributes **positive** margin, where cash contributes 100%
  (`StandardManager.sol:416-417`). A cNGN buyer therefore ends up *better* collateralised
  post-trade than today, not worse. Nothing gets more permissive in a way that lets an
  undercollateralised account through, because the IM check is unchanged and cNGN still counts for
  zero (`CNGN_SPOT_SRM_VAULT_ACTIONS.json`: `srm.setBaseAssetMarginFactor(2, 0)`).
- **Liquidation.** Auction bids settle in cash via
  `contracts/risk-core/src/risk-managers/BaseManager.sol:234,252,347` — manager-level and entirely
  outside the trade path. Unchanged by this proposal, and identical to how the wrapped cNGN leg is
  already liquidated today.
- **`forceWithdraw`.** Exists only on `CashAsset` (`CashAsset.sol:216-228`); there is no equivalent
  on `WrappedERC20Asset` and no manager path that calls one. Wrapped withdrawal goes through
  `WrappedERC20Asset.withdraw` (`:71-89`), which requires the account owner — reached from a
  Matching-held subaccount via `WithdrawalModule`, which is already asset-generic
  (`contracts/execution/src/modules/WithdrawalModule.sol:26` — `IERC20BasedAsset(data.asset)`).
  So the wrapped quote leg is simply not in the `forceWithdraw` path. Nothing breaks; the escape
  hatch is a different one.

### d. Do markets-service or the matcher assume the quote asset is cash?

**Yes — one place, and it is load-bearing.**

- `services/markets/internal/matching/funding.go` reads the buyer's balance as
  `getBalance(accountId, CASH_ASSET_ADDRESS, 0)`, with the asset hardcoded to `c.cashAsset` and the
  interface literally named `CashBalance`. With a wrapped quote it would compare the required quote
  against a cash balance the trade never moves — passing or failing for an unrelated reason, with
  no error.
- The `funding.go:20-47` comment block's reasoning ("netMargin for a spot-only account reduces to
  cash") also stops holding once the quote leg carries a `marginFactor`.
- `services/markets` **never validated `action.module` at all** — `TRADE_MODULE_ADDRESS` was
  dead config (read at `internal/config/config.go:32,85`, referenced nowhere else). The only module
  check was post-cross in `services/execution/src/executor.ts:144-155`, whose failure surfaces as a
  generic executor error and a retry-until-expiry loop, not a submit-time rejection.
- No PnL / equity / margin engine exists in either service, and neither has a deposit or withdraw
  code path, so there was nothing else to change.

Both are fixed on this branch. Nothing in Phase 1 broke the proposal, so I proceeded.

---

## Phase 2 — what was built

### Contracts (`contracts/execution`)

| File | What |
|---|---|
| `scripts/deploy-wrapped-quote-trade-module.s.sol` | **new.** Deploys `TradeModule(matching, wrappedUsdc, feeRecipient)`, checks preconditions, hands ownership to the vault, and writes both a deployment artifact and a vault-actions JSON. |
| `test/shared/SpotWrappedQuoteBase.t.sol` | **new.** Mainnet spot shape in miniature: SRM with borrowing off, cash ledger, 6dp wrapped USDC at market 1 (`0.98/0.98`), 6dp wrapped cNGN at market 2 (`marginFactor 0`), Matching, and **two** TradeModules — the legacy cash-quoted one and the wrapped-quoted one. |
| `test/modules/TradeWrappedQuote.t.sol` | **new.** 12 tests, below. |
| `foundry.toml` | `fs_permissions` now allows reading `../risk-core`, which is where the deploy script resolves core/`WRAPPED_USDC_DELIVERABLE` addresses through the committed `v2-core` symlink. |

**The deploy script deliberately does not disable the old module.** The cash-quoted TradeModule also
carries the SEP-16-2026 deliverable FX future (`DEPLOYED_ADDRESSES.md`); revoking it would take the
futures market down with the spot migration. Cutover is done by repointing the services.

It also cannot enable the new one: `Matching` is owned by the MPC vault, so `setAllowedModule` is
`onlyOwner`. The script writes `deployments/{chainId}/WRAPPED_QUOTE_TRADE_VAULT_ACTIONS.json` in the
same shape risk-core uses for `CNGN_SPOT_SRM_VAULT_ACTIONS.json` — three actions:
`acceptOwnership()`, `setAllowedModule(new, true)`, and the conditional fee allowance. Until the
vault runs action 1, the module exists but `verifyAndMatch` reverts `M_OnlyAllowedModule` for it,
which is the correct resting state.

### Services (`services/markets`)

- `internal/config/config.go` — new `QuoteAssetAddress` (`QUOTE_ASSET_ADDRESS`) and a
  `Config.QuoteAsset()` accessor that **falls back to `CashAssetAddress`**, so an unset variable
  reproduces today's behaviour exactly. `validateFundingCheck` now accepts either.
- `internal/matching/funding.go` — the checker is now asset-agnostic: `fundingChecker.CashBalance`
  → `QuoteBalance`, `chainFundingChecker.cashAsset` → `quoteAsset`, sourced from
  `cfg.QuoteAsset()`. The `funding_check_enabled` log line now names the quote asset and whether it
  is cash.
- `internal/api/orders.go` — new `validateActionModule`, called from `toParams`. This makes
  `TRADE_MODULE_ADDRESS` live: an order signed for a different TradeModule is now rejected at
  submit time instead of resting, crossing, and retry-looping until expiry. Inert when unset.
- `internal/instruments/registry.go` — the spot instrument's `SettlementNote` is derived from
  `QUOTE_ASSET_ADDRESS` rather than asserting "internal USDC cash", so the advertised settlement
  story cannot drift from the configured rail.
- `.env.example`, `README.md` — documented.

### Infra (`infra/aws`)

- New `cash_asset_address` and `quote_asset_address` variables; both wired into the **markets** and
  **matcher** task definitions. `CASH_ASSET_ADDRESS` was previously absent from `ecs.tf` entirely,
  which meant `newFundingChecker` returned `nil` and **the pre-trade funding check has been inert in
  the ECS deployment** — a pre-existing bug this change also closes.

### `services/execution`

No change needed. `TRADE_MODULE_ADDRESS` is already an env override with a per-chain fallback
(`src/config.ts:15,34,54`, `src/index.ts:32`), and `executor.ts:144-155` already pins
`module_address` to it. Cutover is a variable change.

---

## Tests

`contracts/execution/test/modules/TradeWrappedQuote.t.sol`, all passing:

**Round trip, both legs wrapped, cash untouched** (the required test)
- `testRoundTripMovesOnlyWrappedBalances` — cam's and doug's wrapped balances move by *exactly*
  `-743.376685636834e18` / `+1_000_000e18` and the mirror; all three accounts' `CashAsset` balances
  are unchanged (seeded non-zero, so this asserts something); and the wrapper's real ERC20 holding
  still equals the sum of internal balances.
- `testRoundTripSellSide` — taker on the ask, fully unwound back to the starting state.

**Fee-bearing** (the required test)
- `testFeeBearingTrade` — taker pays notional + its fee, maker receives notional − its fee, both
  fees land on the fee recipient **as wrapped USDC, not cash**, the allowance is decremented by
  exactly the fees taken, and the three balances still sum to the deposited total.
- `testFeeRevertsWithoutPositiveAllowanceOnFeeRecipient` — pins finding (b): the exact
  `NotEnoughSubIdOrAssetAllowances` revert, with its arguments, when the allowance is absent.
- `testZeroFeeNeedsNoAllowance` — documents why the zero-fee path needs nothing.

**The two modules cannot be confused** (the required negative test)
- `testSignatureIsBoundToOneModule` / `...Reverse` — re-pointing a signed action at the other module
  fails signature recovery, because `module` is inside the EIP-712 struct hash
  (`ActionVerifier.sol:21-23,120-133`).
- `testCannotCrossOrdersAcrossModules` — a taker signed for one and a maker signed for the other is
  rejected as `M_MismatchedModule` before any module runs (`Matching.sol:69`).
- `testLegacyModuleStillSettlesInCashAndLeavesWrappedUsdcAlone` — positive control: the same
  economic order on the legacy module moves cash and leaves wrapped USDC untouched. They are
  separate rails, not two names for one.
- `testNonceStateIsPerModule` — `filled`/`seenNonces` are per-module storage, so a matcher that
  assumed one global module would double-fill.

`services/markets`:
- `TestChainFundingCheckerReadsConfiguredQuoteAsset` — `QUOTE_ASSET_ADDRESS` steers the `getBalance`
  call, and the cash asset is *not* read.
- `TestQuoteAssetDefaultsToCash` — unset keeps existing behaviour.
- `TestValidateActionModule`, `TestCreateOrderRequestToParamsRejectsForeignTradeModule`.

---

## Reproducing the test run

```bash
# contracts — the new suite
cd contracts/execution
forge test --match-path 'test/modules/TradeWrappedQuote.t.sol' -vv
#   => 12 passed

# contracts — no regressions (fork tests excluded; they need a Base RPC)
forge test --no-match-path 'test/*Fork*.t.sol'
#   => 223 passed, 0 failed, 1 skipped, across 44 suites

# markets service
cd ../../services/markets
go build ./...
go test ./...
#   => all packages ok
```

Foundry `1.7.1`, solc `0.8.27`, Go as pinned by `services/markets/go.mod`.

The deploy script has **not** been run against any chain. Its invocation is:

```bash
cd contracts/execution
PRIVATE_KEY=... \
FEE_RECIPIENT=1 \
MATCHING_OWNER=0x1dcA42ab54Bd3862853A821F84B29BF65245F435 \
  forge script scripts/deploy-wrapped-quote-trade-module.s.sol \
    --rpc-url "$BASE_RPC_URL" --broadcast
```

---

## What I am not sure about

1. **Who owns fee-recipient subaccount 1 on Base.** I could not read chain state. If Matching holds
   it, the wrapped-quote module can never collect a non-zero fee (finding b.1) and the fee recipient
   must be moved to a vault-held subaccount before fees are enabled. The deploy script checks this
   at run time and warns; it does not refuse, because fees are zero today. **This is the single
   thing to confirm before this ships.**
2. **The deploy script is unexercised.** It compiles and its assertions are cheap, but no fork test
   drives it. risk-core's `cngn-spot-batch.sol` pattern — a library shared between the script and a
   fork test so the emitted calldata and the tested calldata cannot diverge — is the right bar for
   a vault-executed batch, and I did not reach it. If this batch is going to be signed by the vault,
   it should get a `CNGNSpotBatchShape`-style test first.
3. **`quoteAsset` is immutable.** A wrong constructor argument is unrecoverable — the module would
   have to be redeployed. The script asserts `quoteAsset() == wrappedUsdc` and `!= cash` after
   deploy, which catches it, but only after the gas is spent.
4. **Decimal exactness at 6dp.** Tests use 6-decimal mocks matching real USDC and cNGN, and the
   wrapper's 18dp internal balances are what fills move, so a fill can leave a balance not
   representable in native 6dp. `WrappedERC20Asset.withdraw` rounds *up* on the way out
   (`:74-76`) specifically so dust cannot be withdrawn while leaving a zero balance, so this is
   handled — but I have not stress-tested the dust boundary and it is worth a fuzz test.
5. **`RfqModule` is still cash-quoted.** If RFQ is used for USDC/cNGN, that path keeps the cash leg
   and the book is only half-migrated. I did not check whether it is live for this pair.
6. **I did not migrate `packages/abis`.** `Deployment = {matching, trade}` is one module per chain
   (`packages/abis/src/index.ts:6`). That is fine for a cutover — set `TRADE_MODULE_ADDRESS` — but
   it cannot express running both modules at once, if that is ever wanted.
7. **Terraform is unvalidated.** `terraform` is not installed in this environment, so the `ecs.tf`
   and `variables.tf` edits are unchecked beyond matching the surrounding style.
