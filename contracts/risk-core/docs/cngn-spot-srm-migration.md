# Moving USDCcNGN-SPOT from DeliverableFXManager to the SRM

The venue serves `USDCcNGN-SPOT` only. This moves it off `DeliverableFXManager` (DFXM) and lists it
on the already-deployed `StandardManager` (SRM) as a base-only market with `marginFactor = 0`.

## Why

Under DFXM a spot-only portfolio margins as `cash + baseBalance + quoteBalance / spotPrice >= 0`.
cNGN gets **100% credit at oracle price** — no haircut, no depeg handling, no contingency — and
cash may go negative. A trader can hold cNGN against ~zero equity. DFXM has no knob to tune this
and is not upgradeable.

On the SRM at `marginFactor = 0`, cNGN contributes nothing to margin while still marking to market,
so every buy must be funded by cash on hand.

## What `marginFactor = 0` buys

For a spot-only portfolio the margin check collapses to `cash >= 0`. Every other term is
structurally zero:

| term | value | why |
| --- | --- | --- |
| `netPerpMargin` | 0 | no perps |
| `netFutureMargin` | 0 | `futureMarginRequirements` unset → early return |
| `netOptionMargin` | 0 | no options |
| `baseMargin` | 0 | `notional * marginFactor * IMScale` |
| depeg penalty | 0 | `depegPenaltyPos` accumulates only from perps, futures and short options — never Base (`SRMPortfolioViewer.sol:120,124,184`) |
| `unrealizedPerpPNL` | 0 | no perps |

`markToMarket` is computed and then discarded by `_assessRisk` (`(int postIM,)`). With
`borrowingEnabled = false` the same constraint is enforced a second time, earlier, as
`SRM_NoNegativeCash`.

Behaviours pinned by `test/fork/CNGNSpotSRMBaseFork.t.sol` and
`test/integration-tests/standard-manager/spot-trade.sol`:

| behaviour | result |
| --- | --- |
| buy funded by cash on hand | settles |
| buy beyond cash on hand | reverts `SRM_PortfolioBelowMargin` (borrowing on) / `SRM_NoNegativeCash` (off) |
| sell more cNGN than held | reverts `WERC_CannotBeNegative` — no short side exists |
| cash-free account sells cNGN | settles — zero credit is not a lock-up |
| cash-free account withdraws cNGN | settles |
| same setup at `marginFactor = 0.5e18` | borrow succeeds — confirms the knob does the work |

## The feeds: orientation and liveness

Two separate problems, one fix.

**Orientation.** The SRM's `Base` convention is USD-per-base (`notional = position * spot`). The
live cNGN feed is quoted **cNGN-per-USDC** (~1345) because DFXM *divides* by it (`_quoteToCash`).
Reusing that feed in the SRM's Base slot inflates reported mark-to-market by `spot^2` — measured on
a fork, 1.5m cNGN truly worth 1,000 USDC marked at **2.25 billion**. Solvency is unaffected because
`baseMargin = notional * 0`, so the whole error is annihilated by a single multiplication by zero.
The moment `marginFactor` goes non-zero, cNGN is credited at ~2.25 million times its value.

**Liveness.** Both the market spot feed and the SRM's global `stableFeed` are read on every spot
adjustment (`_getMarketMargin`, `_getBaseMarginAndMtM:609`, `_getDepegMultiplier:427`) and both
revert when stale. Live heartbeats on Base are **180s** and **3600s**. A keeper gap therefore halts
a fully-funded orderbook whose solvency does not depend on either price.

**Fix:** deploy two `LyraStaticSpotFeed`s — one holding the inverted cNGN price, one holding
`1e18` for the stable feed. `LyraStaticSpotFeed.getSpot()` has no staleness check and cannot revert.
`testFork_TradesWithNoLiveOracleAfterHeartbeatsWouldHaveExpired` warps 30 days, shows the old feed
reverting, and settles a trade anyway.

Note `LyraStaticSpotFeed` does **not** hardcode confidence — it is whatever `setSpot` is given, and
defaults to 0. Nothing on the spot path reads it: all three `spotConf` consumers are unreachable
(`_getNetPerpMargin` returns at `position == 0`, `_getNetOptionMarginAndMtM`'s body is loop-only
over empty `expiryHoldings`, `_getBaseMarginAndMtM` returns at the `baseMargin == 0` short-circuit
before the contingency block). The deploy script sets `1e18` anyway.

## COUPLED SETTINGS — do not change one alone

These five are only safe **as a set**. The static prices are inert *because* margin is zero; make
margin non-zero and the venue credits cNGN against a rate frozen at deploy time.

1. `srm.baseMarginParams(cngnMarketId).marginFactor == 0`
2. `srm.borrowingEnabled == false`
3. market spot feed is the **static, inverted** feed (USDC-per-cNGN)
4. `srm.stableFeed` is the **static** feed
5. `srm.oracleContingencyParams(cngnMarketId)` all zero

Raising `marginFactor` requires replacing **both** feeds with live, correctly-oriented ones first.
This block is duplicated in `DEPLOYED_ADDRESSES.md` next to the addresses.

## Blocker: existing subaccounts cannot be migrated

`SubAccounts` writes `manager[accountId]` only in `_createAccount` (`src/SubAccounts.sol:97`). There
is no `changeManager` — the interface still declares an `AccountManagerChanged` event
(`ISubAccounts.sol:226`) that nothing emits — and `SubAccounts` is not upgradeable. **An account
created under DFXM can never move to the SRM.** This is inherited from upstream Derive verbatim, so
redeploying upstream does not fix it.

Migration is therefore: register the market → clients pass the SRM address to
`SubAccountsManager.createSubAccount(IManager)` (a call argument, so no contract change) → existing
holders withdraw and re-deposit into new accounts.

**Currently free.** On Base mainnet wrapped cNGN holds 0 cNGN, wrapped USDC holds 0 USDC, and cash
holds 1 unit of USDC. Nothing to migrate. This becomes a user-facing step only if mainnet is funded
before this ships.

## The cap

`wrappedCngn.setTotalPositionCap(srm, X)` limits total cNGN the venue can custody. The script
derives it as a percentage (default **10%**) of **live `totalSupply()`**, read at generation time —
not a constant. cNGN supply moves, and a stale denominator is how a cap ends up being most of the
float. (An earlier hardcoded `1.5e9` was 73% of total supply.)

The cap gates **deposits, not trading**: `_checkAssetCap` reverts only on
`preTradePos < postTradePos && postTradePos > cap`, and an account-to-account transfer of a
non-negative asset leaves `totalPosition` unchanged. Hitting it is a degraded state, not an outage —
new inventory cannot enter, the book keeps matching. Pinned by
`testFork_CapIsShareOfLiveSupplyAndBlocksDepositsOnly`.

**Alert at 80% of cap** so the raise happens before users are rejected. The script logs the
threshold.

## LAUNCH BLOCKER: matcher must reserve notional + fee

Tracked as **[numofx/exchange#12](https://github.com/numofx/exchange/issues/12)**. Do not launch
`USDCcNGN-SPOT` on the SRM until it is closed.

`TradeModule._addAssetTransfers` appends the fee as a **third quote-asset transfer in the same
batch** (`:151` taker, `:255` maker). `submitTransfers` applies the batch and then runs one
`handleAdjustment` per account, so the SRM sees one **net** cash delta.

- **Buyer**: `-(notional + fee)`. An order funded to exactly the notional fails `SRM_NoNegativeCash`.
- **Seller**: `+notional - fee`. Safe while `notional > fee`; the gross fee never needs pre-funding.

The matcher must reserve `notional + fee` on the buy side or it will emit orders that cannot settle.
This overlaps the open reserve-before-cross issue. Pinned by
`testFork_BuyerFundedToExactlyNotionalIsRejectedByFee`,
`testFork_BuyerFundedToNotionalPlusFeeSettles`, and `testFork_CashFreeSellerSettlesOnNetDelta`
(which also covers the boundary where a fee exceeding proceeds is refused).

The failure mode is silent: the order is accepted, crossed, and the settlement transaction reverts,
so the user sees a rejection with no obvious cause after the book has already moved.

## Off-chain impact

None to the markets config. The wrapped cNGN **asset** is reused, so `CNGN_SPOT_ASSET_ADDRESS` does
not change. The **feed** is not reused — the live one stays wired to DFXM in its current
orientation, so a dated series can still be relisted.

Nothing in `services/` or `packages/` reads `markToMarket` or `getMarginAndMarkToMarket`, and
`packages/abis` does not export the selector. If a frontend later shows PnL or equity, it must
source marks from the orderbook (last trade / mid), **not** from the manager — the static feed makes
the manager's MtM a frozen number.

## Running it

Two steps, in order. The vault-actions artifact is not committed: two of its eleven calls target
feeds that do not exist until step 1 has run.

```sh
# 1. deploy the static feeds, hand them to the vault (broadcasts)
NEW_OWNER=<vault> PRIVATE_KEY=<deployer> \
  forge script scripts/deploy-cngn-spot-static-feeds.s.sol --rpc-url $BASE_RPC_URL --broadcast

# 2. generate the vault batch (broadcasts nothing; reads live marketId, supply, feed addresses)
forge script scripts/register-cngn-spot-srm.s.sol --rpc-url $BASE_RPC_URL
```

Step 2 writes `deployments/8453/CNGN_SPOT_SRM_VAULT_ACTIONS.json` and logs a **batch hash**. The
action list has exactly one definition, `scripts/cngn-spot-batch.sol`: the script serialises it and
`test/fork/CNGNSpotSRMBaseFork.t.sol` executes it, so the batch under test and the batch signed are
the same bytes by construction. `test/scripts/CNGNSpotBatchShape.t.sol` pins the shape against a
committed hash, so editing the list fails a test until the constant is updated in the same commit.

### Verifying what you sign

**The vault is an EOA** (`0x1dcA42…F435`, codesize 0) — an MPC-signed address, not a Safe. There is
no MultiSend and no single proposed payload: this is **eleven separate transactions**, each approved
on its own. So the unit you can actually verify is one `(to, data)` pair, which is what your signer
displays. Step 2 prints a digest per action for exactly that comparison.

```sh
# check the artifact against live chain state
forge script scripts/verify-cngn-spot-batch.s.sol --rpc-url $BASE_RPC_URL

# identify a single pending transaction before approving it
ACTION_TO=0x… ACTION_DATA=0x… \
  forge script scripts/verify-cngn-spot-batch.s.sol --rpc-url $BASE_RPC_URL
```

The verifier does two independent things. It recomputes each entry's digest from that entry's own
`to`/`data` (catches a hand-edited JSON), and it rebuilds the batch from `CNGNSpotBatch` against
**live chain state** and compares byte-for-byte (catches a JSON that is internally consistent but
was generated against a different world). Only the second has real teeth — anyone who edits `data`
can recompute a digest.

**Because the batch is not atomic**, a mid-batch failure leaves partial state. No intermediate state
is unsafe — `baseMarginParams` defaults to `(0, 0)`, so cNGN never gets credit it should not have —
but two are incomplete and matter: stopping before action 11 leaves the old `stableFeed` and its
3600s staleness halt in place, and stopping before actions 9–10 leaves the static feeds owned by the
deployer key, which is the lost-key failure this repo already records once.

### Preconditions

Step 2 refuses to emit calldata for a world that has moved. `CNGNSpotBatch.checkPreconditions`
asserts, against live chain state: one owner across the SRM and the wrapped asset; the market id is
still `lastMarketId + 1` and unclaimed; both feeds have code and have the vault as **pending owner**
(actions 9–10 revert otherwise); the stable feed reads exactly `1e18`; the cNGN feed reads **below
`1e18`** — the orientation guard, which is what catches the live DFXM feed being substituted in; the
static price is within `CNGN_SPOT_DRIFT_TOLERANCE_PCT` (default 5%) of the inverted live rate; and
supply and cap are non-zero.

Each of these is proven to fire by `test/fork/CNGNSpotPreconditionsFork.t.sol`, against live Base.

The 11 calls, executed **in order**. The ordering is deliberate — secure custody, tighten globals,
configure an inert market, enable last — so that **every prefix is safe to abandon**:

| # | call | why here |
| --- | --- | --- |
| 0 | `staticCngnFeed.acceptOwnership()` | custody first; no functional change |
| 1 | `staticStableFeed.acceptOwnership()` | custody first |
| 2 | `srm.setStableFeed(staticStableFeed)` | clears the 3600s staleness halt. **Global** |
| 3 | `srm.setBorrowingEnabled(false)` | strictly tightening. **Global** |
| 4 | `srm.createMarket("CNGN")` | market exists, nothing wired |
| 5 | `srm.setBaseAssetMarginFactor(id, 0, 0)` | pinned before the asset is reachable |
| 6 | `srm.setOracleContingencyParams(id, zeroed)` | |
| 7 | `srm.setOraclesForMarket(id, staticCngnFeed, 0, 0)` | |
| 8 | `srm.whitelistAsset(wrappedCngn, id, Base)` | SRM side of the gate; asset side still shut |
| 9 | `wrappedCngn.setTotalPositionCap(srm, cap)` | cap in place before deposits are possible |
| 10 | `wrappedCngn.setWhitelistManager(srm, true)` | **the enabling switch** |

A deposit needs *both* gates: `whitelistAsset` on the SRM and `setWhitelistManager` on the asset.
The second is the last action, so no earlier prefix is tradeable —
`testFork_NoPrefixBeforeTheLastActionPermitsADeposit` executes all eleven prefixes and asserts a
deposit reverts on each.

This ordering replaced one that left `acceptOwnership` at 8–9 and `setStableFeed` at 10, where
abandoning the batch stranded both feeds on the deployer key and kept the old staleness halt.

### Resuming a partially-executed batch

```sh
RESUME=1 forge script scripts/verify-cngn-spot-batch.s.sol --rpc-url $BASE_RPC_URL
```

Reads each action's postcondition from chain and reports `done` / `pending` / `DIVERGED`, then names
the action to resume at. It **reverts** on divergence rather than suggesting a resume point — a
target configured to something other than what the batch specifies means someone else acted, and
that needs a human before anything further is signed.

Actions 5 and 6 write all-zeros, which is exactly what an untouched market reads, so state alone
cannot distinguish "we set it" from "nobody touched it".

**Action 5 is settled from logs.** `BaseMarginParamsSet(uint marketId, uint baseAssetMarginFactor,
uint baseAssetIMScale)` carries the market id, so a matching event is direct evidence the call
landed and the action reports plain `done`. The scan window defaults to the last 50,000 blocks;
override with `LOG_SCAN_BLOCKS` or `LOG_SCAN_FROM_BLOCK` if you are resuming after a long gap, and
note that public RPCs cap `eth_getLogs` ranges. A miss never downgrades a status — "no event in the
window" means "not found here", not "did not happen".

**Action 6 cannot be settled from logs alone, but can be settled from the transaction.**
`OracleContingencySet(uint prepThreshold, uint optionThreshold, uint baseThreshold, uint OCFactor)`
omits the market id, so no log can be attributed to a market. The *transaction* that emitted it
carries it, though: the call is
`setOracleContingencyParams(uint256,(uint256,uint256,uint256,uint256))` and the market id is the
first calldata word after the selector.

```sh
python3 scripts/ops/resolve_cngn_action6.py --from-block <n> --market-id <id>
```

It scans for zero-valued `OracleContingencySet` logs, fetches the transaction behind each, decodes
the market id, and exits 0 on a match — a positive read that does not rest on nonce ordering. Exit 1
means "not found in this range", which is **not** proof it did not happen: widen `--from-block`
first. `--self-test` checks the selector and decode with no network.

This lives in `scripts/ops/` rather than the Solidity verifier because `vm.rpc` returns the
transaction object ABI-encoded in alphabetical key order — a layout that differs between providers
and between transaction types — and because enabling `ffi` repo-wide so one check could shell out
would be a bad trade. The two assumptions it makes (selector, and marketId being the first word) are
pinned by `testActionSixCalldataShapeMatchesTheOpsResolver`, so a signature change breaks a test
rather than silently making the resolver match nothing.

Until you run it, action 6 prints `done*` and rests on nonce inference:

> ### The vault EOA must send nothing else until action 10 confirms
>
> Action 6's status rests on one assumption: **transactions from the vault land in nonce order**, so
> a later action reading `done` proves the earlier ones landed. That inference is only sound if the
> vault's nonce sequence over this window contains nothing but these eleven transactions.
>
> While the batch is in flight — from action 0 until action 10 is confirmed — **do not send any
> other transaction from `0x1dcA42…F435`**, on any chain config that shares this nonce sequence, and
> do not run a second batch concurrently. An interleaved transaction, a replacement/speed-up that
> reorders, or a dropped-and-refilled nonce breaks the ordering premise, and `done*` becomes a guess
> rather than an inference.
>
> If that discipline is broken, do not trust `done*`. Confirm action 6 from the transaction receipt
> directly before resuming.

**The batch must execute as the vault.** Actions 9 and 10 are `acceptOwnership()`, callable only by
the pending owner; a deployer EOA cannot stand in. A static feed left on a deployer key is the same
failure already recorded under "ABANDONED deployment" in `DEPLOYED_ADDRESSES.md`.

Actions 1–7 and 9–10 are inert until a client creates a subaccount under the SRM. Actions 8 and 11
take effect immediately across the whole SRM. Both are safe today — market 1 (wrapped USDC,
`marginFactor 0.98`) holds zero — but both must be revisited before any leveraged market lists here.

## After the vault executes

```sh
cast call $SRM 'lastMarketId()(uint256)'                    # must have incremented
cast call $SRM 'assetMap(uint256,uint8)(address)' $MKT 3    # must be wrappedCngn
cast call $SRM 'baseMarginParams(uint256)(uint256,uint256)' $MKT   # (0, 0)
cast call $SRM 'borrowingEnabled()(bool)'                   # false
cast call $SRM 'stableFeed()(address)'                      # the static feed
cast call $WCNGN 'whitelistedManager(address)(bool)' $SRM   # true
```

`baseMarginParams` reading `(0, 0)` is **not** sufficient evidence the batch landed — an unset
mapping slot for a market that does not exist reads identically. Check `lastMarketId` and the asset
map.

Then update `DEPLOYED_ADDRESSES.md`: the SRM as the spot manager, the two static feed addresses, and
the coupled-settings block above.
