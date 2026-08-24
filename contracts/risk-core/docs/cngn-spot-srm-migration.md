# Moving USDCcNGN-SPOT from DeliverableFXManager to the SRM

## Why

The venue serves `USDCcNGN-SPOT` only. Under `DeliverableFXManager` a spot-only portfolio is margined as

```
margin = cash + baseBalance + quoteBalance / spotPrice   >= 0
```

(`DeliverableFXManager.sol:404-432`). Wrapped cNGN gets 100% credit at the oracle price — no haircut, no
depeg penalty, no oracle-confidence contingency — and cash may go negative, so an account can hold cNGN
with near-zero equity. `marginParams.normalIM/MM` cannot fix this: they only multiply *future* notional
(`:439-441`), and with no dated series listed they do nothing. The manager is not upgradeable, so tuning
it costs a redeploy either way.

The SRM is already deployed (`0x3195Bd7e02d93982bCF8b34DF5B941fFCaE1E49b`) and already carries a base-asset
path with real knobs. Registering wrapped cNGN there as a base-only market with `marginFactor = 0` gives
fully-funded spot with no new contract code.

## What `marginFactor = 0` buys

`_getBaseMarginAndMtM` returns `notional * marginFactor * IMScale`, so at 0 the cNGN leg contributes
nothing to margin while still being marked to market. Both directions are pinned down by tests:

| behaviour | test |
| --- | --- |
| buy funded by cash on hand settles | `testFork_FundedSpotBuySettles` |
| buy beyond cash on hand reverts | `testFork_UnfundedSpotBuyReverts` |
| cannot short cNGN (`WERC_CannotBeNegative`) | `testFork_CannotSellMoreCNGNThanHeld` |
| cash-free account can still sell cNGN | `testFork_SellingCNGNFromCashFreeAccountSettles` |
| cash-free account can still withdraw cNGN | `testFork_CanWithdrawCNGNWithNoCash` |
| zero factor blocks the borrow that `0.5e18` allows | `testZeroMarginFactorBlocksBorrowAgainstBase` |

`test/integration-tests/standard-manager/spot-trade.sol` covers the mechanism on a local deployment;
`test/fork/CNGNSpotSRMBaseFork.t.sol` replays the vault calldata against live Base state and trades on top
of it.

`setBorrowingEnabled(false)` is the second, independent guard — `_assessRisk` rejects negative cash before
the margin maths runs (`StandardManager.sol:382`). It is **global to the SRM**, not per market. SRM market 1
is wrapped USDC (`0x364058…`) at `marginFactor 0.98`; disabling borrowing removes leverage there too. That
is safe today — that asset holds 0 USDC on Base — but it is a real constraint if a leveraged market is ever
listed on the same SRM. `marginFactor = 0` is the per-market lever and is sufficient on its own; the flag is
belt-and-braces.

## Blocker: existing subaccounts cannot be migrated

`SubAccounts` writes `manager[accountId]` only in `_createAccount` (`src/SubAccounts.sol:97`). There is no
`changeManager` — the interface still declares an `AccountManagerChanged` event (`ISubAccounts.sol:226`) but
nothing emits it, and `SubAccounts` is not upgradeable. **An account created under `DeliverableFXManager`
stays under it forever.**

So this is not an in-place migration. It is:

1. Register the market on the SRM (below).
2. Point `SubAccountsManager.createSubAccount` at the SRM for new accounts.
3. Existing holders withdraw from their DFXM accounts and re-deposit into new SRM accounts.

Step 3 is currently free: on Base the wrapped cNGN asset holds 0 cNGN, the wrapped USDC deliverable asset
holds 0 USDC, and the cash asset holds 1 unit of USDC (checked 2026-08-22). There is nothing to move. If the
venue funds mainnet before this ships, the cost is a user-facing migration.

Withdrawals out of DFXM accounts are not blocked — a spot-only DFXM portfolio has no delivery obligations,
so `_getDeliveryReadiness` reports `inDeliveryPhase = false` and the account can be emptied.

## Off-chain impact

None to the markets service config. The wrapped cNGN asset and the cNGN spot feed are reused as-is, so
`CNGN_SPOT_ASSET_ADDRESS` does not change. What changes is which manager new subaccounts are created under.

The feed dependency is unchanged and still hard: `_getMarketMargin` fetches the market spot unconditionally,
and `_getBaseMarginAndMtM` reads `stableFeed`, so both the cNGN feed and the stable feed must be fresh for
any spot fill to clear. `srm.setWhitelistedCallee(cngnSpotFeed)` is in the batch so the matcher can push a
price in the same transaction via `managerData`.

## Running it

```
BASE_RPC_URL=... forge script scripts/register-cngn-spot-srm.s.sol --rpc-url $BASE_RPC_URL
```

The script deploys and broadcasts nothing. Every call is `onlyOwner` on a contract owned by the admin vault
`0x1dcA42ab54Bd3862853A821F84B29BF65245F435`, so it writes the calldata to
`deployments/8453/CNGN_SPOT_SRM_VAULT_ACTIONS.json` for the vault to execute **in order**:

1. `srm.createMarket("CNGN")`
2. `wrappedCngn.setWhitelistManager(srm, true)` — additive; DFXM stays whitelisted so a dated series can be relisted
3. `wrappedCngn.setTotalPositionCap(srm, cap)`
4. `srm.whitelistAsset(wrappedCngn, marketId, Base)`
5. `srm.setOraclesForMarket(marketId, cngnSpotFeed, 0, 0)`
6. `srm.setOracleContingencyParams(marketId, zeroed)` — inert at `marginFactor 0`; zeroed rather than left implying a live contingency
7. `srm.setBaseAssetMarginFactor(marketId, 0, 0)`
8. `srm.setBorrowingEnabled(false)`
9. `srm.setWhitelistedCallee(cngnSpotFeed, true)`

`marketId` is resolved from live state as `lastMarketId + 1` (2 as of 2026-08-22). `createMarket` assigns
`++lastMarketId`, so if anything else creates a market between generating and signing the batch, the ids
diverge — regenerate. Override with `CNGN_MARKET_ID` if signing offline.

### The one number to confirm before signing

`CNGN_SPOT_BASE_CAP` defaults to `1_500_000_000e18` cNGN (~$1m at 1,500 cNGN/USDC). Do not use
`Config.getSRMCaps("CNGN")` here: it returns `3_000_000e18`, which is ~$2k of spot inventory — it was sized
for a deliverable leg, not for a spot book. This is the venue's total cNGN inventory limit; pick it
deliberately.

## After the vault executes

Re-run the fork test — it reads the artifact and asserts the resulting on-chain config:

```
BASE_RPC_URL=... forge test --match-path test/fork/CNGNSpotSRMBaseFork.t.sol
```

Then update `DEPLOYED_ADDRESSES.md` with the new market id and the cap that was actually signed.
