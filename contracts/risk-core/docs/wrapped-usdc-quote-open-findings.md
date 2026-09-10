# Open findings — wrapped-USDC quote cutover

From an adversarial review of `integration/wrapped-usdc-quote` (2026-09-09), minus the two
already fixed on this branch. **None of these is closed. Do not run the vault batch until each
has been decided one way or the other** — deciding "accept, and here is why" is a valid close.

The reviewer stated two limits on its own work, kept here because they bound what this list
means: it executed **no test suite** (all claims are from source reading plus read-only chain
calls), and it did not audit the liquidation path, `AtomicSigningExecutor`, or `RfqModule`.

## Fixed already, listed so nobody re-opens them

- **Module custody.** `BaseModule` is `Ownable2Step`; the module was born owned by the deployer
  EOA and `acceptOwnership` was not in the batch. `onlyOwner` includes `setDatedFutureAsset`, and
  `_addAssetTransfers` sets `amtQuote = 0` for a dated future while `_fillLimitOrder` validates
  only `fill.price` — so the owner could take the base leg of any resting order for zero payment.
  Fixed: unconditional `transferOwnership(vault)`, `acceptOwnership` as action 0, postcondition on
  `pendingOwner`, four tests driving the script's own assertion.
- **Fee-recipient id race.** `feeOwner != vault` now asserted, not merely `code.length != 0`.

## Blocking-adjacent — decide before signing

### 1. ~~Action 2 is already on chain, and its description is false~~ — FIXED

`srm.getMarketFeeds(1)` already returns the static stable feed and `baseMarginParams(1)` is
`(0,0)` — both actions of `MARKET1_INERT_VAULT_ACTIONS.json` executed at blocks 51097293/51097344.
So the batch emits an `onlyOwner` no-op described as *"removes the 3600s staleness halt from the
quote leg"*, which is not true of the chain the signer signs against. The script header is stale
the same way.

Handing an MPC signer an action whose description misstates its effect is the wrong way round for
an irreversible batch — it trains the signer to skim.

**Fixed:** `skipOracle` is now derived from chain (`getMarketFeeds(quoteMarketId).spot ==
staticStableFeed`); `SKIP_ORACLE_ACTION` is gone. The action is emitted only when chain says it is
still needed, so its description can no longer misstate its effect.

### 2. ~~`STABLE_STATIC_FEED` override is unvalidated~~ — FIXED (override removed)

The same function carefully `code.length`-checks `matchingAddr` and `quoteAsset`, then accepts an
arbitrary `STABLE_STATIC_FEED` with no code check, no `getSpot()` probe, and no comparison against
`CNGN_SPOT_STATIC_FEEDS.json`. `setOraclesForMarket(1, <garbage>, 0, 0)` bricks the margin path for
every account holding wrapped USDC — post-cutover, every account.

### 3. ~~"Drain the book" is not verifiable~~ — FIXED

`CancelByOwnerNonce` filters `status = 'active'`. An order in `matching` — which the engine leaves
deliberately on an unknown outcome — survives the drain, and `ReleaseStaleMatches` runs only at
matcher startup, so after the cutover redeploy it returns to `active` as an **old-module order in a
new-module book**.

The whole cutover rests on this step and it is written as an action, not an assertion. Make it one:

```sql
select count(*) from active_orders where status in ('active','matching');  -- must be 0
```

**Fixed** by `services/markets/scripts/assert_book_drained.sh`, which asserts that count, lists
what is still open when it is non-zero, and with `--drain` cancels `matching` rows as well —
refusing unless `MATCHER_STOPPED=yes`, since that is the step that gets skipped. Verified against
a real Postgres across all four paths: empty, open, refused, drained.

### 4. ~~The two module env vars are coupled only by prose~~ — FIXED

`TRADE_MODULE_ADDRESS` and `QUOTE_ASSET_ADDRESS` must move together; three files say so and nothing
enforces it. Nothing anywhere reads `TradeModule.quoteAsset()`. The markets service already holds
`ChainRPCURL` and already does raw `eth_call`, so one call compared against
`cfg.QuoteAsset()` turns "an operator set two variables consistently" into "the process refuses to
start".

**Fixed** by `verifyQuoteAssetMatchesTradeModule`, called from `Engine.Run` before the first tick.
A mismatch is fatal and names both addresses; an unreachable RPC is not, because that says nothing
about whether the config is right and crash-looping the matcher on a flaky endpoint would take
matching down for an unrelated reason. Post-cutover the wrong pairing mis-judges *every* buyer, because every account's
wrapped-USDC balance is zero while its cash balance is not.

## Should fix

### 5. ~~`recipientId != subaccountId` ask-side regression~~ — FIXED

The quote leg credits `recipientId`. Matching transfers only `subaccountId` accounts to the module,
so a different recipient is not module-owned, and `WrappedERC20Asset` needs an allowance on the
**credit** side where `CashAsset` did not. A seller receiving quote into a separate recipient worked
under cash and reverts under wrapped.

`orders.go` takes `recipient_id` as a required free-form field and never checks it against
`subaccount_id` or against the signed `TradeData` (`decodeTradeData` reads words 0,1,2,3,6 and skips
4 and 5). Every test in both new suites uses `recipientId == accountId`. Unhandled, untested,
undetectable at submit; manifests as a pair that crosses, reserves, reverts, backs off, repeats.

**Fix:** validate `recipient_id == subaccount_id` at submit, or document the allowance requirement
and add it to the preconditions.

### 6. ~~The batch's ordering contradicts the runbook's~~ — FIXED (runbook order wins)

`wrapped-usdc-quote-cutover.md` §4 puts `setAssetAllowances` *before* the cutover; the script emits
it as the last action, after the enabling switch, and prints "Run the batch IN ORDER". Harmless at
today's zero fees, but it is a contradiction inside the one artifact the signer works from. The safe
order costs nothing.

### 7. The fork test with the stale precondition

`TradeModuleWrappedQuoteFork.t.sol:340` asserts market 1 is *not* on the static feed. It is now, so
the test fails at head. The tempting repairs — delete the assertion, or `vm.prank` the feed back —
would make it assert a world it manufactured rather than one it observed.

**The repair must preserve the coverage**: pin to a block `< 51097293` (51097292 verified), keep a
head-forked contrast test, and note `_repointQuoteOracle()` is now a no-op at head.
`testForkCashQuoteIsUnaffectedByTheStaleStableFeed` still passes but no longer proves anything —
there is no live feed left in the path — so it needs pinning or re-scoping too.

### 8. Two ways to brick or silently void the fee path — PARTLY FIXED

- The allowance is keyed by **owner** (`setAssetAllowances` passes `ownerOf(accountId)`), so
  transferring the fee subaccount to a different owner silently voids the grant. **Still open** —
  documented here, not enforced anywhere.
- `TradeModule` appends the fee transfer even at fee 0, and `SubAccounts._transferAsset` reverts
  `AC_CannotTransferAssetToOneself` when `fromAcc == toAcc`. A fee recipient that is also a trading
  subaccount bricks the venue. **Fixed**: `_assertFeeRecipient` now rejects a fee recipient that
  already holds any asset. Fees are zero at cutover and this still applies, because the transfer is
  appended at any fee including 0.

## Noted

- ~~**`RESULT.md`**~~ — deleted.
- **Canary blind spot.** Every feed its `getMargin` walk can reach is now static, so it cannot go
  red from feed staleness on this venue; it stays correct for a future market wired to a live feed.
  Alerting to Slack has since been added and proven by a live drill, but the coverage point stands:
  green here does not mean "feeds are fresh", it means "there are no stale-able feeds".
- **`inferSharedScale`** (`trade_units.go:130-155`) still never checks the derived scale is a power
  of ten or matches an expected value — only exact divisibility and taker/maker agreement.
  Pre-existing and **not** affected by the quote swap: both assets normalise to 18dp at subId 0, so
  `amtQuote` has identical scale either side of the cutover. Fix separately.

## Live-state observation that bears on the premise

```
USDC.balanceOf(cash)  = 2_000_001          (2.000001 USDC)
cash.totalSupply()    = 1.3682574719…e40   (~1.368e22 USDC, 18dp)
cash.netSettledCash() = 1.3682574719…e40
```

Internally consistent — `_getExchangeRate()` returns `1e18` — but the ledger carries ~1.37e22
nominal USDC against 2.000001 USDC of real backing. That is the manager-creditable property this
branch exists to remove, observed rather than argued.

Two consequences. The buy-side funding check is close to meaningless today: printed cash reads as
balance and the fill succeeds, paying the maker in cash they cannot withdraw. And at cutover every
account's wrapped-USDC balance is **zero** (`totalPosition(srm) == 0`, cap `1e36`), so
`buyerCanFund` rejects every cross until users round-trip cash → USDC → wrapped USDC. Correct
behaviour, but it is a full re-funding of the book and it appears nowhere in the runbook.
